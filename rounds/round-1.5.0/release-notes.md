v1.5.0 将两轮已审查的修复正式出包，重点改善展开工具卡与最小化窗口时的资源占用，并让代码块复制反馈更容易看清。

## 下载哪一个

| 文件 | 说明 |
|---|---|
| `AcpAgentClient-1.5.0-setup.exe` | per-user 安装到 `%LOCALAPPDATA%\Programs\AcpAgentClient`，无需管理员权限 |
| `AcpAgentClient-1.5.0-windows-x64.zip` | 免安装，解压即用 |

Windows 10 / 11 x64。**安装包未签名**，SmartScreen 首次可能拦截，选择「更多信息 → 仍要运行」。
用户数据在 `%APPDATA%\AcpAgentClient`，安装与卸载不删除它。npx 型 agent 需要 Node ≥ 22，没有时应用可下载受管 Node。

## 变更

- **避免 JSON 展开体每帧重算**：工具卡及流量面板局部缓存格式化字符串与语法高亮树，输入、主题或字体变化时正确失效。
- **最小化后持续处理会话消息**：无帧时以微任务刷新，并迁走已挂起的帧回调，避免队列只进不出；还原后恢复按帧合并。
- **复制反馈更清晰**：Copied 保持 1.8 秒，后续在途复制成功重置计时；代码块卸载时取消计时器。
- **减少验收偶发失败**：终端释放集成测试改用有界条件等待，不改变生产断开逻辑。
- 保留 v1.4.9 的 Active 行精简、Reload Agent 文案和全部历史；两轮台账因编号冲突调整为 iteration-23、24。

## 验收与校验

两轮修复分别经所有者指定的 Delta / Grok 4.7 只读审查，均 0 条 findings。1.5.0 完整 validate 通过（632 项 Flutter 测试及 Rust / 静态门），Windows release 自检与 zip / 安装器装卸验收均通过；核心版本 1.5.0，droppedEvents 0。

SHA-256：

```
46596426c5d47eb72c631cb8ea25a32ca45e84733c36bce8fe491a6c2adf4541  AcpAgentClient-1.5.0-windows-x64.zip
5c35514532f5de6c38b380b1b4083371b1bcb4eef77e8ef51a98898243474311  AcpAgentClient-1.5.0-setup.exe
```

## 已知限制

- Windows 真窗口长任务的内存曲线未实测，不宣称修复所有内存增长原因。
- Send Now 打断回合期间关闭 / 挂起会话的竞态仍在 BACKLOG，本版未修复。
- 本版只提供 Windows x64 构建。
