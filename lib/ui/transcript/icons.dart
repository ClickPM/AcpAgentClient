// 画板 10–34 的内联单线图标（flutter_svg，所有者裁定 2026-09-15）。路径逐个取自 design/round-design/NN-*.dc.html 的
// <svg> 内容（24 单位视口、无填充、圆头圆角），颜色由调用方给（colorFilter），尺寸只用 tokens 的 IconSizes。
// 不用 Icons.*（flutter_tester 不装 Material 图标字体，规则 1 也不引图标库）。

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../theme/tokens.dart' as t;

/// 图标路径体（`<svg>` 标签内部）。命名按语义，注释标出处画板。
abstract final class AcpIcons {
  /// 10 / 11：Restore（逆时针箭头）。
  static const String rotateCcw = '<polyline points="1 4 1 10 7 10"/><path d="M3.51 15a9 9 0 1 0 2.13-9.36L1 10"/>';

  /// 11：Edit（铅笔）。
  static const String pencil = '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>';

  /// 11 / 13 / 24：Copy。
  static const String copy = '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>';

  /// 12 / 13 / 25 / 27 / 28：对勾。
  static const String check = '<polyline points="20 6 9 17 4 12"/>';

  /// 15：向下箭头（Mermaid 边）。
  static const String arrowDown = '<line x1="12" y1="4" x2="12" y2="18"/><polyline points="7 14 12 19 17 14"/>';

  /// 17 / 18 / 23 / 24 / 26 / 28 / 29 / 31 / 33：spinner 弧（accent，stroke 2）。
  static const String spinnerArc = '<path d="M21 12a9 9 0 1 1-6.2-8.55"/>';

  /// 折叠 / 展开。
  static const String chevronDown = '<polyline points="6 9 12 15 18 9"/>';
  static const String chevronUp = '<polyline points="18 15 12 9 6 15"/>';

  /// 17：思考（灯泡）。
  static const String lightbulb = '<path d="M9 18h6"/><path d="M10 22h4"/><path d="M12 2a6 6 0 0 0-3.5 10.9c.6.5.9 1.2.9 2h5.2c0-.8.3-1.5.9-2A6 6 0 0 0 12 2z"/>';

  /// 18 / 19 / 24 / 29 / 32：文件（kind read）。
  static const String file = '<path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><polyline points="13 2 13 9 20 9"/>';

  /// 18 / 21 / 22 / 24 / 29 / 33 / 34：完成（圆 + 对勾）。
  static const String checkCircle = '<circle cx="12" cy="12" r="9"/><polyline points="8.4 12.2 11 14.8 15.8 9.6"/>';

  /// 18：搜索（kind search）。
  static const String search = '<circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.2" y2="16.2"/>';

  /// 18 / 29：pending（虚线圆）。
  static const String dashedCircle = '<circle cx="12" cy="12" r="8" stroke-dasharray="3.2 3"/>';

  /// 18 / 20 / 22 / 23：终端（kind execute）。
  static const String terminal = '<polyline points="4 17 10 11 4 5"/><line x1="12" y1="19" x2="20" y2="19"/>';

  /// 18：地球（kind fetch）。
  static const String globe = '<circle cx="12" cy="12" r="9"/><line x1="3" y1="12" x2="21" y2="12"/><path d="M12 3a14 14 0 0 1 0 18 14 14 0 0 1 0-18z"/>';

  /// 18：层叠（kind other）。
  static const String layers = '<polygon points="12 2 2 7 12 12 22 7 12 2"/><polyline points="2 17 12 22 22 17"/>';

  /// 19 / 25 / 27 / 29 / 33：✕。
  static const String x = '<line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/>';

  /// 21：diff（两栏）。
  static const String columns = '<path d="M2 5a2 2 0 0 1 2-2h6v18H4a2 2 0 0 1-2-2z"/><path d="M22 5a2 2 0 0 0-2-2h-6v18h6a2 2 0 0 0 2-2z"/>';

  /// 24：↳ Subagent Output。
  static const String cornerDownRight = '<polyline points="15 10 20 15 15 20"/><path d="M4 4v7a4 4 0 0 0 4 4h12"/>';

