//! 终端（docs/design.md § 7）：portable-pty 之上的终端表。R1 只够跑 terminal auth 的可见终端
//! （拉起、输出字节回调、写入、等退出、kill / release）；R4 接 `terminal/*` 回调与终端面板的本地 shell：
//! 每个终端一份输出留存缓冲（`outputByteLimit`，超限从头截、落字符边界——规范原文；Zed 的 `truncated_output` 是从尾截，
//! 本项目按规范）、`terminal/output` 的文本去 ANSI 转义、命令经系统 shell 拼装（[`shell`]，转写 Zed ShellBuilder）、
//! kill 不释放、release 后核心侧缓冲释放而前端自己留存（跟工具卡走）。
//!
//! 本 crate 不依赖 tokio：输出与退出经 [`TerminalSink`] 回调从读线程 / 等待线程推出；[`TerminalManager::wait`]
//! 是阻塞调用，异步侧等退出用 [`TerminalManager::on_exit`] 的回调，不拿 `spawn_blocking` 包 `wait`。

use std::collections::HashMap;
use std::fmt;
use std::io::{Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use portable_pty::{ChildKiller, CommandBuilder, MasterPty, PtySize, native_pty_system};

pub mod shell;

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

/// 拉起一个终端进程的参数（`terminal/create` 的形状 + 窗口尺寸）。`command` 直接是程序（不过 shell）；
/// 要经 shell 跑的命令用 [`TerminalManager::spawn_shell_command`]。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnSpec {
    pub command: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Option<std::path::PathBuf>,
    /// `terminal/create.outputByteLimit`：留存缓冲的上限；缺省只受 [`HARD_OUTPUT_LIMIT`] 约束。
    pub output_byte_limit: Option<u64>,
    pub rows: u16,
    pub cols: u16,
}

/// 留存缓冲的绝对上限：agent 不给 `outputByteLimit` 时也不能无限吃内存（`yes` 之类的命令）。
pub const HARD_OUTPUT_LIMIT: usize = 4 * 1024 * 1024;

/// 输出留存缓冲：超限从头截（规范：「truncates from the beginning of the output」），起点退到 UTF-8 字符边界。
#[derive(Debug, Default)]
struct OutputBuffer {
    bytes: Vec<u8>,
    limit: Option<usize>,
    truncated: bool,
}

impl OutputBuffer {
    fn new(limit: Option<u64>) -> Self {
        Self { bytes: Vec::new(), limit: limit.map(|l| l as usize), truncated: false }
    }

    fn push(&mut self, chunk: &[u8]) {
        self.bytes.extend_from_slice(chunk);
        let cap = self.limit.unwrap_or(HARD_OUTPUT_LIMIT).min(HARD_OUTPUT_LIMIT);
        if self.bytes.len() > cap {
            let mut start = self.bytes.len() - cap;
            // UTF-8 的续字节是 10xxxxxx：往前挪到下一个字符的首字节，别切出半个字符（规范 MUST）。
            while start < self.bytes.len() && (self.bytes[start] & 0xC0) == 0x80 {
                start += 1;
            }
            self.bytes.drain(..start);
            self.truncated = true;
        }
    }
}

/// `terminal/output` 的响应内容。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalOutput {
    /// 留存的输出（lossy UTF-8，去掉了 ANSI 转义，`\r\n` 归一成 `\n`）。
    pub text: String,
    pub truncated: bool,
    /// 进程已退出时才有。
    pub exit: Option<ExitStatus>,
}

/// 去掉 ANSI 转义（CSI / OSC / 单字节 ESC 序列），`\r\n` → `\n`，其余孤立 `\r` 删掉：agent 要的是文本，不是渲染指令。
/// ConPTY 会把光标定位、颜色都塞进流里，不去掉的话一条 `echo hi` 也会带几十个转义。
pub fn strip_ansi(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\u{1b}' => match chars.next() {
                // CSI：ESC [ 参数字节 (0x30–0x3F) 中间字节 (0x20–0x2F) 终止字节 (0x40–0x7E)
                Some('[') => {
                    for n in chars.by_ref() {
                        if ('\u{40}'..='\u{7e}').contains(&n) {
                            break;
                        }
                    }
                }
                // OSC：ESC ] … BEL 或 ESC \
                Some(']') => {
                    let mut prev = '\0';
                    for n in chars.by_ref() {
                        if n == '\u{7}' || (prev == '\u{1b}' && n == '\\') {
                            break;
                        }
                        prev = n;
                    }
                }
                // 其他两字节序列（ESC =、ESC >、ESC 7 …）与 ESC ( x 之类的字符集选择。
                Some('(') | Some(')') => {
                    chars.next();
                }
                Some(_) | None => {}
            },
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    // `\r\n` 由下一轮的 `\n` 输出。
                } else {
                    // 孤立回车（进度条覆盖行）：删掉。
                }
            }
            other => out.push(other),
        }
    }
    out
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

