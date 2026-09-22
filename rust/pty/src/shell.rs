//! `terminal/create` 的命令拼装：agent 给的是 `command` + `args`，要经系统 shell 跑（管道 / 重定向 / `.cmd` 包装都靠它）。
//! Derived from zed-industries/zed crates/util/src/shell_builder.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//! （`ShellBuilder::build` + `redirect_stdin_to_dev_null` 的组合规则；引号规则转写自同仓库 crates/util/src/shell.rs 的
//! `quote_windows` / `quote_powershell` / `quote_pwsh` / `quote_cmd`，Windows 的默认 shell 探测精简自
//! crates/gpui_util/src/lib.rs 的 `get_powershell` / `get_windows_system_shell`。去掉了 nushell / fish 等我们不接的 shell，
//! 也去掉了 Zed 的沙箱包装。）
//!
//! Windows（CLAUDE.md 规则 9）：首选 PowerShell（pwsh 7 → Windows PowerShell 5.1），`-C "$null | & {<command> <args>}"`；
//! `.cmd` / `.bat` 包装（npx、npm 全局 bin）由 PowerShell 自己经 cmd 拉起，引号按 PowerShell 的规则转义；
//! 找不到 PowerShell 才退到 `cmd.exe /S /C`。其他平台 `sh -c "exec </dev/null\n<command> <args>"`。

use std::borrow::Cow;
use std::path::Path;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellKind {
    Posix,
    /// Windows PowerShell 5.1（`powershell.exe`）。
    PowerShell,
    /// PowerShell 7+（`pwsh.exe`）。
    Pwsh,
    Cmd,
}

impl ShellKind {
    pub fn of_program(program: &str) -> Self {
        let last = program.rsplit(|c| matches!(c, '/' | '\\')).next().unwrap_or(program);
        let name = Path::new(last)
            .file_stem()
            .map(|s| s.to_string_lossy().to_ascii_lowercase())
            .unwrap_or_default();
        match name.as_str() {
            "pwsh" => ShellKind::Pwsh,
            "powershell" => ShellKind::PowerShell,
            "cmd" => ShellKind::Cmd,
            _ => ShellKind::Posix,
        }
    }
}

/// 一次 shell 拉起：程序 + 参数（参数直接进 `CommandBuilder`，不再过一层 shell）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShellCommand {
    pub program: String,
    pub args: Vec<String>,
    pub kind: ShellKind,
}

/// 系统默认 shell（`terminal/create` 与终端面板的本地 shell 共用）。
pub fn default_shell() -> (String, ShellKind) {
    #[cfg(windows)]
    {
        if let Some(p) = find_powershell() {
            let kind = ShellKind::of_program(&p);
            return (p, kind);
        }
        let system_root = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
        let cmd = PathBuf::from(system_root).join("System32").join("cmd.exe");
        (cmd.to_string_lossy().into_owned(), ShellKind::Cmd)
    }
    #[cfg(not(windows))]
    {
        (std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string()), ShellKind::Posix)
    }
}

/// 终端面板（画板 61）的交互 shell 参数：PowerShell 去掉启动横幅，其余不加。
pub fn interactive_args(kind: ShellKind) -> Vec<String> {
    match kind {
        ShellKind::PowerShell | ShellKind::Pwsh => vec!["-NoLogo".to_string()],
        ShellKind::Cmd | ShellKind::Posix => Vec::new(),
    }
}

/// pwsh 7 → Windows PowerShell 5.1：先 PATH，再固定安装位置。
#[cfg(windows)]
fn find_powershell() -> Option<String> {
    if let Some(p) = which("pwsh.exe") {
        return Some(p);
    }
    if let Some(pf) = std::env::var_os("ProgramFiles") {
        let pwsh = PathBuf::from(pf).join("PowerShell").join("7").join("pwsh.exe");
        if pwsh.is_file() {
            return Some(pwsh.to_string_lossy().into_owned());
        }
    }
    if let Some(p) = which("powershell.exe") {
        return Some(p);
    }
    let system_root = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
    let ps = PathBuf::from(system_root)
        .join("System32")
        .join("WindowsPowerShell")
        .join("v1.0")
        .join("powershell.exe");
    ps.is_file().then(|| ps.to_string_lossy().into_owned())
}

#[cfg(windows)]
fn which(name: &str) -> Option<String> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .filter(|d| !d.as_os_str().is_empty())
        .map(|d| d.join(name))
        .find(|p| p.is_file())
        .map(|p| p.to_string_lossy().into_owned())
}

