//! 终端（docs/design.md § 7）：portable-pty 之上的终端表。R1 只够跑 terminal auth 的可见终端
//! （拉起、输出字节回调、写入、等退出、kill / release）；R4 转写 Zed `acp_thread/terminal.rs` 的语义
//! （输出字节上限、截断落字符边界、kill 不释放、release 后输出留存跟卡走）并接 `terminal/*` 回调。
//!
//! 本 crate 不依赖 tokio：输出与退出经 [`TerminalSink`] 回调从读线程 / 等待线程推出；[`TerminalManager::wait`]
//! 是阻塞调用，异步侧用 `spawn_blocking` 包。

use std::collections::HashMap;
use std::fmt;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};

#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum PtyError {
    /// 拉不起来（找不到程序、ConPTY 建不出等）。
    Spawn(String),
    Io(String),
    UnknownTerminal(String),
    NotImplemented(&'static str),
}

impl fmt::Display for PtyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PtyError::Spawn(e) => write!(f, "pty: spawn failed: {e}"),
            PtyError::Io(e) => write!(f, "pty: io: {e}"),
            PtyError::UnknownTerminal(id) => write!(f, "pty: unknown terminal {id}"),
            PtyError::NotImplemented(round) => write!(f, "pty: not implemented until {round}"),
        }
    }
}

impl std::error::Error for PtyError {}

pub type Result<T> = std::result::Result<T, PtyError>;

/// 终端输出的来源（`acp/terminal_output.source`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TerminalSource {
    /// `terminal/*` 回调建的终端。
    Agent,
    /// terminal auth 的可见终端。
    Auth,
    /// 终端面板的本地 shell（R4）。
    Local,
}

impl TerminalSource {
    pub fn as_str(self) -> &'static str {
        match self {
            TerminalSource::Agent => "agent",
            TerminalSource::Auth => "auth",
            TerminalSource::Local => "local",
        }
    }
}

/// 拉起一个终端进程的参数（`terminal/create` 的形状 + 窗口尺寸）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnSpec {
    pub command: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<std::path::PathBuf>,
    /// R4 才生效（Zed 语义）。
    pub output_byte_limit: Option<u64>,
    pub rows: u16,
    pub cols: u16,
}

impl SpawnSpec {
    pub fn new(command: impl Into<String>) -> Self {
        Self {
            command: command.into(),
            args: Vec::new(),
            env: Vec::new(),
            cwd: None,
            output_byte_limit: None,
            rows: 24,
            cols: 80,
        }
    }
}

/// 退出状态，形状对齐 ACP `TerminalExitStatus`（`exitCode` / `signal`）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExitStatus {
    pub exit_code: Option<u32>,
    pub signal: Option<String>,
}

impl From<portable_pty::ExitStatus> for ExitStatus {
    fn from(s: portable_pty::ExitStatus) -> Self {
        match s.signal() {
            Some(sig) => Self { exit_code: None, signal: Some(sig.to_string()) },
            None => Self { exit_code: Some(s.exit_code()), signal: None },
        }
    }
}

/// 输出与退出的出口。实现必须非阻塞：在读线程 / 等待线程上调用。
pub trait TerminalSink: Send + Sync {
    fn output(&self, terminal_id: &str, source: TerminalSource, bytes: &[u8]);
    fn exited(&self, terminal_id: &str, source: TerminalSource, status: &ExitStatus);
}

#[derive(Default)]
struct ExitCell {
    status: Mutex<Option<ExitStatus>>,
    changed: Condvar,
}

impl ExitCell {
    fn set(&self, status: ExitStatus) {
        let mut guard = lock_or_recover(&self.status);
        *guard = Some(status);
        self.changed.notify_all();
    }

    fn wait(&self) -> ExitStatus {
        let mut guard = lock_or_recover(&self.status);
        loop {
            if let Some(status) = guard.as_ref() {
                return status.clone();
            }
            guard = match self.changed.wait(guard) {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            };
        }
    }

    fn get(&self) -> Option<ExitStatus> {
        lock_or_recover(&self.status).clone()
    }
}

