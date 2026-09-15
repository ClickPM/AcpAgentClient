// 壳的共用小件（画板 01–04 / 40 / 41 / 42 / 80 共用；ROUNDS § 2 的文件表之外新增，任务卡已记）：
// agent 标记方块、悬浮包装、文本输入、相对时间文案。样式只取 tokens（CLAUDE.md 规则 3）。

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart' as t;
import '../transcript/icons.dart';

/// agent 标记方块（画板 01–04 的会话项 / 线程头、41 的 agent 列表）：16 见方的框 + 6 见方的菱形。
/// 没有 agent 时（画板 01 状态 2 的 `No Agent`）是虚线空框。设计稿注明这是单色占位，各 agent 自己的 logo 由 R5 registry 带来。
class AgentMark extends StatelessWidget {
  const AgentMark({super.key, this.active = false, this.empty = false});

  /// 当前会话 / 当前 agent：菱形取 accent。
  final bool active;

  /// 虚线空框（无 agent）。
  final bool empty;

  @override
  Widget build(BuildContext context) {
    if (empty) {
      return const SizedBox(
        width: t.IconSizes.base,
        height: t.IconSizes.base,
        child: CustomPaint(painter: _DashedBoxPainter()),
      );
    }
    return Container(
      width: t.IconSizes.base,
      height: t.IconSizes.base,
      decoration: BoxDecoration(
        border: Border.all(color: t.Neutral.placeholder, width: t.Borders.width),
        borderRadius: t.Radii.chip,
      ),
      alignment: Alignment.center,
      child: Transform.rotate(
        angle: _quarterTurn,
        child: Container(
          width: t.Geometry.agentMarkDot,
          height: t.Geometry.agentMarkDot,
          color: active ? t.Accent.base : t.Neutral.placeholder,
        ),
      ),
    );
  }

  /// 45°（画板的 `transform:rotate(45deg)`）。
  static const double _quarterTurn = 0.7853981633974483;
}

/// 虚线方框（画板 01 状态 2 的 `No Agent` 与空态图标）。
class _DashedBoxPainter extends CustomPainter {
  const _DashedBoxPainter({this.radius = t.Radii.r3});

  final Radius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = t.Neutral.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = t.Borders.width;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(t.Borders.width / 2, t.Borders.width / 2, size.width - t.Borders.width, size.height - t.Borders.width),
      radius,
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + _dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d = end + _gap;
      }
    }
  }

  /// 虚线的线段与间隙（CSS `border:1px dashed` 的观感）。
  static const double _dash = t.Spacing.s4 - t.Borders.width;
  static const double _gap = t.Spacing.s4 / 2;

  @override
  bool shouldRepaint(_DashedBoxPainter old) => old.radius != radius;
}

/// 虚线圆角框（画板 01 状态 2 的 32 见方空态图标）。
class DashedBox extends StatelessWidget {
  const DashedBox({super.key, required this.size, required this.child});

  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: const _DashedBoxPainter(radius: t.Radii.r6),
          child: Center(child: child),
        ),
      );
}

/// 悬浮态包装：把 hover 交给 builder（画板 04 的会话项悬浮、顶栏项目名 / 分支名悬浮）。
class Hoverable extends StatefulWidget {
  const Hoverable({super.key, required this.builder, this.onTap, this.cursor = SystemMouseCursors.click, this.forceHover = false});

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onTap;
  final MouseCursor cursor;

  /// gallery 里强制成悬浮态（画板 04 要出悬浮样张）。
  final bool forceHover;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _hover || widget.forceHover);
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: widget.onTap == null ? child : GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: child),
    );
  }
}

/// 单行 / 多行文本输入（`EditableText`，不引 Material）：输入框正文、侧栏搜索、行内重命名、分支名、方法名过滤。
/// 中文 IME 的组合窗由 `EditableText` 自己处理（R0 记录的实测项）。
class AcpTextField extends StatelessWidget {
  const AcpTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.style,
    this.placeholder,
    this.placeholderStyle,
    this.maxLines = 1,
    this.minLines,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final TextStyle style;
  final String? placeholder;
  final TextStyle? placeholderStyle;
  final int? maxLines;
  final int? minLines;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final field = EditableText(
      controller: controller,
      focusNode: focusNode,
      style: style,
      cursorColor: t.Accent.base,
      backgroundCursorColor: t.Neutral.border,
      selectionColor: t.Accent.soft,
      maxLines: maxLines,
      minLines: minLines,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    );
    final hint = placeholder;
    if (hint == null || hint.isEmpty) return field;
    return Stack(
      children: <Widget>[
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) => value.text.isEmpty
              ? Text(hint, style: placeholderStyle ?? style.copyWith(color: t.Neutral.placeholder), maxLines: maxLines, overflow: TextOverflow.ellipsis)
              : const SizedBox.shrink(),
        ),
        field,
      ],
    );
  }
}

/// 「15 分钟前」「3 天前」：会话项的时间戳是客户端本地态（协议只给 `SessionInfo.updatedAt`，画板 04 注）。
String relativeTime(DateTime at, {required DateTime now}) {
  final d = now.difference(at);
  if (d.inSeconds < 60) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  return '${d.inDays} 天前';
}

/// 侧栏底部导航的四个入口（画板 01 / 04），同时是右栏的四个标签（画板 03）。
enum ShellTab {
  settings('设置', '设置', AcpIcons.settings),
  files('文件', '文件浏览器', AcpIcons.folder),
  agents('Agents', 'Agents', AcpIcons.layers),
  terminal('终端', '终端', AcpIcons.terminal);

  const ShellTab(this.label, this.panelTitle, this.icon);

  /// 侧栏底部导航上的文案（画板 01 / 04）。
  final String label;

  /// 右栏标签条上的文案（画板 03）。
  final String panelTitle;
  final String icon;
}
