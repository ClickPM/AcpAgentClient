// 一轮对话（R7.5 从 workbench_controller.dart 拆出）：发送 / 取消 / 权限与 elicitation 回应 / Restore 与 Regenerate（画板 11）、
// 会话配置（画板 40 的下拉与开关、modes 回退）、agent 终端的停止方块（画板 23）、`+` 的 Sessions 用的本地转录文本。
// 读当前会话（store / agentId / 关闭态、现开会话、索引写回、画板 06 的绿点）走 [session]，取输入框正文与附件走 [composer]；
// 会话控制器不知道有轮（任务卡附录 B 唯一保留的「协议对象之间」的依赖，方向固定：轮读会话控制器）。

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../projection/entries.dart';
import '../projection/pending.dart';
import '../projection/session_store.dart';
import '../projection/wire.dart';
import 'composer_state.dart';
import 'core_bridge.dart';
import 'guarded.dart';
import 'session_controller.dart';

class TurnController extends ChangeNotifier with GuardedNotifier {
  TurnController({required this.bridge, required this.session, required this.composer});

  final CoreCommands? bridge;

  /// 当前会话（组合根持有）。
  final SessionController session;

  /// 输入框（组合根持有）：正文、附件块、配置格的弹层锚点。
  final ComposerState composer;

  // ---------------------------------------------------------------- 一轮对话

  /// `session/close` 之后这条会话是**只读**的：所有会往它发命令的入口共用这一道门
  /// （prompt / Restore / Regenerate / 三个下拉；审查第 2 轮 P2：第 1 轮只挡住了 `send()`）。
  bool _blockedByClose() {
    if (!session.sessionClosed) return false;
    lastError = '这个会话已经关闭；用 ≡ 菜单的 Resume 挂回来，或新建一个会话';
    touch();
    return true;
  }

  /// 「选了 agent 但还没有会话」时，第一条消息现开一条：在途期间挡住重复点发送。
  bool _startingSession = false;

  Future<void> send() async {
    final b = bridge;
    final id = session.agentId;
    if (b == null || id == null) return;
    if (composer.editor.text.trim().isEmpty && composer.pendingBlocks.isEmpty) return; // 空输入不开会话
    // 启动后的画板 01 状态 1：agent 已选、会话还没开（进程也没拉）。第一条消息把它开出来，
    // 失败（认证 / 缺 Node）时 `newSession` 已经把错误与认证页安排好，输入框里的文本原样留着。
    // 守卫看 `store`（= 没有可用转录）。已知问题：选中的会话只是**载不回**转录时 `store` 也是 null，
    // 于是这里会开一条新会话把选中的那条静默顶掉（审查 finding P2）。两轮针对性整改都在别处引入了
    // 新缺陷（改 `sessionId` 判据 → 不支持 loadSession 的 agent 按发送零响应；加能力判据 →
    // 覆盖掉 `newSession` 安排好的认证 / 缺 Node 报错，且能力未知时仍会顶掉），
    // 所有者裁定 2026-09-18：回退到出厂行为，记 `rounds/BACKLOG.md` 等单独一轮做。
    if (session.store == null) {
      if (_startingSession) return;
      _startingSession = true;
      try {
        await session.newSession(session.agentRefOf(id));
      } finally {
        _startingSession = false;
      }
    }
    // 静默 return 是有意的：走到这里说明 `newSession` 失败了，而它的每条失败路径都已经把
    // 真实原因写进会话控制器的 `lastError`（认证 / 缺 Node / 没选项目目录）并安排好认证页，这里再写一句会盖掉它。
    final s = session.store;
    if (s == null) return;
    if (_blockedByClose()) return;
    // 快照要取在开会话之后：拉起进程 + `initialize` + `session/new` 要几百毫秒到数秒，
    // 这期间新打的字与新加的附件也得发出去，否则下面的 clear 会把它们静默抹掉（审查 finding P2，2026-09-18）。
    final blocks = _promptBlocks(composer.editor.text);
    if (blocks.isEmpty) return;
    composer.clearForSend();
    // 又开了一轮：上一轮留下的绿点立即撤（画板 06 D「运行中 · 绿点：无（有则立即撤）」）。
    session.clearUnread(s.sessionId);
    s.startTurn(<ContentBlockWire>[for (final b in blocks) ContentBlockWire(b)]);
    unawaited(session.stampPromptSent());
    await _runTurn(b, id, s, blocks);
  }

