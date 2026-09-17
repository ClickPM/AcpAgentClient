//! Derived from zed-industries/zed crates/eval_cli/src/headless.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)
//!
//! 复制（CLAUDE.md 规则 5 的第二种复用方式）。相对原文的改动只有三处，其余逐行照抄：
//! 1. `user_agent` 改成本 sidecar 的名字；
//! 2. **不设** `acp_thread::HeadlessTerminal(true)` —— eval CLI 没有控制终端所以关 PTY，
//!    本 sidecar 是被桌面应用拉起的普通子进程，终端要按 Zed 正常路径跑（画板 22 / 23 要真实输出）；
//! 3. `agent_ui::init` 的 `is_new_install` 传 false（我们不是首次安装的 Zed），`is_eval` 传 false
//!    （eval 会跳过从用户 settings 读模型配置，而本 sidecar 恰恰要沿用 Zed 的 settings.json，
//!    见 docs/design.md § 8「模型密钥沿用 Zed 的 settings.json / 环境变量」）；
//! 4. 去掉 `languages::init` —— `languages` crate 没进依赖（原因见 Cargo.toml 里那段注释：
//!    它依赖的 `pet` 要 VS 的 Spectre 缓解库，本机没装）。`LanguageRegistry` 照样建、照样传给
//!    `Project` 与 `agent_ui`，只是里面没有注册任何语言。

use std::path::PathBuf;
use std::sync::Arc;

use client::{Client, ProxySettings, RefreshLlmTokenListener, UserStore};
use db::AppDatabase;
use extension::ExtensionHostProxy;
use fs::RealFs;
use gpui::http_client::read_proxy_from_env;
use gpui::{App, AppContext as _, Entity};
use gpui_tokio::Tokio;
use language::LanguageRegistry;
use language_extension::LspAccess;
use node_runtime::{NodeBinaryOptions, NodeRuntime};
use project::project_settings::ProjectSettings;
use prompt_store::PromptBuilder;
use release_channel::{AppCommitSha, AppVersion};
use reqwest_client::ReqwestClient;
use settings::{Settings, SettingsStore};
use util::ResultExt as _;

pub struct AgentAppState {
    pub languages: Arc<LanguageRegistry>,
    pub client: Arc<Client>,
    pub user_store: Entity<UserStore>,
    pub fs: Arc<dyn fs::Fs>,
    pub node_runtime: NodeRuntime,
}

pub fn init(cx: &mut App) -> Arc<AgentAppState> {
    let app_commit_sha = option_env!("ZED_COMMIT_SHA").map(|s| AppCommitSha::new(s.to_owned()));

    let app_version = AppVersion::load(
        env!("ZED_PKG_VERSION"),
        option_env!("ZED_BUILD_ID"),
        app_commit_sha,
    );

    release_channel::init(app_version.clone(), cx);
    gpui_tokio::init(cx);

    let settings_store = SettingsStore::new(cx, &settings::default_settings());
    cx.set_global(settings_store);
    theme_settings::init(theme::LoadThemes::JustBase, cx);

    let user_agent = format!(
        "zed-agent-acp/{} ({}; {})",
        app_version,
        std::env::consts::OS,
        std::env::consts::ARCH
    );
    let proxy_str = ProxySettings::get_global(cx).proxy.to_owned();
    let proxy_url = proxy_str
        .as_ref()
        .and_then(|input| input.parse().ok())
        .or_else(read_proxy_from_env);
    let http = {
        let _guard = Tokio::handle(cx).enter();
        ReqwestClient::proxy_and_user_agent(proxy_url, &user_agent)
            .expect("could not start HTTP client")
    };
    cx.set_http_client(Arc::new(http));

    let client = Client::production(cx);
    cx.set_http_client(client.http_client());

    let app_db = AppDatabase::new();
    cx.set_global(app_db);

    let git_binary_path = None;
    let fs = RealFs::new(git_binary_path, cx.background_executor().clone());
    <dyn fs::Fs>::set_global(fs.clone(), cx);

    let mut languages = LanguageRegistry::new(cx.background_executor().clone());
    languages.set_language_server_download_dir(paths::languages_dir().clone());
    let languages = Arc::new(languages);

    let user_store = cx.new(|cx| UserStore::new(client.clone(), cx));

    extension::init(cx);

    let (mut node_options_tx, node_options_rx) = watch::channel(None);
    cx.observe_global::<SettingsStore>(move |cx| {
        let settings = &ProjectSettings::get_global(cx).node;
        let options = NodeBinaryOptions {
            allow_path_lookup: !settings.ignore_system_version,
            allow_binary_download: true,
            use_paths: settings.path.as_ref().map(|node_path| {
                let node_path = PathBuf::from(shellexpand::tilde(node_path).as_ref());
                let npm_path = settings
                    .npm_path
                    .as_ref()
                    .map(|path| PathBuf::from(shellexpand::tilde(&path).as_ref()));
                (
                    node_path.clone(),
                    npm_path.unwrap_or_else(|| {
                        let base_path = PathBuf::new();
                        node_path.parent().unwrap_or(&base_path).join("npm")
                    }),
                )
            }),
        };
        node_options_tx.send(Some(options)).log_err();
    })
    .detach();
    let node_runtime = NodeRuntime::new(client.http_client(), None, node_options_rx);

    let extension_host_proxy = ExtensionHostProxy::global(cx);
    debug_adapter_extension::init(extension_host_proxy.clone(), cx);
    language_extension::init(LspAccess::Noop, extension_host_proxy, languages.clone());
    language_model::init(cx);
    RefreshLlmTokenListener::register(client.clone(), user_store.clone(), cx);
    language_models::init(user_store.clone(), client.clone(), cx);
    prompt_store::init(cx);
    terminal_view::init(cx);

    let stdout_is_a_pty = false;
    let prompt_builder = PromptBuilder::load(fs.clone(), stdout_is_a_pty, cx);
    agent_ui::init(
        fs.clone(),
        prompt_builder,
        languages.clone(),
        false,
        false,
        cx,
    );

    Arc::new(AgentAppState {
        languages,
        client,
        user_store,
        fs,
        node_runtime,
    })
}