  /// 24：反馈。
  static const String thumbsUp = '<path d="M14 9V5a3 3 0 0 0-3-3l-4 9v11h11.3a2 2 0 0 0 2-1.7l1.4-9A2 2 0 0 0 19.7 9z"/><line x1="7" y1="22" x2="4" y2="22"/>';
  static const String thumbsDown = '<path d="M10 15v4a3 3 0 0 0 3 3l4-9V2H5.7a2 2 0 0 0-2 1.7l-1.4 9A2 2 0 0 0 4.3 15z"/><line x1="17" y1="2" x2="20" y2="2"/>';

  /// 24 / 28：外链。
  static const String externalLink = '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/><polyline points="15 3 21 3 21 9"/><line x1="10" y1="14" x2="21" y2="3"/>';

  /// 25 / 26：垃圾桶（kind delete）。
  static const String trash = '<polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>';

  /// 26 / 34：警告三角。
  static const String alertTriangle = '<path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/>';

  /// 26 / 27 / 28：信息圆。
  static const String info = '<circle cx="12" cy="12" r="9"/><line x1="12" y1="11" x2="12" y2="16"/><line x1="12" y1="8" x2="12.01" y2="8"/>';

  /// 30 / 31：加号。
  static const String plus = '<line x1="12" y1="5" x2="12" y2="19"/><line x1="5" y1="12" x2="19" y2="12"/>';

  /// 30：斜向外链（Rules）。
  static const String arrowUpRight = '<line x1="7" y1="17" x2="17" y2="7"/><polyline points="7 7 17 7 17 17"/>';

  /// 32：播放。
  static const String play = '<polygon points="6 4 20 12 6 20 6 4"/>';

  /// 32：链接。
  static const String link = '<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.8 1.8"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.8-1.8"/>';

  /// 34：spawned（小圆点）。
  static const String dot = '<circle cx="12" cy="12" r="5"/>';

  /// 34：锁（auth_required）。
  static const String lock = '<rect x="4" y="11" width="16" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>';

  /// 34：禁止（exited）。
  static const String slashCircle = '<circle cx="12" cy="12" r="9"/><line x1="18" y1="6" x2="6" y2="18"/>';

  /// 31：线程头菱形（画板 31 线程标题前的图标，原稿是填充菱形）。
  static const String diamond = '<path d="M12 3l9 9-9 9-9-9z"/>';

  /// 全部图标（测试预热 svg 缓存用）。
  static const List<String> all = <String>[
    rotateCcw, pencil, copy, check, arrowDown, spinnerArc, chevronDown, chevronUp, lightbulb, file, checkCircle, search,
    dashedCircle, terminal, globe, layers, x, columns, cornerDownRight, thumbsUp, thumbsDown, externalLink, trash,
    alertTriangle, info, plus, arrowUpRight, play, link, dot, lock, slashCircle, diamond,
  ];

  /// 完整 SVG 文档：stroke 固定为黑，真实颜色由 [AcpIcon] 的 colorFilter 给，这样同一图标只解析一次。
  static String document(String body, {double strokeWidth = t.IconSizes.stroke}) =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#000000" '
      'stroke-width="$strokeWidth" stroke-linecap="round" stroke-linejoin="round">$body</svg>';
}

/// 单色单线图标。`size` 只接受 tokens 的 IconSizes（16 / 14）。
class AcpIcon extends StatelessWidget {
  const AcpIcon(this.body, {super.key, required this.color, this.size = t.IconSizes.base, this.strokeWidth = t.IconSizes.stroke});

  final String body;
  final Color color;
  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      AcpIcons.document(body, strokeWidth: strokeWidth),
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

/// spinner：accent · 1.5px 弧，持续旋转（tokens Spinner）。
class Spinner extends StatefulWidget {
  const Spinner({super.key, this.size = t.IconSizes.toolbar, this.color = t.Spinner.color});

  final double size;
  final Color color;

  @override
  State<Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<Spinner> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, duration: t.Geometry.spinnerPeriod)..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: AcpIcon(AcpIcons.spinnerArc, color: widget.color, size: widget.size, strokeWidth: t.Spinner.strokeWidth),
    );
  }
}