struct Handle {
    source: TerminalSource,
    /// 子进程退出后由等待线程 take 掉：ConPTY 的读端要等伪终端关闭才会 EOF。
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    writer: Mutex<Option<Box<dyn Write + Send>>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    exit: Arc<ExitCell>,
}

/// 终端表：id → 句柄。id 形如 `term_<n>`，进程内唯一。
pub struct TerminalManager {
    sink: Arc<dyn TerminalSink>,
    terminals: Mutex<HashMap<String, Arc<Handle>>>,
    seq: AtomicU64,
}

impl fmt::Debug for TerminalManager {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("TerminalManager").finish_non_exhaustive()
    }
}

/// 子进程退出后到关闭伪终端之间留给 ConPTY 冲刷尾部输出的时间。
const DRAIN_AFTER_EXIT: Duration = Duration::from_millis(150);
const READ_CHUNK: usize = 8 * 1024;
/// ConPTY 的光标位置探询（`CSI 6 n`）与我们的应答（`CSI 1 ; 1 R`）。
/// portable-pty 0.9 固定以 `PSEUDOCONSOLE_INHERIT_CURSOR` 建伪终端，Windows 11 26200 的 conhost 会在启动时发这条探询并
/// **阻塞子进程的控制台 I/O 直到收到应答**（本机实测：不答则 `cmd /c echo` 永不退出，只有关掉输入管道才被 conhost 杀掉）。
/// 真正的终端渲染器（xterm.dart）要到 `spawn` 之后才挂上，所以启动探询由 pty 层答一次；之后的 DSR 留给渲染器。
const DSR_QUERY: &[u8] = b"\x1b[6n";
const DSR_REPLY: &[u8] = b"\x1b[1;1R";

impl TerminalManager {
    pub fn new(sink: Arc<dyn TerminalSink>) -> Self {
        Self {
            sink,
            terminals: Mutex::new(HashMap::new()),
            seq: AtomicU64::new(0),
        }
    }

