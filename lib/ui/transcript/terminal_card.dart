// 画板 22 / 23 · 嵌入式终端控制台卡：tool_call.content[] 的 { type: "terminal", terminalId } + 本地输出流。
// 展开 = 命令块 + xterm 渲染的输出（ANSI 三色按语义色映射：黄 → warning、绿 → success、青 → info/accent）+
// Exit Code · terminalId · released 元信息行；折叠 = 头行 + Exit Code；进行中 = spinner + 红色停止方块（→ terminal/kill，R4 接）。
// 终端被嵌进工具卡后即使 release 也继续显示输出（缓冲跟卡走，TerminalBuffer）。本轮只喂固定字节流，PTY 在 R4。

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart' as xt;

import '../../projection/entries.dart';
import '../../projection/tool_calls.dart';
import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'icons.dart';
import 'tool_call_card.dart';

/// xterm 主题：全部取 tokens；ANSI 红 / 绿 / 黄 / 青按语义色映射，不引入表外色相。
const xt.TerminalTheme terminalTokenTheme = xt.TerminalTheme(
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
  cyan: t.Semantic.info,
  brightBlack: t.Neutral.muted,
  brightRed: t.Semantic.error,
  brightGreen: t.Semantic.success,
  brightYellow: t.Semantic.warning,
  brightBlue: t.Accent.base,
  brightMagenta: t.Accent.active,
  brightCyan: t.Semantic.info,
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
        decoration: const BoxDecoration(color: t.Semantic.error, borderRadius: t.Radii.chip),
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
  late final xt.Terminal _terminal = xt.Terminal(maxLines: _maxLines);
  int _written = 0;

  /// 回滚行数上限（几何，不是样式）。
  static const int _maxLines = 2000;

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
    if (mounted) setState(() {});
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
            leading: const AcpIcon(AcpIcons.terminal, color: t.Neutral.muted),
            title: e.title,
            subtitle: _expanded ? toolSubtitle(e, cwd: widget.cwd) : command,
            trailing: <Widget>[
              if (!_expanded && exitLabel.isNotEmpty) Text(exitLabel, style: t.TextStyles.monoMeta),
              if (running) ...<Widget>[const Spinner(), StopSquareButton(onTap: widget.onKill)] else ToolStatusIcon(e.displayStatus),
              Chevron(expanded: _expanded),
            ],
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded)
            CardBody(
              children: <Widget>[
                MonoBlock(text: command),
                Container(
                  decoration: const BoxDecoration(color: t.Neutral.panel, borderRadius: t.Radii.control),
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