  /// 在途的那一轮（`session/prompt` 还没返回）。Restore / Regenerate 要先等它结束，
  /// 否则同一个 session 上会重叠两个 `session/prompt`，先返回的那次会把 `endTurn` 打到新开的轮上
  /// （审查 finding high，2026-09-15）。
  Future<void>? _turnInFlight;

  Future<void> _runTurn(CoreCommands b, String id, SessionStore s, List<JsonMap> blocks) async {
    final turn = () async {
      try {
        final result = await b.sessionPrompt(id, s.sessionId, blocks);
        final stopReason = result['stopReason'] as String?;
        s.endTurn(
          stopReason: stopReason,
          usage: result['usage'] is Map ? (result['usage'] as Map).cast<String, dynamic>() : null,
        );
        session.markDone(s.sessionId, stopReason);
        // 只刷消息计数：`updatedAt` 沿用发消息时打的那个（见 `SessionIndex.upsert`）。
        // 写的是**刚跑完这一轮的那条**（`s`）而不是当前选中的：会话可以并跑，后台那条跑完时前台往往是另一条。
        await session.saveIndex(target: s);
      } catch (e) {
        // 失败也必须收轮：不收的话 `currentTurn` 一直挂着，会话头永远转 spinner、发送位永远是停止键，
        // 之后的 Restore 还会拿新连接去操作一个 agent 侧已不存在的 sessionId（审查第 2 轮 finding P2，2026-09-15）。
        // `stopReason` 留空：连接断了本来就没有协议给的结束值，不编一个（规则 2）；原因走 `TurnEntry.error`，
        // 由画板 31 的结束行显示——只记 `lastError` 的话整条错误在界面上无处可见，用户只看到一个 `?` 徽章
        // （2026-09-18 实测：dsh 回 `-32602 model does not declare image input` 与 `-32603 turn failed`，界面全无提示）。
        final message = describeError(e);
        s.endTurn(error: message);
        lastError = message;
        debugPrint('[workbench] session/prompt failed: $message');
      }
    }();
    _turnInFlight = turn;
    try {
      await turn;
    } finally {
      if (identical(_turnInFlight, turn)) _turnInFlight = null;
    }
    touch();
  }

  /// 输入框正文 + 附件块。`/` 命令按 unstructured 口径原样作为一条 text 块发出（docs/design.md § 3）。
  List<JsonMap> _promptBlocks(String text) {
    final trimmed = text.trim();
    return <JsonMap>[
      if (trimmed.isNotEmpty) <String, dynamic>{'type': 'text', 'text': text},
      ...composer.pendingBlocks,
    ];
  }

  Future<void> cancel() async {
    final s = session.store;
    final b = bridge;
    final id = session.agentId;
    if (s == null || b == null || id == null) return;
    // 停止方块也是往会话发命令的入口：`closeSession` 里的 `s.cancel()` 不收轮（`isRunning` 还是 true），
    // 作曲器禁用态下 Stop 仍会渲染，点下去就把 `session/cancel` 打到已经释放掉的会话上（审查第 3 轮 P2）。
    if (_blockedByClose()) return;
    await guard(() async {
      // 权限请求由核心自动回 cancelled（api.rs 的契约），前端再回会撞 unknown_request；
      // **elicitation 核心不管**，不回 agent 会一直等（审查 finding high，2026-09-15）。
      await b.sessionCancel(id, s.sessionId);
      final result = s.cancel();
      for (final requestId in result.cancelledElicitationIds) {
        await guard(() => b.acpRespond(id, requestId, PendingQueue.cancelledAction));
      }
    });
    touch();
  }

  Future<void> answerPermission(String requestId, String optionId) async {
    final s = session.store;
    final b = bridge;
    final id = session.agentId;
    if (s == null) return;
    final payload = s.answerPermission(requestId, optionId);
    if (payload == null || b == null || id == null) return;
    await guard(() => b.acpRespond(id, requestId, payload));
  }

