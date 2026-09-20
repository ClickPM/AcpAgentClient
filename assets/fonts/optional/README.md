# 可选字体放这里

画板 70「外观」小节的字体切换里，除随包默认项之外的候选，字体文件放这个目录。
**这个目录下的字体文件永不入库**（`.gitignore` 里只放行本文件），构建时由 `windows/CMakeLists.txt`
的 install 规则拷到可执行文件旁的 `fonts/`，运行时由 `lib/app/appearance_prefs.dart` 注册进引擎。

## 为什么不像 Geist / Noto Sans SC 那样进 `pubspec.yaml`

两个原因，缺一不可：

1. **许可证**。MiSans 与 HarmonyOS Sans 都允许「嵌入 App 一起分发」，但都禁止「在独立基础上」再分发字体
   文件本身。公开的 git 仓库里躺着一份可单独取出的 `.ttf`，正是被禁的那种情况。不入库、只随安装包走，
   才落在两份协议明确允许的那一格。
2. **构建**。`pubspec.yaml` 里声明了字体却没有文件，`flutter build` 会直接失败。走运行时注册之后，
   仓库里一个可选字体都没有也能正常构建与测试，文件放进来就自动点亮。

随包的三款（Geist / Geist Mono / Noto Sans SC）都是 OFL 1.1，可以入库，所以仍在 `pubspec.yaml` 里。

## 怎么放

文件直接平铺在本目录，只认 `.ttf` 与 `.otf`（`.ttc` 字体集合 `FontLoader` 吃不下，会被跳过）。
同一款字体的多个字重一起放，它们会注册进同一个 family，w400 / w500 两档都能匹配到。
本项目只用到 Regular（400）与 Medium（500）两档，放这两个就够；放全套也不会出错，只是包体变大。

文件名不必改，探测按「小写后只留字母数字、再看是不是以某个主干开头」来匹配
（`lib/app/appearance_prefs.dart` 的 `fileStems`）：

| 字体 | 认得的文件名形如 | 许可 | 官方下载 |
|---|---|---|---|
| MiSans | `MiSans-Regular.ttf`、`MiSans-Medium.ttf` | 小米自有协议 · 免费商用 | <https://hyperos.mi.com/font/download> |
| HarmonyOS Sans SC | `HarmonyOS_Sans_SC_Regular.ttf` | 华为自有协议 · 免费商用 | <https://developer.huawei.com/consumer/cn/design/resource/> |
| Inter | `Inter-Regular.ttf`、`InterVariable.ttf` | OFL 1.1 | <https://rsms.me/inter/> |
| JetBrains Mono | `JetBrainsMono-Regular.ttf` | OFL 1.1 | <https://www.jetbrains.com/lp/mono/> |
| Cascadia Mono | `CascadiaMono.ttf` | OFL 1.1 | <https://github.com/microsoft/cascadia-code/releases> |
| 更纱黑体 Sarasa Mono SC | `Sarasa-Mono-SC-Regular.ttf` | OFL 1.1 | <https://github.com/be5invis/Sarasa-Gothic/releases> |

要加新候选，先在 `lib/app/appearance_prefs.dart` 的 `fontCatalog` 里添一条（带 `fileStems` 与 `downloadUrl`），
`test/app/appearance_prefs_test.dart` 会检查新条目有没有漏填、以及有没有破坏「西文轴与中文轴候选不重叠」这条不变量。

## 分发时要注意的两件事

- **不得修改**：MiSans 与 HarmonyOS Sans 的协议都不允许改字体，所以不能 subset 精简，只能整份放。
  MiSans SC 全量单字重约 10MB 量级，HarmonyOS Sans 的包约 21.6MB，放进安装包前先想清楚体积。
- **必须注明**：两份协议都要求在软件里显著说明用了该字体。随包分发前需要有一个「关于 / 致谢」的去处，
  目前设计稿里还没有这块（记在 `rounds/BACKLOG.md`）。**只在本机自用时不涉及这条**，
  它只在把安装包发给别人时才成立。

用户也可以不动这个目录，自己把字体装进系统，或者丢进数据目录（`%APPDATA%/AcpAgentClient/fonts/`），
两者都会被探测到；装进系统的那种由平台按家族名直接解析，我们不重复注册。
