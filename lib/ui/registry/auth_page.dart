// 画板 52 · agent 认证：认证方式选择（authMethods 的 agent 型 / terminal 型）、terminal auth 的可见终端、
// 成功后自动重试新会话、失败态（重试 / 换一种方式）、无会话阶段的 URL elicitation（requestScope）。
// 落在右栏 Agents 标签内（docs/design.md § 5 第 5 条），不落转录。方法列表来自 `initialize.authMethods` 原样 JSON，
// 描述文字优先用方法自带的 `description`，没有时按类型给一句协议事实（不按 agent 名特判，规则 2）。样式只取 tokens。

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart' as xt;

import '../../projection/entries.dart';
import '../../projection/tool_calls.dart';
import '../../projection/wire.dart';
import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import '../transcript/terminal_card.dart';

/// 认证页所处的阶段。
enum AuthPhase {
  /// 选方法。
  choose,

  /// 已发出 `authenticate` / 已在 pty 里拉起 terminal auth，等它结束。
  running,

  /// 认证成功，正在自动重试 `session/new`。
  succeeded,

  /// 失败（`authenticate` 报错、terminal 退出后重试仍回 `-32000`）。
  failed,
}

class AuthPage extends StatelessWidget {
  const AuthPage({
    super.key,
    required this.agentName,
    required this.authMethods,
    this.message,
    this.selectedMethodId,
    this.phase = AuthPhase.choose,
    this.terminalLabel,
    this.terminalBuffer,
    this.error,
    this.requestScope = const <ElicitationEntry>[],
    this.onSelectMethod,
    this.onStart,
    this.onCancel,
    this.onRetry,
    this.onChangeMethod,
    this.onStopTerminal,
    this.onTerminalInput,
    this.onOpenUrl,
    this.onCancelElicitation,
  });

  /// 展示名（`initialize.agentInfo.title / name`，退到 settings 的键）。
  final String agentName;

  /// `initialize.authMethods` 原样（每条 `{id, name, description?, type?, args?, env?}`）。
  final List<JsonMap> authMethods;

  /// `-32000` 错误带的 message。
  final String? message;
  final String? selectedMethodId;
  final AuthPhase phase;

  /// terminal 型：方法名（画板 52 头行「terminal auth · …」）。
  final String? terminalLabel;

  /// terminal 型：`acp/terminal_output`（source = auth）的缓冲。
  final TerminalBuffer? terminalBuffer;
  final String? error;

  /// 无会话阶段的 URL elicitation（挂起或已打开的）。
  final List<ElicitationEntry> requestScope;
  final ValueChanged<String>? onSelectMethod;
  final VoidCallback? onStart;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onChangeMethod;
  final VoidCallback? onStopTerminal;
  final ValueChanged<String>? onTerminalInput;
  final ValueChanged<ElicitationEntry>? onOpenUrl;
  final ValueChanged<ElicitationEntry>? onCancelElicitation;

  static String methodType(JsonMap m) => m['type'] == 'terminal' ? 'terminal' : 'agent';

  @override
  Widget build(BuildContext context) {
    final buffer = terminalBuffer;
    return Container(
      color: t.Surface.canvas,
      child: ListView(
        padding: const EdgeInsets.all(t.Spacing.s16),
        children: <Widget>[
          AuthMethodPicker(
            agentName: agentName,
            authMethods: authMethods,
            message: message,
            selectedMethodId: selectedMethodId,
            running: phase == AuthPhase.running,
            onSelect: phase == AuthPhase.choose ? onSelectMethod : null,
            onStart: phase == AuthPhase.choose ? onStart : null,
            onCancel: onCancel,
          ),
          if (buffer != null && terminalLabel != null) ...<Widget>[
            const SizedBox(height: t.Spacing.s16),
            AuthTerminalCard(
              label: terminalLabel!,
              buffer: buffer,
              running: phase == AuthPhase.running && !buffer.exited,
              onStop: onStopTerminal,
              onInput: onTerminalInput,
            ),
          ],
          if (phase == AuthPhase.succeeded) ...<Widget>[const SizedBox(height: t.Spacing.s16), const AuthSucceededCard()],
          if (phase == AuthPhase.failed) ...<Widget>[
            const SizedBox(height: t.Spacing.s16),
            AuthFailedCard(error: error ?? '', onRetry: onRetry, onChangeMethod: onChangeMethod),
          ],
          for (final e in requestScope) ...<Widget>[
            const SizedBox(height: t.Spacing.s16),
            RequestScopeElicitationCard(e, agentName: agentName, onOpen: onOpenUrl == null ? null : () => onOpenUrl!(e), onCancel: onCancelElicitation == null ? null : () => onCancelElicitation!(e)),
          ],
        ],
      ),
    );
  }
}