  Future<void> answerElicitation(String requestId, String action, JsonMap? content) async {
    final s = session.store;
    final b = bridge;
    final id = session.agentId;
    if (s == null) return;
    final payload = s.answerElicitation(requestId, action, content: content);
    if (payload == null || b == null || id == null) return;
    await guard(() => b.acpRespond(id, requestId, payload));
  }

  /// 用户气泡上的 Restore 与 Regenerate（画板 11）：从这条用户消息本地截断 + 同会话重发
  /// （截断点是消息本身而不是轮边界：`session/load` 重放回来的历史没有轮边界，见 `restoreTo` 的注释）。
  /// （画板 10 的 Restore Checkpoint 分隔线已废弃，所有者裁定 2026-09-17：与这里是同一个动作。）
  /// **截断范围内仍挂起的请求必须回应**，否则 agent 一直等着：permission 回 cancelled outcome、
  /// elicitation 回 cancelled action（`RestoreResult` 的两组 id）。
  Future<void> restore(MessageEntry message, {String? newText}) async {
    final s = session.store;
    if (s == null) return;
    // 关掉的会话不能 Restore / Regenerate：`restoreTo` 会先把本地转录截断，随后的 `session/prompt`
    // 必然失败，本地就少了一截而 agent 侧还是关闭前那份（审查第 2 轮 P2）。
    if (_blockedByClose()) return;
    // 先把在途的那一轮收干净（发 cancel 并等 session/prompt 真正返回），再截断重发。
    if (s.isRunning) {
      await cancel();
      await _turnInFlight;
    }
    final result = s.restoreTo(message.id);
    if (result == null) return;
    await _respondCancelled(result);
    final blocks = <JsonMap>[
      if (newText != null && newText.trim().isNotEmpty)
        <String, dynamic>{'type': 'text', 'text': newText}
      else
        for (final b in result.prompt) b.json,
    ];
    if (blocks.isEmpty) return;
    final b = bridge;
    final id = session.agentId;
    if (b == null || id == null) {
      touch();
      return;
    }
    session.clearUnread(s.sessionId);
    s.startTurn(<ContentBlockWire>[for (final x in blocks) ContentBlockWire(x)]);
    unawaited(session.stampPromptSent());
    await _runTurn(b, id, s, blocks);
  }

  /// 把被截断的挂起请求逐条回应（顺序无所谓，但一条都不能漏）。
  Future<void> _respondCancelled(RestoreResult result) async {
    final b = bridge;
    final id = session.agentId;
    if (b == null || id == null) return;
    for (final requestId in result.cancelledRequestIds) {
      await guard(() => b.acpRespond(id, requestId, PendingQueue.cancelledOutcome));
    }
    for (final requestId in result.cancelledElicitationIds) {
      await guard(() => b.acpRespond(id, requestId, PendingQueue.cancelledAction));
    }
  }

  // ---------------------------------------------------------------- 会话配置

  Future<void> setConfigOption(String configId, JsonMap value) async {
    composer.hideConfigPopovers();
    final s = session.store;
    final b = bridge;
    final id = session.agentId;
    if (s == null || b == null || id == null) return;
    if (_blockedByClose()) return;
    await guard(() async {
      final result = await b.sessionSetConfigOption(id, s.sessionId, configId, value);
      s.applyConfigOptionsResponse(result);
    });
    touch();
  }

  Future<void> selectConfigValue(String configId, String value) {
    // modes 回退（R6）：合成条目的 id 是本地哨兵，不能当 configId 发出去——它走 `session/set_mode`。
    if (configId == SessionStore.modeFallbackId) return setMode(value);
    return setConfigOption(configId, <String, dynamic>{'type': 'select', 'value': value});
  }

  /// `session/set_mode`（modes 回退路径）。响应是空的；按规范客户端发起的切换成功即生效，
  /// 所以本地同步 `currentModeId`（agent 自己改模式时会另发 `current_mode_update`）。
  Future<void> setMode(String modeId) async {
    composer.hideConfigPopovers();
    final s = session.store;
    final b = bridge;
    final id = session.agentId;
    if (s == null || b == null || id == null) return;
    if (_blockedByClose()) return;
    await guard(() async {
      await b.sessionSetMode(id, s.sessionId, modeId);
      s.applyModeSelected(modeId);
    });
    touch();
  }