/// [`TerminalManager::on_exit`] 登记的回调。
type ExitCallback = Box<dyn FnOnce(&ExitStatus) + Send>;

#[derive(Default)]
struct ExitState {
    status: Option<ExitStatus>,
    /// 还没退出时登记的回调，退出那一下逐个调一次。
    callbacks: Vec<ExitCallback>,
}

#[derive(Default)]
struct ExitCell {
    state: Mutex<ExitState>,
    changed: Condvar,
}

impl ExitCell {
    fn set(&self, status: ExitStatus) {
        let callbacks = {
            let mut guard = lock_or_recover(&self.state);
            guard.status = Some(status.clone());
            self.changed.notify_all();
            std::mem::take(&mut guard.callbacks)
        };
        // 锁外调：回调里再查这个终端（`try_status` / `output`）不会自己锁死自己。
        for callback in callbacks {
            callback(&status);
        }
    }

    /// 退出时回调一次；已经退出就当场回调（在调用方线程上）。
    fn on_exit(&self, callback: ExitCallback) {
        let mut guard = lock_or_recover(&self.state);
        match guard.status.clone() {
            Some(status) => {
                drop(guard);
                callback(&status);
            }
            None => guard.callbacks.push(callback),
        }
    }

    fn wait(&self) -> ExitStatus {
        let mut guard = lock_or_recover(&self.state);
        loop {
            if let Some(status) = guard.status.as_ref() {
                return status.clone();
            }
            guard = match self.changed.wait(guard) {
                Ok(g) => g,
                Err(poisoned) => poisoned.into_inner(),
            };
        }
    }

    fn get(&self) -> Option<ExitStatus> {
        lock_or_recover(&self.state).status.clone()
    }