/// 「认证方式选择」卡：头行（锁 + `<agent> 需要认证` + `session/new → -32000`）、单选列表、开始认证 / 取消。
class AuthMethodPicker extends StatelessWidget {
  const AuthMethodPicker({
    super.key,
    required this.agentName,
    required this.authMethods,
    this.message,
    this.selectedMethodId,
    this.running = false,
    this.onSelect,
    this.onStart,
    this.onCancel,
  });

  final String agentName;
  final List<JsonMap> authMethods;
  final String? message;
  final String? selectedMethodId;

  /// 已发出 `authenticate`（agent 型）：底栏换成 spinner + 等待文案。
  final bool running;
  final ValueChanged<String>? onSelect;
  final VoidCallback? onStart;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final selected = selectedMethodId ?? (authMethods.isEmpty ? null : authMethods.first['id'] as String?);
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: AcpIcon(AcpIcons.lock, color: t.Semantic.warning),
            title: '$agentName 需要认证',
            titleStyle: CardText.cardTitle,
            subtitle: 'session/new → -32000',
          ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.all(t.Spacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (authMethods.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(t.Spacing.s8),
                    child: Text(message ?? 'agent 没有公布 authMethods。', style: t.TextStyles.secondary),
                  ),
                for (final m in authMethods) _option(m, selected: (m['id'] as String?) == selected),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
            child: Row(
              children: <Widget>[
                if (running) ...<Widget>[
                  const Spinner(),
                  const SizedBox(width: t.Spacing.s8),
                  Expanded(child: Text('等待 $agentName 完成认证…', style: CardText.secondary)),
                ] else ...<Widget>[
                  AcpButton(label: '开始认证', kind: ButtonKind.primary, enabled: selected != null, onTap: onStart),
                  const SizedBox(width: t.Spacing.s4),
                ],
                AcpButton(label: '取消', onTap: onCancel),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _option(JsonMap m, {required bool selected}) {
    final id = m['id'] as String? ?? '';
    final type = AuthPage.methodType(m);
    final description = m['description'] as String? ??
        (type == 'terminal'
            ? '在内置终端里用附加的 args / env 重新拉起同一个 agent 程序（不是另给一条命令）。'
            : 'agent 自己完成认证（可能打开系统浏览器，或经 URL elicitation 让本页打开）。');
    return MouseRegion(
      cursor: onSelect == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSelect == null ? null : () => onSelect!(id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
          decoration: BoxDecoration(color: selected ? t.Overlays.hover : null, borderRadius: t.Radii.control),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(padding: const EdgeInsets.only(top: t.Spacing.s4), child: RadioDot(selected: selected)),
              const SizedBox(width: t.Spacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(child: Text(m['name'] as String? ?? id, style: t.TextStyles.body.copyWith(color: t.Neutral.strong, height: t.LineHeights.control), maxLines: 1, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: t.Spacing.s8),
                        ToneChip('$type 型', tone: ChipTone.neutral),
                      ],
                    ),
                    const SizedBox(height: t.Spacing.s4),
                    Text(description, style: t.TextStyles.secondary.copyWith(height: t.LineHeights.body)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 单选圆（画板 52）：14 圆环，选中时 accent 边 + 6 圆点。
class RadioDot extends StatelessWidget {
  const RadioDot({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) => Container(
        width: t.Geometry.radioSize,
        height: t.Geometry.radioSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? t.Accent.base : t.Borders.base, width: t.Borders.width),
        ),
        alignment: Alignment.center,
        child: selected
            ? Container(width: t.Geometry.radioDot, height: t.Geometry.radioDot, decoration: BoxDecoration(shape: BoxShape.circle, color: t.Accent.base))
            : null,
      );
}

/// terminal auth 的可见终端（画板 52）：头行（终端图标 + `terminal auth · <方法名>` + spinner + 停止方块）+ xterm。
/// 与画板 22 / 23 的终端卡同一套 xterm 主题；这里可输入（键盘经 [onInput] 写回 pty），退出后只读。
class AuthTerminalCard extends StatefulWidget {
  const AuthTerminalCard({super.key, required this.label, required this.buffer, this.running = true, this.onStop, this.onInput});

  final String label;
  final TerminalBuffer buffer;
  final bool running;
  final VoidCallback? onStop;
  final ValueChanged<String>? onInput;

  @override
  State<AuthTerminalCard> createState() => _AuthTerminalCardState();
}

class _AuthTerminalCardState extends State<AuthTerminalCard> {
  late final xt.Terminal _terminal = xt.Terminal(maxLines: t.Geometry.terminalScrollbackLines);
  int _written = 0;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = (data) => widget.onInput?.call(data);
    _sync();
    widget.buffer.addListener(_sync);
  }

  @override
  void didUpdateWidget(AuthTerminalCard old) {
    super.didUpdateWidget(old);
    if (old.buffer != widget.buffer) {
      old.buffer.removeListener(_sync);
      _written = 0;
      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);
      widget.buffer.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.buffer.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final out = widget.buffer.output;
    if (out.length < _written) {
      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);
      _written = 0;
    }
    if (out.length > _written) {
      // pty 的输出自带 \r\n；fixtures / 假数据只有 \n 时补上 \r。
      _terminal.write(out.substring(_written).replaceAll(RegExp(r'(?<!\r)\n'), '\r\n'));
      _written = out.length;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.buffer;
    final exit = b.exitCode;
    final exitLabel = exit != null ? 'Exit Code $exit' : (b.signal != null ? 'Signal ${b.signal}' : '');
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: AcpIcon(AcpIcons.terminal, color: t.Neutral.muted),
            title: 'terminal auth · ${widget.label}',
            trailing: <Widget>[
              if (widget.running) ...<Widget>[const Spinner(), StopSquareButton(onTap: widget.onStop)] else Text(exitLabel, style: t.TextStyles.monoMeta),
            ],
          ),
          Container(
            decoration: BoxDecoration(color: t.Neutral.panel, border: Border(top: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
            padding: const EdgeInsets.all(t.Spacing.s12),
            height: t.Geometry.authTerminalHeight,
            child: xt.TerminalView(
              _terminal,
              theme: terminalTokenTheme,
              textStyle: xt.TerminalStyle.fromTextStyle(CardText.code),
              readOnly: !widget.running,
              autoResize: true,
              hardwareKeyboardOnly: true,
              simulateScroll: false,
              autofocus: widget.running,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「认证成功 · 正在自动重试 session/new」（画板 52）。
class AuthSucceededCard extends StatelessWidget {
  const AuthSucceededCard({super.key});

  @override
  Widget build(BuildContext context) => TranscriptCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
          child: Row(
            children: <Widget>[
              AcpIcon(AcpIcons.checkCircle, color: t.Semantic.success),
              const SizedBox(width: t.Spacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('认证成功', style: t.TextStyles.body.copyWith(color: t.Neutral.strong, height: t.LineHeights.control)),
                    Text('正在自动重试 session/new，完成后回到刚才的新会话。', style: t.TextStyles.secondary),
                  ],
                ),
              ),
              const SizedBox(width: t.Spacing.s8),
              const Spinner(),
            ],
          ),
        ),
      );
}

/// 失败态（画板 52）：斜杠圆 + 「认证失败」 + 错误块；右侧 重试 / 换一种方式。
class AuthFailedCard extends StatelessWidget {
  const AuthFailedCard({super.key, required this.error, this.onRetry, this.onChangeMethod});

  final String error;
  final VoidCallback? onRetry;
  final VoidCallback? onChangeMethod;

  @override
  Widget build(BuildContext context) => TranscriptCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s12, vertical: t.Spacing.s8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AcpIcon(AcpIcons.slashCircle, color: t.Semantic.error),
              const SizedBox(width: t.Spacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text('认证失败', style: t.TextStyles.body.copyWith(color: t.Neutral.strong, height: t.LineHeights.control)),
                    const SizedBox(height: t.Spacing.s4),
                    MonoBlock(text: error, background: t.Semantic.errorSoft, style: CardText.codeError),
                  ],
                ),
              ),
              const SizedBox(width: t.Spacing.s8),
              // 两个按钮同宽（画板 52 右侧一列）：IntrinsicWidth 给 Row 里的 Column 一个有限宽，stretch 才有意义。
              IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    AcpButton(label: '重试', kind: ButtonKind.primary, onTap: onRetry),
                    const SizedBox(height: t.Spacing.s4),
                    AcpButton(label: '换一种方式', onTap: onChangeMethod),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

/// 无会话阶段的 URL elicitation（画板 52 / 28 的 requestScope 变体）：头行 + 说明 + Open in browser。
/// 打开过之后按画板 28 的口径显示 Waiting for completion… / Completed。
class RequestScopeElicitationCard extends StatelessWidget {
  const RequestScopeElicitationCard(this.entry, {super.key, this.agentName, this.onOpen, this.onCancel});

  final ElicitationEntry entry;
  final String? agentName;
  final VoidCallback? onOpen;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final who = agentName ?? e.agentId ?? 'agent';
    final completed = e.status == PendingStatus.completed;
    final cancelled = e.status == PendingStatus.cancelled || e.status == PendingStatus.withdrawn;
    final opened = e.opened && !completed && !cancelled;
    final message = e.wire.message ?? '认证阶段的 elicitation 可能在任何会话之外到达，落在本页而不是转录里。';
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: AcpIcon(AcpIcons.info, color: t.Accent.base),
            title: 'Sign in requested by $who',
            titleStyle: CardText.cardTitle,
            trailing: <Widget>[
              Text(
                completed
                    ? 'Completed'
                    : cancelled
                        ? 'Cancelled'
                        : 'requestScope · 无 sessionId',
                style: t.TextStyles.monoMeta.copyWith(color: completed ? t.Semantic.success : null),
              ),
            ],
          ),
          CardBody(
            padding: const EdgeInsets.all(t.Spacing.s12),
            children: <Widget>[
              Text(message, style: t.TextStyles.secondary.copyWith(height: t.LineHeights.body)),
              if (e.wire.url != null) MonoBlock(text: e.wire.url, style: CardText.subtitle, softWrap: false),
              Row(
                children: <Widget>[
                  AcpButton(label: 'Open in browser', kind: ButtonKind.primary, icon: AcpIcons.externalLink, enabled: !completed && !cancelled, onTap: onOpen),
                  const SizedBox(width: t.Spacing.s8),
                  if (completed)
                    Text('已收到 elicitation/complete', style: t.TextStyles.body.copyWith(color: t.Semantic.success))
                  else if (opened) ...<Widget>[
                    const Spinner(),
                    const SizedBox(width: t.Spacing.s4),
                    Text('Waiting for completion...', style: CardText.secondary),
                    const SizedBox(width: t.Spacing.s8),
                    AcpButton(label: 'Cancel', onTap: onCancel),
                  ],
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
