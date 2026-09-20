// 画板 22 / 23 · 嵌入式终端控制台卡：tool_call.content[] 的 { type: "terminal", terminalId } + 本地输出流。
// 展开 = 命令块 + xterm 渲染的输出（ANSI 三色按语义色映射：黄 → warning、绿 → success、青 → accent.text）+
// Exit Code · terminalId · released 元信息行；折叠 = 头行 + Exit Code；进行中 = spinner + 红色停止方块（→ terminal/kill，R4 接）。
// 终端被嵌进工具卡后即使 release 也继续显示输出（缓冲跟卡走，TerminalBuffer）。本轮只喂固定字节流，PTY 在 R4。
// 跑完自动收起（所有者裁定 2026-09-18）：status 转 completed / failed（或终端自己 exit）的那一下，用户没手动点过头行就折叠。
// 协议里没有「折叠」这回事（ToolCall 只给 status），这是客户端自定的呈现规则，与 acp-projection.md § 7 第 6 条同类；
// 只认「转换」的那一下，生来就结束的卡由 initiallyExpanded 定（画板 22 的展开态、转录列表的历史卡各按各的）。

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart' as xt;

import '../../projection/entries.dart';
import '../../projection/tool_calls.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';
import 'tool_call_card.dart';

/// xterm 主题：全部取 tokens；ANSI 红 / 绿 / 黄 / 青按语义色映射，不引入表外色相。
/// 黑 / 白两位是「反差最大的墨 / 等于背景」的语义（浅色 n.strong / n.canvas，深色 d.strong / d.canvas），
/// 不是把浅色值照搬（画板 07 § 2.9）。
///
/// getter 而不是常量：整张表把颜色烘在里面，换主题要整张重算（理由同 [CardText]）。
xt.TerminalTheme get terminalTokenTheme => xt.TerminalTheme(
  cursor: t.Accent.base,
  selection: t.Accent.soft,
  foreground: t.Neutral.text,
  background: t.Neutral.panel,
  black: t.Neutral.strong,
  white: t.Neutral.canvas,
  red: t.Semantic.error,
  green: t.Semantic.success,
  yellow: t.Semantic.warning,
  blue: t.Accent.base,
  magenta: t.Accent.active,
  cyan: t.Accent.text,
  brightBlack: t.Neutral.muted,
  brightRed: t.Semantic.error,
  brightGreen: t.Semantic.success,
  brightYellow: t.Semantic.warning,
  brightBlue: t.Accent.base,
  brightMagenta: t.Accent.active,
  brightCyan: t.Accent.text,
  brightWhite: t.Neutral.canvas,
  searchHitBackground: t.Semantic.warningSoft,
  searchHitBackgroundCurrent: t.Semantic.warning,
  searchHitForeground: t.Neutral.strong,
);

/// 停止方块：ghost 容器里的 error 色小方块（不是红色填充按钮）。
class StopSquareButton extends StatelessWidget {
  const StopSquareButton({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButtonGhost(
      icon: AcpIcons.x,
      size: t.Controls.compact,
      onTap: onTap,
      child: Container(
        width: t.Spacing.s12,
        height: t.Spacing.s12,
        decoration: BoxDecoration(color: t.Semantic.error, borderRadius: t.Radii.chip),
      ),
    );
  }
}

class TerminalCard extends StatefulWidget {
  const TerminalCard(this.entry, {super.key, required this.buffer, this.cwd, this.initiallyExpanded = true, this.onKill});

  final ToolCallEntry entry;
  final TerminalBuffer buffer;
  final String? cwd;
  final bool initiallyExpanded;
  final VoidCallback? onKill;

  @override
  State<TerminalCard> createState() => _TerminalCardState();
}

class _TerminalCardState extends State<TerminalCard> {
  late bool _expanded = widget.initiallyExpanded;
  late final xt.Terminal _terminal = xt.Terminal(maxLines: t.Geometry.terminalScrollbackLines);
  int _written = 0;

  /// 用户点过头行之后就不再替他做主：手动展开的卡跑完不收，手动收起的也不会被重新打开。
  bool _userToggled = false;

  /// 上一次看到的「已结束」，用来只在转换的那一下收起。
  late bool _wasFinished = _isFinished;

  /// 回滚行数上限（几何，不是样式）。

