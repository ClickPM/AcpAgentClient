//! zed-agent-acp：把 Zed 内置 agent 包成一个标准的 ACP agent 进程（stdio 上的 JSON-RPC）。
//!
//! 主进程（Flutter + rust/ cdylib）把它当成普通的 custom 型 agent 拉起，走和其他五个 agent
//! 完全一样的路（docs/design.md § 8、ROUNDS.md R7）；gpui 只活在本进程里（CLAUDE.md 规则 5）。
//!
//! 线程模型：gpui 的 `App` 不是 `Send`，而 ACP SDK 的 handler 必须 `Send`，所以两边各占一条路
//! （细节在 [`bridge`]）：
//! - **入站**：SDK handler（跑在专用传输线程上）把 `(请求, Responder)` 装成 [`bridge::Incoming`]
//!   丢进 mpsc，gpui 前台的 dispatcher 取出来执行，回应由 `Responder` 直接送回；
//! - **出站**：gpui 侧直接持有 `ConnectionTo<Client>`（内部是 mpsc sender，`Send` 且发送是同步的）。
//!
//! 除 stdout 之外的一切输出走 stderr：stdout 是 JSON-RPC 通道。

mod bridge;
mod headless;
mod meta_keys;
mod session;
mod translate;

use std::process::ExitCode;

fn main() -> ExitCode {
    // ACP agent 独占 stdout，日志一律 stderr。RUST_LOG 没设时只留 warn 以上。
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn"))
        .target(env_logger::Target::Stderr)
        .init();

    let mut args: Vec<String> = std::env::args().skip(1).collect();

    // 两个路径开关，都必须在任何人读 `paths::*` **之前**处理（`set_custom_data_dir` 之后再调会 panic）：
    //
    // - `--user-data-dir <dir>`：把 Zed 的配置与数据目录（settings.json、threads.db、logs、prompts）
    //   整体挪到 `<dir>` 下。主程序默认会传自己数据目录里的一个子目录，**不**和本机 Zed 共用
    //   `threads.db`：R7 实测同时写会让**正在跑的 Zed** 存线程失败（`database is locked`，
    //   Zed 日志 `crates/agent/src/agent.rs:1861`）。
    // - `--zed-settings <file>`：照样从本机 Zed 真正的 settings.json 读模型与密钥配置
    //   （docs/design.md § 8），与数据目录搬到哪儿无关。两个开关配合 = 「配置共用、数据隔离」。
    let zed_settings = match take_flag(&mut args, "--zed-settings") {
        Ok(value) => value.map(std::path::PathBuf::from),
        Err(()) => {
            eprintln!("zed-agent-acp: --zed-settings 后面要给一个文件路径");
            return ExitCode::FAILURE;
        }
    };
    match take_flag(&mut args, "--user-data-dir") {
        Ok(Some(dir)) => {
            paths::set_custom_data_dir(&dir);
        }
        Ok(None) => {}
        Err(()) => {
            eprintln!("zed-agent-acp: --user-data-dir 后面要给一个目录");
            return ExitCode::FAILURE;
        }
    }

    match args.first().map(String::as_str) {
        Some("--version") => {
            println!("zed-agent-acp {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some("--help") | Some("-h") => {
            println!(
                "zed-agent-acp — Zed 内置 agent 的 ACP 包装\n\n\
                 用法：zed-agent-acp [--user-data-dir <dir>] [--zed-settings <file>] [--acp | --selftest]\n\n\
                 不带参数（或带 --acp）时在 stdin / stdout 上说 ACP v1；\n\
                 --selftest 只跑一次无头启动自检，不进 ACP 循环；\n\
                 --user-data-dir 把 Zed 的配置与数据目录挪到别处（默认与本机 Zed 共用）；\n\
                 --zed-settings 指定要读的 Zed settings.json（默认读 --user-data-dir 下的那份）。"
            );
            ExitCode::SUCCESS
        }
        Some("--selftest") => run(true, zed_settings),
        None | Some("--acp") => run(false, zed_settings),
        Some(other) => {
            eprintln!("zed-agent-acp: 未知参数 {other}；--help 看用法");
            ExitCode::FAILURE
        }
    }
}

/// 取走 `--flag <value>` 这一对；没有这个 flag 返回 `Ok(None)`，有 flag 但没跟值返回 `Err(())`。
fn take_flag(args: &mut Vec<String>, flag: &str) -> Result<Option<String>, ()> {
    let Some(i) = args.iter().position(|a| a == flag) else {
        return Ok(None);
    };
    let Some(value) = args.get(i + 1).cloned() else {
        return Err(());
    };
    args.drain(i..=i + 1);
    Ok(Some(value))
}

fn run(selftest: bool, zed_settings: Option<std::path::PathBuf>) -> ExitCode {
    let http_client = std::sync::Arc::new(reqwest_client::ReqwestClient::new());
    let app = gpui_platform::headless().with_http_client(http_client);

    let exit = std::sync::Arc::new(std::sync::atomic::AtomicU8::new(0));
    let exit_for_app = exit.clone();
    app.run(move |cx| {
        let app_state = headless::init(cx);
        let settings_path = zed_settings
            .clone()
            .unwrap_or_else(|| paths::settings_file().clone());
        if selftest {
            bridge::selftest(app_state, settings_path, exit_for_app, cx);
        } else {
            bridge::serve(app_state, settings_path, exit_for_app, cx);
        }
    });

    ExitCode::from(exit.load(std::sync::atomic::Ordering::SeqCst))
}