/// 把 agent 的 `command` + `args` 拼成一条 shell 调用（Zed `ShellBuilder::build` + `redirect_stdin_to_dev_null`）：
/// 有 args 时 command 本身也过引号规则；没有 args 时 command 原样交给 shell（agent 常把整条命令行放在 command 里）。
pub fn build(program: &str, kind: ShellKind, command: &str, args: &[String]) -> ShellCommand {
    let command_part: Cow<'_, str> = if args.is_empty() {
        Cow::Borrowed(command)
    } else {
        quote(kind, command)
    };
    let mut combined = command_part.into_owned();
    for a in args {
        combined.push(' ');
        combined.push_str(&quote(kind, a));
    }
    let shell_args = match kind {
        ShellKind::PowerShell | ShellKind::Pwsh => {
            // stdin 接空：命令要交互式读输入就会立刻 EOF，而不是挂在那里等 agent。
            vec!["-C".to_string(), format!("$null | & {{{combined}}}")]
        }
        ShellKind::Cmd => vec!["/S".to_string(), "/C".to_string(), format!("\"{combined}< NUL\"")],
        ShellKind::Posix => vec!["-c".to_string(), format!("exec </dev/null\n{combined}")],
    };
    ShellCommand { program: program.to_string(), args: shell_args, kind }
}

/// 按 shell 种类给一个参数加引号（Zed `ShellKind::try_quote`）。
pub fn quote(kind: ShellKind, arg: &str) -> Cow<'_, str> {
    match kind {
        ShellKind::PowerShell => quote_powershell(arg),
        ShellKind::Pwsh => quote_pwsh(arg),
        ShellKind::Cmd => quote_cmd(arg),
        ShellKind::Posix => quote_posix(arg),
    }
}

/// POSIX：只含安全字符原样，否则单引号包起来（内部的 `'` 写成 `'\''`）。
fn quote_posix(arg: &str) -> Cow<'_, str> {
    if arg.is_empty() {
        return Cow::Borrowed("''");
    }
    let safe = arg
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '/' | ':' | '=' | '+' | '@' | '%' | ','));
    if safe {
        return Cow::Borrowed(arg);
    }
    let mut out = String::with_capacity(arg.len() + 2);
    out.push('\'');
    for c in arg.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    Cow::Owned(out)
}

/// MSVCRT 的命令行引号规则（Zed `quote_windows`）：空格 / tab / `"` 触发；反斜杠只在引号前加倍。
fn quote_windows(arg: &str, enclose: bool) -> Cow<'_, str> {
    if arg.is_empty() {
        return Cow::Borrowed("\"\"");
    }
    let needs_quoting = arg.chars().any(|c| c == ' ' || c == '\t' || c == '"');
    if !needs_quoting {
        return Cow::Borrowed(arg);
    }
    let mut result = String::with_capacity(arg.len() + 2);
    if enclose {
        result.push('"');
    }
    let chars: Vec<char> = arg.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\\' {
            let mut num_backslashes = 0;
            while i < chars.len() && chars[i] == '\\' {
                num_backslashes += 1;
                i += 1;
            }
            if i < chars.len() && chars[i] == '"' {
                for _ in 0..(num_backslashes * 2 + 1) {
                    result.push('\\');
                }
                result.push('"');
                i += 1;
            } else if i >= chars.len() {
                for _ in 0..(num_backslashes * 2) {
                    result.push('\\');
                }
            } else {
                for _ in 0..num_backslashes {
                    result.push('\\');
                }
            }
        } else if chars[i] == '"' {
            result.push('\\');
            result.push('"');
            i += 1;
        } else {
            result.push(chars[i]);
            i += 1;
        }
    }
    if enclose {
        result.push('"');
    }
    Cow::Owned(result)
}

fn needs_quoting_powershell(s: &str) -> bool {
    s.is_empty()
        || s.chars().any(|c| {
            c.is_whitespace()
                || matches!(
                    c,
                    '"' | '`' | '$' | '&' | '|' | '<' | '>' | ';' | '(' | ')' | '[' | ']' | '{' | '}' | ',' | '\'' | '@'
                )
        })
}

fn need_quotes_powershell(arg: &str) -> bool {
    let mut quote_count = 0;
    for c in arg.chars() {
        if c == '"' {
            quote_count += 1;
        } else if c.is_whitespace() && (quote_count % 2 == 0) {
            return true;
        }
    }
    false
}

fn escape_powershell_quotes(s: &str) -> String {
    let mut result = String::with_capacity(s.len() + 4);
    result.push('\'');
    for c in s.chars() {
        if c == '\'' {
            result.push('\'');
        }
        result.push(c);
    }
    result.push('\'');
    result
}

