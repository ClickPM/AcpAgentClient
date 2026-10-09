v1.4.9 将 main 上的两项 UI 改进正式出包：精简 Active 会话行的连接状态文案，以及将重载按钮提示纠正为 `Reload Agent`。不改变会话挂载、挂起或重载逻辑。

## 下载哪一个

| 文件 | 说明 |
|---|---|
| `AcpAgentClient-1.4.9-setup.exe` | per-user 安装到 `%LOCALAPPDATA%\Programs\AcpAgentClient`，无需管理员权限 |
| `AcpAgentClient-1.4.9-windows-x64.zip` | 免安装，解压即用 |

Windows 10 / 11 x64。**安装包未签名**，SmartScreen 首次可能拦截，选择「更多信息 → 仍要运行」。
用户数据在 `%APPDATA%\AcpAgentClient`，安装与卸载不删除它。npx 型 agent 需要 Node ≥ 22，没有时应用可下载受管 Node。

## 变更

- **Active 会话行更简洁**：副标题只显示时间与消息数，去掉重复的「· 已连接」；图标在线绿点、Active 分组与 Connected 提示保留。同步更新画板 45 与侧栏测试。
- **准确标明重载范围**：按钮 tooltip 从 `Reload this session` 改为 `Reload Agent`。只纠正文案，不改变现有重载行为、不新增确认框。
- 补齐工程研究、迭代与上版发布记录。

## 验收与校验

完整 `validate.ps1` 通过，622 项 Flutter 测试全过。正式 Windows 构建自检通过；zip 解压运行与安装器静默安装 → 运行 → 卸载均通过，核心版本 1.4.9。本次发布按所有者指示不追加独立审查。

SHA-256：

```
e812b693ad44e70be1638cf696d0a0b9f98514b9e1685a153344c4e87399b4b9  AcpAgentClient-1.4.9-windows-x64.zip
54a2d9659667d425da1d35124addeb696c66d0e67224e2fb5dc91bd39671fae4  AcpAgentClient-1.4.9-setup.exe
```

## 已知限制

- Send Now 打断回合期间关闭 / 挂起会话的竞态仍在 BACKLOG，本版未修复。
- 本版只提供 Windows x64 构建。
