# 上游与设计协同

> 相关：`AGENTS.md` 规则 4（钉版本）/ 规则 3（设计稿是功能边界）、[`release-pipeline.md`](release-pipeline.md)、
> `design/README.md`（画板索引）、`design/DIVERGENCE.md`（实现与画板的偏移清单）。

## 1. 怎么把设计画板从画布拉回仓库

设计工具是 **Claude Design**（所有者裁定 2026-09-14）。画布 URL 形如 `claude.ai/design/p/<projectId>`，
产物是每画板一个 `.dc.html`（设计唯一事实来源）+ 一张 PNG（验收基准）+ 一份仓库这边手维护的 `canvas.json`。

### 首选路径：内置 DesignSync 工具（上一代 agent 的执行器专属）

> ⚠️ 这一条是 **Claude Code 专属**的：本机**没有** `claude_design` MCP，但它的内置 `DesignSync` 工具在所有者做过
> `/design-login` 之后就能直读这个设计项目。**换 agent 后这条不成立**，走下面的「绕法」，或者自己实现一个等价的读取。

- `get_project` / `list_files` / `get_file` 传 `projectId` 即可，`get_file` 返回的就是**干净的源文件**，
  和仓库里的 `.dc.html` 逐字节一致（2026-09-18 用画板 06 对过：34,673 字节、LF）。
- 项目 type 是 `PROJECT_TYPE_PROJECT` 不是 design system，所以 `list_projects` **列不出它**（那个方法只列 design-system 项目），**必须按 projectId 点名**。
- 工具描述说「只配合 /design-sync skill 用」，那是对**写**方法（`finalize_plan` / `write_files`）说的；**读方法没有权限提示**，拉画板只用读。

### 绕法（2026-09-18 实测可用，比上面麻烦）

1. 用**已登录 claude.ai 的浏览器**打开画布页（内置浏览器没有登录态，会被弹到 `/login`）。
2. 页面里调 Connect-RPC：

   ```js
   fetch('https://claude.ai/design/anthropic.omelette.api.v1alpha.OmeletteService/ListFiles', {
     method: 'POST',
     headers: { 'content-type': 'application/json', 'connect-protocol-version': '1' },
     body: JSON.stringify({ projectId }),
   })
   ```

   `GetFile` 同形状加 `path`，返回 base64。
3. 不想把内容读进上下文，就从 `performance.getEntriesByType('resource')` 里挑一个
   `*.claudeusercontent.com/...?t=<token>` 取出预览 token，在 **PowerShell** 里
   `Invoke-WebRequest ".../v1/design/projects/<projectId>/serve/<画板>.dc.html?t=<token>" -OutFile <仓库路径>`
   （页面里 fetch 这个域会被 CORS 挡，`curl` / `IWR` 不会）。
4. `serve` 与 Connect-RPC 的 `GetFile` 拿到的都是**注入过的**版本：`<html>\n<head>\n` 之后多一大段
   `data-omelette-injected` 的 style + script。还原成仓库那份干净源文件就是把 `<head>\n` 到 `<meta charset="utf-8">` 之间整段删掉。
   （`DesignSync` 的 `get_file` 没有这层注入。）

### 覆盖前必须判「画布是不是比本地新」

**画布未必比本地新**（2026-09-20 实测）：设计师在画布上改了画板 01 / 02 / 03（加 history 按钮），
但画布上那三张还停在 `72e2be1` 的版本，缺本地 `4e59ef3`「R3 手测整改 2」的六处 32→36 与分栏把手注脚 ——
**整份拉回来就把那次整改静默回退了**。

判据：`$preview` 高度对不上（本地 1976 / 1004，画布 1900 / 960）就说明两边分过叉。
这种时候别整份覆盖，**只把新增的那一段按画布的写法插进本地文件**（用 Python 按唯一锚点 replace，插入位置与缩进照抄画布），
再重渲 PNG，并在 `design/README.md` 的变更记录里写明「这张没有整份拉回来」。
稳妥起见覆盖前先 `git log` 那张画板。

### 落盘之后

- `powershell -File scripts/render-design.ps1 -Only <编号>` 出 PNG，再更新 `design/README.md` 索引表与 `design/round-design/canvas.json`。
- **`canvas.json` 线上没有**，是仓库这边手维护的，坐标要自己按同页其他画板排。
- **新画板的 `$preview` 可能只写了宽**（2026-09-23 画板 09）：`render-design.ps1` 要 `{"width":…,"height":…}`，缺高直接 throw。
  高度去设计方交回的 `delivery/canvas.json` 补进 `$preview` 再渲（那份画布布局与仓库的不同，**只取该画板的 `h`**），渲完看一眼底部没截断。

## 2. 改上游（以 dsh-acp-interactive 为例）

`dsh-acp-interactive` 是所有者自己的仓库（本地 `D:\variFlight_work\dsh-acp-interactive`，`（本机）`）。