    /// 最多等 `timeout`；到点还没退出返回 None。
    fn wait_timeout(&self, timeout: Duration) -> Option<ExitStatus> {
        let deadline = Instant::now() + timeout;
        let mut guard = lock_or_recover(&self.state);
        loop {
            if let Some(status) = guard.status.as_ref() {
                return Some(status.clone());
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            guard = match self.changed.wait_timeout(guard, remaining) {
                Ok((g, _)) => g,
                Err(poisoned) => poisoned.into_inner().0,
            };
        }
    }
}

struct Handle {
    source: TerminalSource,
    /// 子进程退出后由等待线程 take 掉：ConPTY 的读端要等伪终端关闭才会 EOF。
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    writer: Mutex<Option<Box<dyn Write + Send>>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    exit: Arc<ExitCell>,
    /// `terminal/output` 的留存缓冲（release 时随句柄一起丢掉；前端自己留存一份跟卡走）。
    output: Mutex<OutputBuffer>,
    started: Instant,
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

/// `kill` 之后等进程真的退出的时限：等待线程先 drain `DRAIN_AFTER_EXIT` 再 join 读线程，通常 0.3 s 内落定。
const KILL_CONFIRM: Duration = Duration::from_secs(5);
const READ_CHUNK: usize = 8 * 1024;
/// ConPTY 的光标位置探询（`CSI 6 n`）与我们的应答（`CSI 1 ; 1 R`）。
/// portable-pty 0.9 固定以 `PSEUDOCONSOLE_INHERIT_CURSOR` 建伪终端，Windows 11 26200 的 conhost 会在启动时发这条探询并
/// **阻塞子进程的控制台 I/O 直到收到应答**（本机实测：不答则 `cmd /c echo` 永不退出，只有关掉输入管道才被 conhost 杀掉）。
/// 真正的终端渲染器（xterm.dart）要到 `spawn` 之后才挂上，所以启动探询由 pty 层答一次；之后的 DSR 留给渲染器。
/// 启动探询本身从输出流里抠掉（R4）：留着的话本地 shell 的 xterm.dart 会再答一次，PSReadLine 解析那条应答时把相邻的
/// 按键一起吞掉（实测敲 `echo` 丢了 `e`）；转录里的终端卡是只读视图本来就不接 `onOutput`（`rounds/BACKLOG.md` R1 条目）。
const DSR_QUERY: &[u8] = b"\x1b[6n";
const DSR_REPLY: &[u8] = b"\x1b[1;1R";
/// 启动探询最多攒这么多字节：ConPTY 把它放在最前面，超过这个量还没出现就当没有。
const DSR_HOLD_LIMIT: usize = 256;

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
            output: Mutex::new(OutputBuffer::new(spec.output_byte_limit)),
            started: Instant::now(),
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
                    // 启动探询没答之前先把字节攒在 `held` 里（探询可能被 read 边界切开）：找到就答一次并把探询本身从流里抠掉
                    // ——渲染器（xterm.dart）看不到它就不会再答第二次，那第二次应答会被 shell 当键盘输入吞掉相邻的按键
                    // （R4 实测：本地 PowerShell 里敲 `echo` 丢了 `e`）。攒满 [`DSR_HOLD_LIMIT`] 还没出现就不等了。
                    let mut dsr_answered = false;
                    let mut held: Vec<u8> = Vec::new();
                    let emit = |bytes: &[u8]| {
                        if bytes.is_empty() {
                            return;
                        }
                        lock_or_recover(&handle.output).push(bytes);
                        sink.output(&id, source, bytes);
                    };
                    loop {
                        match reader.read(&mut buf) {
                            Ok(0) | Err(_) => {
                                emit(&held);
                                break;
                            }
                            Ok(n) => {
                                let chunk = &buf[..n];
                                if dsr_answered {
                                    emit(chunk);
                                    continue;
                                }
                                held.extend_from_slice(chunk);
                                if let Some(at) = held.windows(DSR_QUERY.len()).position(|w| w == DSR_QUERY) {
                                    dsr_answered = true;
                                    if let Some(writer) = lock_or_recover(&handle.writer).as_mut() {
                                        let _ = writer.write_all(DSR_REPLY).and_then(|()| writer.flush());
                                    }
                                    held.drain(at..at + DSR_QUERY.len());
                                    let rest = std::mem::take(&mut held);
                                    emit(&rest);
                                } else if held.len() >= DSR_HOLD_LIMIT {
                                    dsr_answered = true;
                                    let rest = std::mem::take(&mut held);
                                    emit(&rest);
                                }
                            }
                        }
                    }
                })
        };
        let reader_thread = match reader_thread {
            Ok(thread) => thread,
            Err(e) => {
                self.abandon(&id, &handle);
                return Err(PtyError::Io(e.to_string()));
            }
        };

        let waiter = {
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
        };
        if let Err(e) = waiter {
            self.abandon(&id, &handle);
            return Err(PtyError::Io(e.to_string()));
        }
        Ok(id)
    }

    /// 拉起后半途失败（读 / 等待线程建不出来）：撤表项、杀子进程、关伪终端，不留孤儿（审查 finding）。
    fn abandon(&self, id: &str, handle: &Arc<Handle>) {
        lock_or_recover(&self.terminals).remove(id);
        let _ = lock_or_recover(&handle.killer).kill();
        drop(lock_or_recover(&handle.writer).take());
        drop(lock_or_recover(&handle.master).take());
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

    /// `terminal/create`：agent 的 `command` + `args` 经系统默认 shell 跑（[`shell::build`]），stdin 接空、关掉分页器
    /// （Zed `disable_pagers_through_env`），再叠上 agent 给的环境变量。`cwd` 缺省由调用方给会话目录。
    pub fn spawn_shell_command(
        &self,
        command: &str,
        args: &[String],
        env: Vec<(String, String)>,
        cwd: Option<std::path::PathBuf>,
        output_byte_limit: Option<u64>,
        source: TerminalSource,
    ) -> Result<String> {
        let (program, kind) = shell::default_shell();
        let built = shell::build(&program, kind, command, args);
        let mut spec = SpawnSpec::new(built.program);
        spec.args = built.args;
        spec.env = vec![("PAGER".to_string(), String::new()), ("GIT_PAGER".to_string(), "cat".to_string())];
        spec.env.extend(env);
        spec.cwd = cwd;
        spec.output_byte_limit = output_byte_limit;
        self.spawn(spec, source)
    }

    /// `terminal/output`：留存的输出（去 ANSI）、是否截断过、退出状态（已退出时）。
    pub fn output(&self, id: &str) -> Result<TerminalOutput> {
        let handle = self.handle(id)?;
        // 锁内只拷字节：读线程的 push 与这把锁竞争，lossy 解码 + 去 ANSI（最多 4 MiB）放到锁外做（审查 finding，2026-09-16）。
        let (bytes, truncated) = {
            let buffer = lock_or_recover(&handle.output);
            (buffer.bytes.clone(), buffer.truncated)
        };
        let text = strip_ansi(&String::from_utf8_lossy(&bytes));
        Ok(TerminalOutput { text, truncated, exit: handle.exit.get() })
    }

    /// 拉起到现在的时长（终端面板的耗时行）。
    pub fn elapsed(&self, id: &str) -> Result<Duration> {
        Ok(self.handle(id)?.started.elapsed())
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

    /// kill 不释放（Zed 语义）：句柄与输出留存到 `release`。已退出的进程 kill 是空操作。
    /// 阻塞最多 `KILL_CONFIRM`（异步侧用 `spawn_blocking`）。
    pub fn kill(&self, id: &str) -> Result<()> {
        let handle = self.handle(id)?;
        if handle.exit.get().is_some() {
            return Ok(());
        }
        // portable-pty 0.9.0 的 Windows `WinChildKiller::kill` 把 TerminateProcess 的成败判反了：成功时返回
        // Err(GetLastError 的陈旧值——本机实测见过 os error 0 与 os error 6「句柄无效」)，失败时反而返回 Ok。
        // 返回值不可信，以进程是否真的退出为准：等等待线程把退出状态落进 ExitCell。
        let _ = lock_or_recover(&handle.killer).kill();
        match handle.exit.wait_timeout(KILL_CONFIRM) {
            Some(_) => Ok(()),
            None => Err(PtyError::Io(format!("{id}: process still running {}s after kill", KILL_CONFIRM.as_secs()))),
        }
    }

    /// 阻塞等退出。异步侧用 [`TerminalManager::on_exit`]，别拿 `spawn_blocking` 包它：进程跑不完就钉住一条阻塞线程。
    pub fn wait(&self, id: &str) -> Result<ExitStatus> {
        let handle = self.handle(id)?;
        Ok(handle.exit.wait())
    }

    /// 进程退出时回调一次（已经退出就当场回调），不阻塞：异步侧等退出用它挂一个 oneshot，不占线程
    /// （BACKLOG P0，2026-09-24：`terminal/wait_for_exit` 原先 `spawn_blocking` + [`TerminalManager::wait`]，
    /// 跑不完的终端每个钉住一条 tokio 阻塞线程，攒多了文件树 / git / fs 回调 / `terminal/kill` 全排队）。
    /// 回调在等待线程上跑，与 [`TerminalSink`] 一样必须非阻塞。登记之后 release 掉这个终端也照样回调（release 会先 kill）。
    pub fn on_exit(&self, id: &str, callback: impl FnOnce(&ExitStatus) + Send + 'static) -> Result<()> {
        self.handle(id)?.exit.on_exit(Box::new(callback));
        Ok(())
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
        // 启动探询已由 pty 层应答并抠掉，渲染器看不到它（否则会再答一次）。
        assert!(!out.contains("\u{1b}[6n"), "startup DSR query must not reach the renderer: {out:?}");
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

    /// 规范硬要求：超限从头截、落在字符边界（含中文与 emoji 的输出不能切出半个字符）。
    #[test]
    fn output_buffer_truncates_from_the_start_at_char_boundaries() {
        let mut b = OutputBuffer::new(Some(10));
        b.push("汉字".as_bytes()); // 6 字节
        assert!(!b.truncated);
        b.push("😀ab".as_bytes()); // 4 + 2 = 6 → 共 12 > 10
        assert!(b.truncated);
        let text = String::from_utf8(b.bytes.clone()).expect("must be valid utf-8 after truncation");
        // 从头截掉 2 字节会落在「汉」中间，退到「字」的首字节：留下 字😀ab（3 + 4 + 2 = 9 字节）。
        assert_eq!(text, "字😀ab");
        assert!(b.bytes.len() <= 10);
        // 再推一大块，仍不超限、仍是合法 UTF-8。
        b.push("中文中文中文".as_bytes());
        assert!(b.bytes.len() <= 10);
        assert!(std::str::from_utf8(&b.bytes).is_ok());
        // 没给上限时受绝对上限约束。
        let mut unbounded = OutputBuffer::new(None);
        unbounded.push(&vec![b'x'; HARD_OUTPUT_LIMIT + 3]);
        assert_eq!(unbounded.bytes.len(), HARD_OUTPUT_LIMIT);
        assert!(unbounded.truncated);
    }

    #[test]
    fn strip_ansi_removes_escapes_and_normalizes_newlines() {
        let raw = "\u{1b}[?25l\u{1b}[2J\u{1b}[1;1H\u{1b}[32mok\u{1b}[0m\r\n\u{1b}]0;title\u{7}line2\r\nprogress 1\rprogress 2\r\n";
        assert_eq!(strip_ansi(raw), "ok\nline2\nprogress 1progress 2\n");
        assert_eq!(strip_ansi("plain\n"), "plain\n");
        // 不完整的序列（流被截断在转义中间）不能 panic。
        assert_eq!(strip_ansi("x\u{1b}["), "x");
        assert_eq!(strip_ansi("x\u{1b}"), "x");
    }

    /// terminal/output 拿到的是去转义后的文本 + 退出状态；kill 不释放（句柄与输出仍在），release 才没了。
    #[test]
    fn output_and_kill_then_release() {
        let recorder = Arc::new(Recorder::default());
        let manager = TerminalManager::new(recorder.clone());
        let id = manager.spawn(echo_spec(), TerminalSource::Agent).expect("spawn");
        let status = manager.wait(&id).expect("wait");
        assert_eq!(status.exit_code, Some(0));
        let out = manager.output(&id).expect("output");
        assert!(out.text.contains("pty-hello-world"), "{out:?}");
        assert!(!out.text.contains('\u{1b}'), "escapes must be stripped: {:?}", out.text);
        assert!(!out.truncated);
        assert_eq!(out.exit.as_ref().and_then(|e| e.exit_code), Some(0));
        // 已退出的进程 kill 是空操作（不报错也不释放）。
        let _ = manager.kill(&id);
        assert!(manager.output(&id).is_ok());
        manager.release(&id).expect("release");
        assert!(matches!(manager.output(&id), Err(PtyError::UnknownTerminal(_))));
    }

    /// 长命令（后台命令）被 kill：wait 返回、输出还在、release 前 output 仍可读。
    #[test]
    fn kill_running_command_keeps_output_until_release() {
        let recorder = Arc::new(Recorder::default());
        let manager = TerminalManager::new(recorder.clone());
        let mut spec = if cfg!(windows) {
            let mut s = SpawnSpec::new("cmd.exe");
            s.args = vec!["/c".into(), "echo started && ping -n 30 127.0.0.1 > nul".into()];
            s
        } else {
            let mut s = SpawnSpec::new("sh");
            s.args = vec!["-c".into(), "echo started; sleep 30".into()];
            s
        };
        spec.cwd = Some(std::env::temp_dir());
        let id = manager.spawn(spec, TerminalSource::Agent).expect("spawn");
        let deadline = Instant::now() + Duration::from_secs(10);
        while !manager.output(&id).expect("output").text.contains("started") {
            assert!(Instant::now() < deadline, "prompt never appeared");
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(manager.try_status(&id).expect("status").is_none(), "still running");
        manager.kill(&id).expect("kill");
        let status = manager.wait(&id).expect("wait");
        assert_ne!(status.exit_code, Some(0), "{status:?}");
        let out = manager.output(&id).expect("output after kill");
        assert!(out.text.contains("started"));
        assert!(out.exit.is_some());
        manager.release(&id).expect("release");
    }

    /// 等退出的回调（BACKLOG P0，2026-09-24）：跑着时登记的在退出那一下回调、只回一次；release（先 kill）之后照样回调；
    /// 退出之后登记的当场回调；不认识的 id 报错。整个过程不占调用方线程。
    #[test]
    fn on_exit_fires_once_on_exit_and_immediately_after() {
        let manager = TerminalManager::new(Arc::new(Recorder::default()));
        let mut spec = if cfg!(windows) {
            let mut s = SpawnSpec::new("cmd.exe");
            s.args = vec!["/c".into(), "ping -n 30 127.0.0.1 > nul".into()];
            s
        } else {
            let mut s = SpawnSpec::new("sh");
            s.args = vec!["-c".into(), "sleep 30".into()];
            s
        };
        spec.cwd = Some(std::env::temp_dir());
        let id = manager.spawn(spec, TerminalSource::Agent).expect("spawn");
        let (tx, rx) = std::sync::mpsc::channel::<ExitStatus>();
        for _ in 0..2 {
            let tx = tx.clone();
            manager
                .on_exit(&id, move |s| {
                    let _ = tx.send(s.clone());
                })
                .expect("on_exit");
        }
        assert!(rx.try_recv().is_err(), "still running: no callback yet");
        manager.release(&id).expect("release kills it");
        for _ in 0..2 {
            let status = rx.recv_timeout(KILL_CONFIRM).expect("callback after release");
            assert_ne!(status.exit_code, Some(0), "{status:?}");
        }
        assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "each callback fires once");

        let quick = manager.spawn(echo_spec(), TerminalSource::Agent).expect("spawn");
        let status = manager.wait(&quick).expect("wait");
        manager
            .on_exit(&quick, move |s| {
                let _ = tx.send(s.clone());
            })
            .expect("on_exit after exit");
        assert_eq!(rx.try_recv().expect("fired inline"), status);
        manager.release(&quick).expect("release");
        assert!(matches!(manager.on_exit(&quick, |_| {}), Err(PtyError::UnknownTerminal(_))));
    }

    /// `terminal/create` 的 shell 拼装路径（规则 9：Windows 上经 PowerShell，带引号与中文的参数、含空格与中文的 cwd）。
    #[test]
    fn spawn_shell_command_runs_through_the_system_shell() {
        let recorder = Arc::new(Recorder::default());
        let manager = TerminalManager::new(recorder.clone());
        let cwd = std::env::temp_dir().join(format!("acp pty 中文 目录-{}", std::process::id()));
        std::fs::create_dir_all(&cwd).expect("mkdir");
        let (command, args): (&str, Vec<String>) = if cfg!(windows) {
            ("Write-Output", vec!["含 空格 与 \"引号\" 的参数".into()])
        } else {
            ("printf", vec!["%s".into(), "含 空格 与 \"引号\" 的参数".into()])
        };
        let id = manager
            .spawn_shell_command(command, &args, vec![("ACP_TEST_VAR".into(), "1".into())], Some(cwd.clone()), Some(4096), TerminalSource::Agent)
            .expect("spawn");
        let status = manager.wait(&id).expect("wait");
        assert_eq!(status.exit_code, Some(0), "{status:?} output: {:?}", manager.output(&id));
        let out = manager.output(&id).expect("output");
        assert!(out.text.contains("含 空格 与 \"引号\" 的参数"), "output: {:?}", out.text);
        manager.release(&id).expect("release");
        let _ = std::fs::remove_dir_all(&cwd);
    }

    /// 规则 9：`.cmd` 包装（npm / npx 全局 bin）经 PowerShell 拉起——agent 给的 `command` 是裸名 `npm`，
    /// shell 自己按 PATHEXT 找到 `npm.cmd` 再经 cmd.exe 跑起来，输出正常回到 pty。
    #[cfg(windows)]
    #[test]
    fn spawn_shell_command_runs_cmd_wrappers_on_windows() {
        // 环境缺失就红，不跳过：Node ≥ 22 是本地开发前置，npm.cmd 随它来。
        let has_npm = std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()).any(|d| d.join("npm.cmd").is_file());
        assert!(has_npm, "npm.cmd not on PATH");
        let recorder = Arc::new(Recorder::default());
        let manager = TerminalManager::new(recorder.clone());
        let id = manager
            .spawn_shell_command("npm", &["--version".into()], Vec::new(), Some(std::env::temp_dir()), None, TerminalSource::Agent)
            .expect("spawn");
        let status = manager.wait(&id).expect("wait");
        assert_eq!(status.exit_code, Some(0), "{status:?} output: {:?}", manager.output(&id));
        let out = manager.output(&id).expect("output");
        assert!(out.text.trim().chars().next().is_some_and(|c| c.is_ascii_digit()), "npm --version output: {:?}", out.text);
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
