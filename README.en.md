# AcpAgent Client

[中文](README.md) | English

> A good-looking multi-agent desktop client. Every agent connects over the [Agent Client Protocol (ACP)](https://agentclientprotocol.com/), and any agent in the official registry works right after you install it.

Claude Agent, Codex, Cursor, pi and DeepSeek Harness share one interface: the same transcript cards, the same file and terminal panels, the same permission and authentication flows. Zed's built-in agent works too, through a sidecar that ships with the app. The app is a Flutter shell on top of a Rust core (an in-process cdylib bridged with flutter_rust_bridge v2), and the UI is built board by board from Claude Design mockups.

![Session workbench: session list on the left, transcript in the middle, settings on the right](docs/images/workbench.png)

*The session workbench. Left: sessions of the current project. Middle: the transcript (here a few terminal tool-call cards and rich text). Right: the settings panel.*

## Features

Everything revolves around the session workbench. The design mockups set the feature boundary: the sources and PNG baselines of all 45 boards are indexed in [`design/README.md`](design/README.md).

- **Transcript**: Markdown body (syntax highlighting, GFM tables, Mermaid, math), collapsible thinking blocks, tool-call cards (including failed and cancelled ones), file diffs, embedded terminals, sub-agent delegation, plans, context compaction, and image / audio / resource content blocks. Whole turns fold, and each turn ends with token usage, cost and duration.
- **Composer**: `@` to reference context, `/` for commands, image paste and attachment chips, session config (mode, model, thought level and so on, as declared by the agent), and a popover showing context-window usage.
- **Permissions and interaction**: permission cards with scope selection, both elicitation kinds (form and URL), and Awaiting Confirmation.
- **Sessions**: the sidebar lists only the current project's sessions, newest user message first. Running sessions show a sweep indicator and finished ones an unread dot. A timeline popover jumps between turns, and user bubbles offer Restore and Regenerate.
- **Four right-side tabs**: file browser (source / preview), terminal, Agents, settings.
- **Agents**: pulls the official registry and supports both `npx` and `binary` distribution (binaries are checked against their sha256). If Node is missing, the app downloads a managed copy. Both auth methods are implemented: Agent Auth (the agent opens a browser) and Terminal Auth (the login command runs in the built-in terminal). Agent configs can be imported from Zed's `settings.json`.
- **Appearance**: light, dark or follow-system theme. UI and code fonts each have separate Latin and CJK choices, four independent axes in all.
- **Debugging**: an ACP traffic panel that shows each redacted raw JSON-RPC line, also written to `logs/acp-<date>.log`.

![File browser panel](docs/images/files-panel.png)

*The file browser in the right column: lists directories per workspace and offers Source / Preview views of the selected file.*

## Supported agents

![Agents panel: the ACP Registry lists every entry with its install / sign-in state](docs/images/agents-registry.png)

Every registry entry can be installed (43 at the time of the screenshot). These six are first-class and fully verified end to end: install, authenticate, new session, a turn with tool calls and permissions, terminal, cancel, reopen and load history.

| Agent | Distribution | Authentication |
|---|---|---|
| Claude Agent (`claude-agent-acp`) | npx | Agent Auth / Terminal Auth, or environment variables |
| Codex (`codex-acp`) | npx (bundles the codex binary) | ChatGPT sign-in via URL elicitation, or `OPENAI_API_KEY` |
| Cursor (`agent acp`) | binary (archives for six platforms) | `agent login` (Terminal Auth) or `--api-key` |
| pi (`pi-acp`) | npx | Terminal Auth `--terminal-login` |
| DeepSeek Harness (`dsh-acp-interactive`) | built into the core, no setup needed | Terminal Auth `--setup` |
| Zed Agent (`zed-agent-acp`) | sidecar shipped with the installer | reuses the local Zed model and key config, read-only |

## Installation

**Windows x64.** Grab one file from [Releases](https://github.com/ClickPM/AcpAgentClient/releases):

| Artifact | Notes |
|---|---|
| `AcpAgentClient-<version>-setup.exe` | Per-user installer into `%LOCALAPPDATA%\Programs\AcpAgentClient`, no UAC prompt. **Unsigned**: SmartScreen blocks it the first time, so choose "More info → Run anyway" |
| `AcpAgentClient-<version>-windows-x64.zip` | Portable, unzip and run. Includes the Zed Agent sidecar |
| `AcpAgentClient-<version>-windows-x64-nosidecar.zip` | Same without the sidecar, over 60 MB smaller. The trade-off is no Zed Agent in the agent list |

npx-based agents need Node ≥ 22 on the system. Without it, the app downloads its own managed Node.

User data lives in `%APPDATA%\AcpAgentClient\` (`settings.json`, the session index, installed agents, logs). Installing and uninstalling never touch it.

**There are no macOS or Linux builds yet**, see "Status" below.

### Getting started

1. Pick a project directory in the top bar. Sessions and the file panel both use it as the workspace.
2. Right column **Agents** → install an agent → authenticate as its card says (browser or built-in terminal).
3. Create a session and send your first message.

## Building from source

Prerequisites: Rust stable, Flutter stable, `flutter_rust_bridge_codegen`, the Visual Studio 2022 "Desktop development with C++" workload, and Node ≥ 22. Upstream sources are pinned in [`pins/upstream.json`](pins/upstream.json) and not committed, so fetch them first:

```powershell
powershell -File scripts/fetch-upstream.ps1          # first-time fill of vendor/upstream/
powershell -File scripts/fetch-upstream.ps1 -Check   # verify the pins
```

From Git Bash use `scripts/fetch-upstream.sh [--check]`. Then:

```powershell
powershell -File scripts/validate.ps1          # build + tests + contract checks (-Quick runs static checks only)
powershell -File scripts/build.ps1             # flutter build windows --release
powershell -File scripts/build-sidecar.ps1     # Zed Agent sidecar (separate workspace, cold build about 50 minutes)
powershell -File scripts/package.ps1           # zip and installer → dist/
```

Output goes to `build/windows/x64/runner/Release/`. The sidecar lands in `build/sidecar/` first and a CMake install rule copies it next to the app. If it is missing the build still succeeds; there is just no Zed Agent in the agent list.

If the project path contains non-ASCII characters or spaces, use `scripts/build.ps1` only: a bare `flutter build windows` mangles such paths. More prerequisites and local pitfalls are under "本地开发" (local development) in [`CLAUDE.md`](CLAUDE.md). There is a one-line index of the scripts in [`scripts/README.md`](scripts/README.md) and a test layout guide in [`test/README.md`](test/README.md).

## Status

Current release: **v1.4.6**, Windows x64. Per-version changes are on [Releases](https://github.com/ClickPM/AcpAgentClient/releases), and development rounds and the progress table are in [`ROUNDS.md`](ROUNDS.md). As of 2026-09-22 the R0–R8 core is done and the project is in agile iterations. Day-to-day bug fixes, UX polish and single-board features follow the iteration process in [`iterations/`](iterations/README.md): one file per iteration, one line per item, one review round. The round process is reserved for major core work.

v1.4.6 fixes two everyday problems:

- Fans spinning up while an agent runs a long command: always-on animations (spinners, the sidebar sweep line) now run on a shared low-rate clock (about 15 ticks/s in the foreground, 4 when the window is inactive, stopped when minimized). In the same scenario, foreground integrated-GPU usage drops from 45.8% to 6.0%.
- Output that arrives after a turn ends: when an agent keeps going after `end_turn`, the turn's conclusion is no longer folded away with the late content. Late entries appear below the conclusion, and the view follows them while pinned to the bottom.

It also adds this English README. Both fixes passed cursor review with zero findings before merging (iteration-14 and 15 in [`iterations/`](iterations/README.md)).

v1.4.5 closes the last seven BACKLOG P0 items:

- Local state files: read-modify-write now runs under per-file, in-process write locks.
- Resources: the terminal view no longer freezes past 64 K characters of output, agents read large files as a stream, and each connection has a cap on open terminals.
- Routing: with two agents online, permission and form cards no longer go to the wrong agent. Restore during concurrent runs no longer makes the stop button disappear. Deleting a running session sends `session/cancel` first.

It also closes two P1 items on streaming render performance (linear diffs with lazily built diff bodies; long answers re-parse only their tail, and code highlighting is cached). The bundled DeepSeek Harness moves to 1.3.2, which stores sessions in `~/.dsh/acp-sessions` rather than the process working directory. Each batch passed cursor review with zero findings before merging (iteration-10 to 13 in [`iterations/`](iterations/README.md), and [`rounds/round-dsh-1.3.2`](rounds/round-dsh-1.3.2/round-dsh-1.3.2.md)).

v1.4.4 brought:

- Session identity and lifecycle (four BACKLOG P0 items):
  - A session load that fails midway no longer leaves half a transcript.
  - Sending routes by the session's state relative to the current connection, instead of silently replacing the selected session.
  - After a reload or crash, other sessions of the same agent reattach automatically before sending.
  - A session created after authentication no longer lands in the old directory if you switched projects during sign-in.
- Board 09, "waiting for you": sessions in the background with pending permission or form requests are flagged in the sidebar and badged in the project switcher.
- Shell-level toasts for failures that used to go only to the log, including "session is loading".
- A follow-system theme.
- Visible IME composition in the terminal.
- Reclaiming agents that are still handshaking on exit.

Its code changes since v1.4.3 were reviewed as a whole and passed four cursor review rounds down to zero findings ([`rounds/round-1.4.4`](rounds/round-1.4.4/round-1.4.4.md)).

v1.4.3 brought:

- Board 53, registry update checks and upgrades. A new version installs next to the old one and switches only after it passes, so a failed or cancelled upgrade leaves the old version usable.
- Two new ways to add paths from the composer: `+` → Files & Directories now goes through the `@` menu and accepts directories, and Ctrl+V pastes files and folders copied in Explorer as path references.
- Two owner-reported fixes: a maximized window overflowing the screen after minimize and restore, and typed text disappearing after a space in the terminal panel.
- Clearing out BACKLOG P5.

Its code changes since v1.4.2 were reviewed as a whole and passed two full cursor review rounds with zero findings ([`rounds/round-1.4.3`](rounds/round-1.4.3/round-1.4.3.md)).

Not done yet: macOS and Linux builds, and installer signing. Cross-round to-dos and open decisions are in [`rounds/BACKLOG.md`](rounds/BACKLOG.md).

## Architecture

```
Flutter host process (Dart frontend ⇄ frb v2 ⇄ Rust core cdylib)
   │ stdio · ACP JSON-RPC
   ├── claude-agent-acp / codex-acp / pi-acp     npx
   ├── cursor `agent acp`                        binary
   ├── dsh-acp-interactive                       custom (built into the core, no setup needed)
   └── zed-agent-acp                             sidecar (headless gpui + Zed's built-in agent, shipped with the app)
```

Three constraints hold throughout:

- There is no gpui in the main process; anything that needs gpui goes into the sidecar.
- The frontend consumes the raw JSON of ACP wire messages as-is and has no special cases for any agent.
- The registry, installs, authentication, and terminal and fs callbacks all live in the Rust core.

## Documentation

The documents below are written in Chinese.

| File | Contents |
|---|---|
| [`docs/background.md`](docs/background.md) | Why this exists: the predecessor, why ACP, why Flutter + Rust |
| [`docs/requirements.md`](docs/requirements.md) | The authoritative scope: must-haves, non-goals, dependency allowlist |
| [`docs/design.md`](docs/design.md) | Process model, core–frontend contract, auth, registry, terminal and fs, sidecar, data directory |
| [`docs/acp-projection.md`](docs/acp-projection.md) | What can be projected: the 15 `session/update` variants, capability gates, the 8 things a client must build itself |
| [`docs/research.md`](docs/research.md) | Source-level research: Zed's ACP code, rust-sdk, registry, the five agents, rejected approaches |
| [`design/README.md`](design/README.md) | Board index: each board's `.dc.html` source, PNG baseline and implementation status |
| [`iterations/README.md`](iterations/README.md) | The agile iteration process (day-to-day mode since 2026-09-22) and the list of iterations; rounds are reserved for major core work |
| [`CLAUDE.md`](CLAUDE.md) | Development conventions, the round and iteration processes, hard rules (`AGENTS.md` is a pointer for reviewers) |

## License

**GPL-3.0-or-later**; see [`LICENSE`](LICENSE) for the full text. Open source; the project itself is non-commercial.

The license follows from reusing Zed source code. Fifteen files under `rust/` and `sidecar/` are copied-and-adapted or transcribed from Zed, each with the upstream path and commit in its header. [`NOTICE`](NOTICE) lists them, together with the sources of the ACP spec, rust-sdk and registry (Apache-2.0), the bundled fonts (OFL-1.1) and the icons, plus trademark notices.