**发版的远端是 `github`（ClickPM）**，不是 `origin`（Cursor 托管，落后好几版；
本地 `main` 却跟踪 `origin`，拉最新要 `git fetch github` + `merge --ff-only github/main`）。
发版 = 一个 `release: x.y.z …` 提交（`package.json` / lock / `registry/agent.json` **两处** /
`docs/compatibility*.md` / 双语 CHANGELOG）→ 推 `github main` + 注解 tag `vX.Y.Z` →
`release.yml` 走 trusted publishing 发 npm。（2026-09-24 发 1.3.2 按这个流程走通。）

### 四个环境坑（2026-09-24 实测，都是「看着失败、其实和改动无关」）

- 拉完先 **`npm ci`**：`node_modules` 会停在旧基线。
- **`npm run test:harness`** 要兄弟目录 `../deepseek-harness` 里有 `config/upstream-baseline.json` 钉的 tag
  （没有就先 `git fetch upstream tag <ref> --no-tags`）；**在 Git Bash 里跑会报 `spawnSync tar EOF`，换 PowerShell（Windows 自带 bsdtar）就过**。
- **`npm run check:profile`** 读的是兄弟目录的**工作区**，不是钉住的 tag；上游一前进就报 `candidatePackages` 漂移。
  用 `git worktree add --detach D:\hrc3 <tag>` 临时检出，再用 `DSH_HARNESS_ROOT` 指过去
  （scratchpad 路径太长、超 MAX_PATH），用完 `git worktree remove`。
- 发布后自动触发的 **Registry auth check** 会先于 npm 可见启动，报 `notarget` 失败；
  `npm view <pkg> dist-tags` 显示新版后 `gh workflow run registry-auth.yml --ref vX.Y.Z -f version=X.Y.Z` 重跑即过。

### 客户端侧跟着改钉版本

按规则 4 的顺序：改 `pins/upstream.json` → 改 `docs/research.md` 对应段 → fetch → 改
`rust/acp-core/src/builtin.rs` 的 `DSH_PACKAGE`。

- **本机 `%APPDATA%\npm` 里有全局安装的 dsh，内置条目优先用它**（`（本机）`）；npx 钉版本只在没有全局安装的机器上生效。
  要测 npx 那条路，就在 PATH 里摘掉 `%APPDATA%\npm`。
- **改钉版本的分支合进 main 后，要把主副本 `vendor/upstream/<name>` 也挪到新 commit**
  （`git -C <dir> fetch --depth 1 origin <commit>` + `checkout FETCH_HEAD`，和 fetch 脚本同样两步），否则 main 的 `-Check` 报 DRIFT；
  代价是其余用目录联接指向主副本的 worktree 在合 main 之前都会报 DRIFT（2026-09-24 有 4 个）—— **汇报时点名**。
  开发期间自己分支的 worktree 里，改了钉版本的那个上游单独 fetch 一份、其余照旧联接，就不影响别人。
- **`acp-smoke` 验不了 dsh 的存储**：它 prompt 完就强杀进程树、不发 `session/close`，
  而 dsh 只在模型请求 / 工具派发 / 步骤完成时落盘。验存储要自己写 ACP 客户端脚本走 close
  （见 `rounds/round-dsh-1.3.2` 任务卡验收 7），并且放 `D:\` 下（见 [`harness-pitfalls.md`](harness-pitfalls.md)）。

## 3. 本机生图网关（`（本机）`）

需要生成图标 / 素材时可以走 OpenAI 兼容网关 `https://api.cking000.com/v1`，
**key 在用户级环境变量 `CLIPROXY_API_KEY`**（直接 `-H "Authorization: Bearer $CLIPROXY_API_KEY"`，**别 echo 出来** —— 规则 8）。
`/v1/models` 上有 25 个模型，生图的是 `gpt-image-2`（所有者口中的「image2」）、`gpt-image-1.5`、`gpt-image-2.5*`、`gemini-3.1-flash-image`。

**两种线协议不同**：

- `gpt-image-2` → `POST /v1/images/generations`，`size:"1024x1024"` 生效，回 `data[0].b64_json`，PNG 1254×1254。
- `gemini-3.1-flash-image` → `POST /v1/chat/completions`，图在 `choices[0].message.images[].image_url.url` 的 data URL 里。
  **回的是 JPEG 不是 PNG，且默认 16:9（1408×768）把图标缩在中间**；
  prompt 里显式写「Square 1:1, the tile fills the frame edge to edge」才给 1024×1024。存盘前按 `\xff\xd8\xff` magic 判扩展名。

六张并发跑完约 60 s。`gemini` CLI 装了但没登录（报 `Please set an Auth method ... GEMINI_API_KEY`），要用它得先 `gemini` 交互登录一次。
另一条路（`imagegen_providers_list`）只是那个站点自己 `generate_image` 工具的配置、key 只回掩码，拿不到凭据。
