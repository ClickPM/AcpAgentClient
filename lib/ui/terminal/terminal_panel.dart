// 画板 61 · 终端面板：状态行（运行中 = success 圆点 + cwd 常显；已退出 = error 圆点 + 「已退出 · exitCode N · signal none」）+
// 右侧停止方块（运行中才有）/ 清屏 / 重启；正文是 xterm 渲染的本地 shell（PTY 在 Rust 侧，输出经 acp/terminal_output 喂进来），
// 退出后正文末尾多一行「Exit Code N · 耗时」。标签本身在右栏标签条上（right_panel.dart 的 PanelTab.terminal）。
// 偏离：画板正文行高 1.7 不是 token，取 tokens 的正文行高 1.5（与画板 22 的终端卡同一份 CardText.code）。

import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart' as xt;

import '../../theme/tokens.dart' as t;
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import '../transcript/terminal_card.dart';
import 'local_terminal.dart';

class TerminalPanel extends StatelessWidget {
  const TerminalPanel({
    super.key,
    required this.terminal,
    this.onStop,
    this.onClear,
    this.onRestart,
    this.focusNode,
    this.autofocus = false,
  });

  final LocalTerminal terminal;
  final VoidCallback? onStop;
  final VoidCallback? onClear;
  final VoidCallback? onRestart;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: terminal,
      builder: (context, _) => Container(
        color: t.Surface.canvas,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _statusRow(),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _statusRow() {
    final running = terminal.running;
    final label = running
        ? terminal.cwd
        : '已退出 · exitCode ${terminal.exitCode ?? 'none'} · signal ${terminal.signal ?? 'none'}';
    return Container(
      height: t.Geometry.panelHeaderHeight,
      padding: const EdgeInsets.only(left: t.Spacing.s12, right: t.Spacing.s4),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width))),
      child: Row(
        children: <Widget>[
          Container(
            width: t.Geometry.terminalDot,
            height: t.Geometry.terminalDot,
            decoration: BoxDecoration(shape: BoxShape.circle, color: running ? t.Semantic.success : t.Semantic.error),
          ),
          const SizedBox(width: t.Spacing.s8),
          Expanded(child: Text(label, style: CardText.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (running) StopSquareButton(onTap: onStop),
          IconButtonGhost(icon: AcpIcons.clearScreen, size: t.Controls.compact, onTap: onClear),
          IconButtonGhost(icon: AcpIcons.rotateCw, size: t.Controls.compact, onTap: onRestart),
        ],
      ),
    );
  }

  Widget _body() {
    final running = terminal.running;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: t.Spacing.s16, vertical: t.Spacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            child: xt.TerminalView(
              terminal.terminal,
              theme: terminalTokenTheme,
              textStyle: xt.TerminalStyle.fromTextStyle(CardText.code),
              // 底色由外层 canvas 给（主题里的 panel 底是终端卡的）。
              backgroundOpacity: 0,
              focusNode: focusNode,
              autofocus: autofocus && running,
              readOnly: !running,
              alwaysShowCursor: running,
              autoResize: true,
              // 键盘输入只认硬件按键事件（与终端卡、terminal auth 的两处 TerminalView 一致）：xterm 默认那条
              // 「平台文本输入」通道在 Windows 上建不起来——它 attach 时不带 viewId，而 Windows 引擎的
              // TextInputPlugin 对 setClient 要求 viewId 是整数，缺了就直接报错返回、连 active_model 都不建，
              // 于是打进去的字符被静默丢掉（keytab 认的回车 / 方向键照旧，所以表现是「只有字打不进去」）。
              // 走 CustomKeyboardListener 这条：keytab 不认的按键取 KeyEvent.character 交给终端。
              // 代价是终端里没有 IME 组字（中文输入法），见 rounds/BACKLOG.md。
              hardwareKeyboardOnly: true,
              simulateScroll: false,
            ),
          ),
          if (!running) ...<Widget>[
            const SizedBox(height: t.Spacing.s4),
            TerminalExitLine(exitCode: terminal.exitCode, signal: terminal.signal, elapsed: terminal.elapsed),
          ],
        ],
      ),
    );
  }
}

/// 「Exit Code 1 · 0.9s」：退出码非零走 error 色，零走 success。
class TerminalExitLine extends StatelessWidget {
  const TerminalExitLine({super.key, this.exitCode, this.signal, this.elapsed});

  final int? exitCode;
  final String? signal;
  final Duration? elapsed;

  /// 画板 61 的「0.9s」：一分钟内一位小数的秒，超过一分钟「1m 15s」。
  static String formatElapsed(Duration d) {
    if (d.inSeconds < 60) return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  @override
  Widget build(BuildContext context) {
    final code = exitCode;
    final ok = code == 0;
    return Text.rich(
      TextSpan(
        style: CardText.code,
        children: <InlineSpan>[
          if (code != null) ...<InlineSpan>[
            const TextSpan(text: 'Exit Code '),
            TextSpan(text: '$code', style: TextStyle(color: ok ? t.Semantic.success : t.Semantic.error)),
          ] else
            TextSpan(text: 'Signal ${signal ?? 'none'}', style: const TextStyle(color: t.Semantic.error)),
          if (elapsed != null) TextSpan(text: ' · ${formatElapsed(elapsed!)}', style: const TextStyle(color: t.Neutral.muted)),
        ],
      ),
    );
  }
}