/// Windows PowerShell 5.1：先按 MSVCRT 规则处理引号，再整体单引号（5.1 传参给原生程序时会再拆一次）。
pub fn quote_powershell(arg: &str) -> Cow<'_, str> {
    let ps_will_quote = need_quotes_powershell(arg);
    let crt_quoted = quote_windows(arg, !ps_will_quote);
    if !needs_quoting_powershell(arg) {
        return crt_quoted;
    }
    Cow::Owned(escape_powershell_quotes(&crt_quoted))
}

/// pwsh 7：只需单引号包起来。
pub fn quote_pwsh(arg: &str) -> Cow<'_, str> {
    if arg.is_empty() {
        return Cow::Borrowed("''");
    }
    if !needs_quoting_powershell(arg) {
        return Cow::Borrowed(arg);
    }
    Cow::Owned(escape_powershell_quotes(arg))
}

/// cmd：MSVCRT 引号 + `^` 转义元字符，`%` 用 `%%cd:~,%` 打断变量展开。
pub fn quote_cmd(arg: &str) -> Cow<'_, str> {
    let crt_quoted = quote_windows(arg, true);
    let needs_cmd_escaping = crt_quoted.contains(['"', '%', '^', '<', '>', '&', '|', '(', ')']);
    if !needs_cmd_escaping {
        return crt_quoted;
    }
    let mut result = String::with_capacity(crt_quoted.len() * 2);
    for c in crt_quoted.chars() {
        match c {
            '^' | '"' | '<' | '>' | '&' | '|' | '(' | ')' => {
                result.push('^');
                result.push(c);
            }
            '%' => result.push_str("%%cd:~,%"),
            _ => result.push(c),
        }
    }
    Cow::Owned(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn powershell_wraps_command_and_quotes_args() {
        let c = build("pwsh.exe", ShellKind::Pwsh, "git", &["log".into(), "--pretty=format:%h - %s (%cr) <%an>".into()]);
        assert_eq!(c.args[0], "-C");
        assert_eq!(c.args[1], "$null | & {git log '--pretty=format:%h - %s (%cr) <%an>'}");
        // 没有 args 时整条命令原样交给 shell（管道 / 重定向都由 shell 解释）。
        let whole = build("pwsh.exe", ShellKind::Pwsh, "git log | Select-Object -First 5", &[]);
        assert_eq!(whole.args[1], "$null | & {git log | Select-Object -First 5}");
        // 5.1 与 7 的引号差异：5.1 对含空格的参数先加 MSVCRT 引号再单引号。
        let ps51 = build("powershell.exe", ShellKind::PowerShell, "echo", &["a b".into()]);
        assert_eq!(ps51.args[1], "$null | & {echo 'a b'}");
        // 含空格的参数 PowerShell 自己会加一层引号（`need_quotes_powershell`），这里只转义内层的 `"`，再整体单引号。
        let quoted = quote_powershell("say \"hi\"");
        assert_eq!(quoted, "'say \\\"hi\\\"'");
        // 不含空格但含 `"` 的参数：MSVCRT 那层要自己加引号。
        assert_eq!(quote_powershell("a\"b"), "'\"a\\\"b\"'");
    }

    #[test]
    fn cmd_and_posix_forms() {
        let c = build(r"C:\Windows\System32\cmd.exe", ShellKind::Cmd, "echo", &["a b".into(), "x&y".into()]);
        assert_eq!(c.args, vec!["/S", "/C", "\"echo ^\"a b^\" x^&y< NUL\""]);
        let p = build("/bin/sh", ShellKind::Posix, "ls", &["-la".into(), "my dir".into(), "it's".into()]);
        assert_eq!(p.args, vec!["-c", "exec </dev/null\nls -la 'my dir' 'it'\\''s'"]);
    }

    #[test]
    fn kind_of_program_by_file_stem() {
        assert_eq!(ShellKind::of_program(r"C:\Program Files\PowerShell\7\pwsh.exe"), ShellKind::Pwsh);
        assert_eq!(ShellKind::of_program(r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"), ShellKind::PowerShell);
        assert_eq!(ShellKind::of_program("cmd.exe"), ShellKind::Cmd);
        assert_eq!(ShellKind::of_program("/bin/bash"), ShellKind::Posix);
    }

    #[cfg(windows)]
    #[test]
    fn default_shell_on_windows_is_powershell_when_present() {
        let (program, kind) = default_shell();
        assert!(Path::new(&program).is_file(), "{program}");
        assert!(matches!(kind, ShellKind::Pwsh | ShellKind::PowerShell | ShellKind::Cmd));
    }
}