    /// 拉起进程：读线程把输出经 sink 推出；等待线程在进程退出后关闭伪终端、等读线程收尾，最后推 `exited`。
    pub fn spawn(&self, spec: SpawnSpec, source: TerminalSource) -> Result<String> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows: spec.rows,
                cols: spec.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| PtyError::Spawn(e.to_string()))?;
        let mut cmd = CommandBuilder::new(&spec.command);
        cmd.args(&spec.args);
        for (k, v) in &spec.env {
            cmd.env(k, v);
        }
        if let Some(cwd) = &spec.cwd {
            cmd.cwd(cwd);
        }
        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| PtyError::Spawn(format!("{}: {e}", spec.command)))?;
        // 拉起后 slave 端就没用了（portable-pty 的约定：尽早 drop）。
        drop(pair.slave);
        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| PtyError::Io(e.to_string()))?;
        let writer = pair
            .master
            .take_writer()
            .map_err(|e| PtyError::Io(e.to_string()))?;
        let killer = child.clone_killer();

        let id = format!("term_{}", self.seq.fetch_add(1, Ordering::Relaxed) + 1);
        let handle = Arc::new(Handle {
            source,
            master: Mutex::new(Some(pair.master)),
            writer: Mutex::new(Some(writer)),
            killer: Mutex::new(killer),
            exit: Arc::new(ExitCell::default()),
        });
        lock_or_recover(&self.terminals).insert(id.clone(), handle.clone());

        let reader_thread = {
            let sink = self.sink.clone();
            let id = id.clone();
            let handle = handle.clone();
            let mut reader = reader;
            std::thread::Builder::new()
                .name(format!("pty-read-{id}"))
                .spawn(move || {
                    let mut buf = [0u8; READ_CHUNK];
                    let mut dsr_answered = false;
                    loop {
                        match reader.read(&mut buf) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => {
                                let chunk = &buf[..n];
                                if !dsr_answered && chunk.windows(DSR_QUERY.len()).any(|w| w == DSR_QUERY) {
                                    dsr_answered = true;
                                    if let Some(writer) = lock_or_recover(&handle.writer).as_mut() {
                                        let _ = writer.write_all(DSR_REPLY).and_then(|()| writer.flush());
                                    }
                                }
                                sink.output(&id, source, chunk);
                            }
                        }
                    }
                })
                .map_err(|e| PtyError::Io(e.to_string()))?
        };

        {
            let sink = self.sink.clone();
            let id = id.clone();
            let handle = handle.clone();
            let mut child = child;
            std::thread::Builder::new()
                .name(format!("pty-wait-{id}"))
                .spawn(move || {
                    let status: ExitStatus = match child.wait() {
                        Ok(s) => s.into(),
                        Err(e) => ExitStatus { exit_code: None, signal: Some(format!("wait failed: {e}")) },
                    };
                    std::thread::sleep(DRAIN_AFTER_EXIT);
                    // 关闭伪终端让读线程 EOF；写端一并关。
                    drop(lock_or_recover(&handle.writer).take());
                    drop(lock_or_recover(&handle.master).take());
                    let _ = reader_thread.join();
                    handle.exit.set(status.clone());
                    sink.exited(&id, source, &status);
                })
                .map_err(|e| PtyError::Io(e.to_string()))?;
        }
        Ok(id)
    }

    fn handle(&self, id: &str) -> Result<Arc<Handle>> {
        lock_or_recover(&self.terminals)
            .get(id)
            .cloned()
            .ok_or_else(|| PtyError::UnknownTerminal(id.to_string()))
    }

    pub fn source(&self, id: &str) -> Result<TerminalSource> {
        Ok(self.handle(id)?.source)
    }

    /// 往进程 stdin 写字节（键盘输入）。进程已退出 → `Io`。
    pub fn write(&self, id: &str, bytes: &[u8]) -> Result<()> {
        let handle = self.handle(id)?;
        let mut guard = lock_or_recover(&handle.writer);
        let writer = guard.as_mut().ok_or_else(|| PtyError::Io(format!("{id}: process exited")))?;
        writer.write_all(bytes).map_err(|e| PtyError::Io(e.to_string()))?;
        writer.flush().map_err(|e| PtyError::Io(e.to_string()))
    }

    pub fn resize(&self, id: &str, rows: u16, cols: u16) -> Result<()> {
        let handle = self.handle(id)?;
        let guard = lock_or_recover(&handle.master);
        let master = guard.as_ref().ok_or_else(|| PtyError::Io(format!("{id}: process exited")))?;
        master
            .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| PtyError::Io(e.to_string()))
    }

    /// kill 不释放（Zed 语义）：句柄与输出留存到 `release`。
    pub fn kill(&self, id: &str) -> Result<()> {
        let handle = self.handle(id)?;
        lock_or_recover(&handle.killer).kill().map_err(|e| PtyError::Io(e.to_string()))
    }

    /// 阻塞等退出。异步侧用 `spawn_blocking`。
    pub fn wait(&self, id: &str) -> Result<ExitStatus> {
        let handle = self.handle(id)?;
        Ok(handle.exit.wait())
    }

    pub fn try_status(&self, id: &str) -> Result<Option<ExitStatus>> {
        Ok(self.handle(id)?.exit.get())
    }

    /// 释放句柄：进程还在就先 kill。
    pub fn release(&self, id: &str) -> Result<()> {
        let handle = lock_or_recover(&self.terminals)
            .remove(id)
            .ok_or_else(|| PtyError::UnknownTerminal(id.to_string()))?;
        if handle.exit.get().is_none() {
            let _ = lock_or_recover(&handle.killer).kill();
        }
        Ok(())
    }

    pub fn ids(&self) -> Vec<String> {
        lock_or_recover(&self.terminals).keys().cloned().collect()
    }
}