  /// 只读展示不显示光标（DECTCEM 关）。
  static const String _hideCursor = '[?25l';

  @override
  void initState() {
    super.initState();
    _terminal.write(_hideCursor);
    _sync();
    widget.buffer.addListener(_sync);
  }

  @override
  void didUpdateWidget(TerminalCard old) {
    super.didUpdateWidget(old);
    if (old.buffer != widget.buffer) {
      old.buffer.removeListener(_sync);
      _written = 0;
      widget.buffer.addListener(_sync);
      _sync();
    }
    // 工具调用的 status 是就地改在同一个 ToolCallEntry 上的，只有转录列表重建时才看得到：收尾就在这里收。
    _autoCollapseOnFinish();
  }

  @override
  void dispose() {
    widget.buffer.removeListener(_sync);
    super.dispose();
  }

  /// 只把新增的字节写进终端；缓冲被截断（内容变短）时整体重写。
  void _sync() {
    final out = widget.buffer.output;
    if (out.length < _written) {
      _terminal.buffer.clear();
      _terminal.buffer.setCursor(0, 0);
      _terminal.write(_hideCursor);
      _written = 0;
    }
    if (out.length > _written) {
      _terminal.write(out.substring(_written).replaceAll('\n', '\r\n'));
      _written = out.length;
    }
    _autoCollapseOnFinish();
    if (mounted) setState(() {});
  }

  /// 工具调用收尾（completed / failed / 本地取消）或终端自己退出，都算跑完。
  bool get _isFinished => widget.entry.isFinished || widget.buffer.exited;

  /// 跑完自动收起：只在跑完的那一下、且用户没手动点过头行时收，把版面让给后面的输出。
  void _autoCollapseOnFinish() {
    final finished = _isFinished;
    if (finished && !_wasFinished && !_userToggled) _expanded = false;
    _wasFinished = finished;
  }

  int get _rows {
    final n = widget.buffer.output.split('\n').length;
    return n.clamp(1, 12);
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final b = widget.buffer;
    final running = !e.isFinished && !b.exited;
    final exit = b.exitCode;
    final exitLabel = exit != null ? 'Exit Code $exit' : (b.signal != null ? 'Signal ${b.signal}' : '');
    final command = toolCommand(e) ?? e.title;
    final lineHeight = CardText.code.fontSize! * CardText.code.height!;
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CardHeader(
            leading: AcpIcon(AcpIcons.terminal, color: t.Neutral.muted),
            title: e.title,
            subtitle: _expanded ? toolSubtitle(e, cwd: widget.cwd) : command,
            trailing: <Widget>[
              if (!_expanded && exitLabel.isNotEmpty) Text(exitLabel, style: t.TextStyles.monoMeta),
              if (running) ...<Widget>[const Spinner(), StopSquareButton(onTap: widget.onKill)] else ToolStatusIcon(e.displayStatus),
              Chevron(expanded: _expanded),
            ],
            onTap: () => setState(() {
              _userToggled = true;
              _expanded = !_expanded;
            }),
          ),
          if (_expanded)
            CardBody(
              children: <Widget>[
                MonoBlock(text: command),
                Container(
                  decoration: BoxDecoration(color: t.Neutral.panel, borderRadius: t.Radii.control),
                  padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s8, vertical: t.Spacing.s8),
                  height: _rows * lineHeight + t.Spacing.s16,
                  child: xt.TerminalView(
                    _terminal,
                    theme: terminalTokenTheme,
                    textStyle: xt.TerminalStyle.fromTextStyle(CardText.code),
                    readOnly: true,
                    autoResize: true,
                    hardwareKeyboardOnly: true,
                    simulateScroll: false,
                  ),
                ),
                if (!running)
                  Text.rich(
                    TextSpan(children: <InlineSpan>[
                      if (exitLabel.isNotEmpty) TextSpan(text: exitLabel),
                      if (exitLabel.isNotEmpty) const TextSpan(text: '  |  '),
                      TextSpan(text: 'terminalId ${b.terminalId}'),
                      if (b.released) const TextSpan(text: '  |  released（输出按规范继续留存）'),
                      if (b.killed) const TextSpan(text: '  |  killed'),
                      if (b.truncated) const TextSpan(text: '  |  truncated'),
                    ]),
                    style: t.TextStyles.monoMeta,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
