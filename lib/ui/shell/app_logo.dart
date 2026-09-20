// 应用标记（画板 01–04 侧栏顶部）。R3 起那里画的是占位方框 ☒（icons.dart 的 appMark，本轮已删），
// 所有者 2026-09-17 定稿了正式 logo，这里换成正式标记：字母 A 的横杠是三节点链路 = ACP 把多个 agent 串起来。
//
// 几何与 design/brand/app-icon.svg 同一份（256 视口），差别只在这里不画底板、viewBox 收到标记外框。
// 底板版是 windows/runner/resources/app_icon.ico 的来源，改几何要两边一起改。
// 配色不写字面量（规则 3）：从 tokens 的 Color 取值拼进 SVG 文档。

import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../theme/tokens.dart' as t;

/// 侧栏顶部的应用标记。双色，尺寸只用 tokens 的 [t.IconSizes]。
///
/// **构造函数不是 `const`**（也别改回去）：[document] 把当前主题的颜色烘进了 SVG 文本，而常量 widget
/// 会被规范化成同一个实例——父级换主题重建时 `Element.updateChild` 见到 `identical(old, new)` 就直接
/// 复用旧 element、不再 build，标记于是冻在首次构建那一套颜色上（深色下是黑底黑标）。
class AppLogo extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables  见上：const 化会让它在换主题时被跳过重建。
  AppLogo({super.key, this.size = t.IconSizes.base});

  final double size;

  /// SVG 里的 `#RRGGBB`。
  static String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

  /// 无底板的标记，viewBox 收到 A 与链路的外框（底板版见 design/brand/app-icon.svg）。
  static String document() =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="38 36 180 180">'
      '<defs><clipPath id="band">'
      '<rect x="0" y="0" width="256" height="135"/><rect x="0" y="163" width="256" height="93"/>'
      '</clipPath></defs>'
      '<path d="M69 190 L128 61 L187 190" clip-path="url(#band)" fill="none" stroke="${_hex(t.Neutral.strong)}" '
      'stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>'
      '<path d="M53 149 H203" fill="none" stroke="${_hex(t.Accent.base)}" stroke-width="9" stroke-linecap="round"/>'
      '<circle cx="53" cy="149" r="13" fill="${_hex(t.Accent.base)}"/>'
      '<circle cx="128" cy="149" r="13" fill="${_hex(t.Accent.base)}"/>'
      '<circle cx="203" cy="149" r="13" fill="${_hex(t.Accent.base)}"/>'
      '</svg>';

  @override
  Widget build(BuildContext context) => SvgPicture.string(document(), width: size, height: size);
}