fn lock_or_recover<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    match m.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Recorder {
        output: Mutex<Vec<u8>>,
        exits: Mutex<Vec<(String, ExitStatus)>>,
    }

    impl TerminalSink for Recorder {
        fn output(&self, _id: &str, _source: TerminalSource, bytes: &[u8]) {
            lock_or_recover(&self.output).extend_from_slice(bytes);
        }

        fn exited(&self, id: &str, _source: TerminalSource, status: &ExitStatus) {
            lock_or_recover(&self.exits).push((id.to_string(), status.clone()));
        }
    }

    fn echo_spec() -> SpawnSpec {
        let mut spec = if cfg!(windows) {
            let mut s = SpawnSpec::new("cmd.exe");
            s.args = vec!["/c".into(), "echo pty-hello-world".into()];
            s
        } else {
            let mut s = SpawnSpec::new("sh");
            s.args = vec!["-c".into(), "echo pty-hello-world".into()];
            s
        };
        spec.cwd = Some(std::env::temp_dir());
        spec
    }

    #[test]
    fn spawn_streams_output_and_reports_exit() {
        let recorder = Arc::new(Recorder::default());
        let manager = TerminalManager::new(recorder.clone());
        let id = manager.spawn(echo_spec(), TerminalSource::Auth).expect("spawn");
        assert_eq!(manager.source(&id).expect("source"), TerminalSource::Auth);
        let status = manager.wait(&id).expect("wait");
        assert_eq!(status.exit_code, Some(0), "{status:?}");
        let out = String::from_utf8_lossy(&lock_or_recover(&recorder.output)).into_owned();
        assert!(out.contains("pty-hello-world"), "output: {out:?}");
        let exits = lock_or_recover(&recorder.exits).clone();
        assert_eq!(exits.len(), 1);
        assert_eq!(exits[0].0, id);
        manager.release(&id).expect("release");
        assert!(matches!(manager.wait(&id), Err(PtyError::UnknownTerminal(_))));
    }

    /// 键盘输入能到达子进程：cmd 的 `set /p` 读一行后回显。
    #[cfg(windows)]
    #[test]
    fn write_reaches_the_child() {
        let recorder = Arc::new(Recorder::default());
        let manager = TerminalManager::new(recorder.clone());
        let mut spec = SpawnSpec::new("cmd.exe");
        // `/v:on` + `!X!`：`%X%` 会在解析整行时就展开成空串，读到的值要用延迟展开才看得到。
        spec.args = vec!["/v:on".into(), "/c".into(), "set /p X=Enter key: && echo GOT:!X!".into()];
        spec.cwd = Some(std::env::temp_dir());
        let id = manager.spawn(spec, TerminalSource::Auth).expect("spawn");
        // 等提示出现再写（ConPTY 启动探询由读线程应答；这里只需等 prompt 到达）。
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            let seen = String::from_utf8_lossy(&lock_or_recover(&recorder.output)).contains("Enter key");
            if seen {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "prompt never appeared: {:?}", String::from_utf8_lossy(&lock_or_recover(&recorder.output)));
            std::thread::sleep(Duration::from_millis(20));
        }
        manager.write(&id, b"secret-1\r").expect("write");
        let status = manager.wait(&id).expect("wait");
        assert_eq!(status.exit_code, Some(0), "{status:?}");
        let out = String::from_utf8_lossy(&lock_or_recover(&recorder.output)).into_owned();
        assert!(out.contains("GOT:secret-1"), "output: {out:?}");
        manager.release(&id).expect("release");
    }

    #[test]
    fn unknown_program_fails_to_spawn() {
        let manager = TerminalManager::new(Arc::new(Recorder::default()));
        let spec = SpawnSpec::new("definitely-not-a-program-acp-r1");
        let result = manager.spawn(spec, TerminalSource::Auth);
        match result {
            Err(PtyError::Spawn(_)) => {}
            // 有的平台把找不到程序推迟到进程退出（ConPTY 在 CreateProcess 失败时就报错，Unix 也在 exec 前报错）。
            Ok(id) => {
                let status = manager.wait(&id).expect("wait");
                assert_ne!(status.exit_code, Some(0));
            }
            Err(other) => panic!("unexpected error {other}"),
        }
    }
}