  Future<void> toggleConfigBoolean(String configId, bool value) =>
      setConfigOption(configId, <String, dynamic>{'type': 'boolean', 'value': value});

  ConfigOptionWire? optionOf(String category) {
    for (final o in session.store?.configOptions ?? const <ConfigOptionWire>[]) {
      if (o.category == category) return o;
    }
    // modes 回退（R6）：只发 modes / `current_mode_update`、不发 configOptions 的 agent，
    // 模式下拉用 `SessionStore.modeFallbackOption` 合成的那条；两者都有时上面的循环已经命中，走不到这里。
    if (category == 'mode') return session.store?.modeFallbackOption;
    return null;
  }

  /// 输入框右下的固定档序（所有者裁定 2026-09-18）：`mode → model → model_config → thought_level → 其余`，
  /// 档内保持 agent 给的数组顺序、同一档可以有多条。ACP 的 category 是开放集合（schema：
  /// `Mode | Model | ModelConfig | ThoughtLevel | Other(String)`，字段本身还可缺省，`_` 开头的是 agent 自定义），
  /// 所以匹配不上的一律排进最后一档、一条一格，不丢条目（spec v1 session-config-options：
  /// 「Clients MUST handle missing or unknown categories gracefully」）。boolean 型也在这条列表里，就地渲染成开关。
  /// 与 Zed 的差别只在顺序：Zed 照 agent 给的数组顺序排，我们按档序排（换 agent 时输入框的位置稳定）。
  static const List<String> _categoryOrder = <String>['mode', 'model', 'model_config', 'thought_level'];

  List<ConfigOptionWire> get composerOptions {
    final all = session.store?.configOptions ?? const <ConfigOptionWire>[];
    final ordered = <ConfigOptionWire>[];
    for (final category in _categoryOrder) {
      // modes 回退（R6）：没有 `category == 'mode'` 的 configOption 时才合成，排在 mode 档的头一格。
      if (category == 'mode') {
        final fallback = session.store?.modeFallbackOption;
        if (fallback != null) ordered.add(fallback);
      }
      for (final o in all) {
        if (o.category == category) ordered.add(o);
      }
    }
    for (final o in all) {
      if (!_categoryOrder.contains(o.category)) ordered.add(o);
    }
    return ordered;
  }

  /// 按 id 取当前那一份（弹层要在每次 rebuild 时重新读，`set_config_option` 的响应是全量替换）。
  ConfigOptionWire? optionById(String id) {
    for (final o in composerOptions) {
      if (o.id == id) return o;
    }
    return null;
  }

  /// 挂起队列的首项（画板 26 的停靠条）。
  TranscriptEntry? get firstPending {
    final s = session.store;
    if (s == null) return null;
    final list = s.pending.forSession(s.sessionId);
    return list.isEmpty ? null : list.first;
  }

  // ---------------------------------------------------------------- agent 终端（画板 23）与本地转录文本

  /// 画板 23 的停止方块（agent 建的终端）：`terminal_kill` = `terminal/kill` 语义，退出状态随 `acp/terminal_output` 回来。
  Future<void> killTerminal(String terminalId) async {
    final b = bridge;
    if (b == null) return;
    try {
      await b.terminalKill(terminalId);
    } catch (e) {
      // `_meta` 通道喂出来的终端 id 是 agent 的 toolUseId，核心没有这个 pty：协议里没有能停它的动作，
      // 不算错误、也不标 killed（审查 finding，2026-09-16）。
      final text = describeError(e);
      if (!text.contains('unknown terminal')) {
        lastError = text;
        touch();
      }
      return;
    }
    session.store?.markTerminalKilled(terminalId);
  }

  /// 本地转录文本（`+` 的 Sessions）：把当前会话的消息拼成一份 embedded resource。
  String transcriptText() {
    final s = session.store;
    if (s == null) return '';
    final buffer = StringBuffer();
    for (final e in s.entries) {
      if (e is! MessageEntry) continue;
      buffer.writeln('[${e.role.name}] ${e.blocks.map((b) => b.text ?? '').where((t) => t.isNotEmpty).join('')}');
    }
    return buffer.toString();
  }
}
