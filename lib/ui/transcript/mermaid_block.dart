// 画板 15 · Mermaid 图：卡片头（mermaid 标签 + 图形 / 源码切换）；图形态用 mermaid_flutter + mermaid_core（纯 Dart，
// 主题 16 色全部从 tokens 灌，节点只用中性色阶的两级表面）；解析失败经 errorBuilder 回落源码态；源码态是等宽块。

import 'package:flutter/widgets.dart';
import 'package:mermaid_core/mermaid_core.dart' as core;
import 'package:mermaid_flutter/mermaid_flutter.dart' as mf;

import '../../theme/tokens.dart' as t;
import 'card_chrome.dart';
import 'code_block.dart';

core.Color _c(Color color) => core.Color(color.toARGB32());

/// 画板 15 注：节点只用中性色阶的两级表面，不引入配色。字体只能给一个家族名（无 fallback），CJK 靠平台回退。
///
/// getter 而非顶层 `final`：顶层 final 只求值一次，会把 [t.Fonts.sans] 冻在首次访问那一刻，
/// 换字体之后图里的文字不跟着变（理由同 [CardText]）。
core.MermaidTheme get mermaidTokenTheme => core.MermaidTheme(
  background: _c(t.Surface.canvas),
  primaryColor: _c(t.Neutral.surface),
  primaryTextColor: _c(t.Neutral.strong),
  primaryBorderColor: _c(t.Borders.base),
  secondaryColor: _c(t.Neutral.panel),
  lineColor: _c(t.Neutral.muted),
  arrowheadColor: _c(t.Neutral.muted),
  textColor: _c(t.Neutral.text),
  nodeBorder: _c(t.Borders.base),
  mainBkg: _c(t.Neutral.surface),
  clusterBkg: _c(t.Neutral.panel),
  clusterBorder: _c(t.Borders.subtle),
  titleColor: _c(t.Neutral.strong),
  edgeLabelBackground: _c(t.Surface.canvas),
  fontFamily: t.Fonts.sans,
  fontSize: t.TextStyles.body.fontSize!,
);

enum MermaidView { diagram, source }

class MermaidBlock extends StatefulWidget {
  const MermaidBlock({super.key, required this.source, this.initialView = MermaidView.diagram, this.fontFamily});

  final String source;
  final MermaidView initialView;

  /// 测试环境不做平台字体回退时可指定含 CJK 的家族（gallery 用），真机留 null 用 tokens 的 Geist。
  final String? fontFamily;

  @override
  State<MermaidBlock> createState() => _MermaidBlockState();
}

class _MermaidBlockState extends State<MermaidBlock> {
  late MermaidView _view = widget.initialView;

  core.MermaidTheme get _theme => widget.fontFamily == null ? mermaidTokenTheme : mermaidTokenTheme.copyWith(fontFamily: widget.fontFamily);

  @override
  Widget build(BuildContext context) {
    return TranscriptCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            height: t.Controls.standard,
            padding: t.Controls.padStandard,
            decoration: BoxDecoration(
              color: t.Neutral.panel,
              border: Border(bottom: BorderSide(color: t.Borders.subtle, width: t.Borders.width)),
            ),
            child: Row(
              children: <Widget>[
                Text('mermaid', style: t.TextStyles.monoMeta),
                const Spacer(),
                _Segmented(
                  value: _view,
                  onChanged: (v) => setState(() => _view = v),
                ),
              ],
            ),
          ),
          if (_view == MermaidView.diagram)
            Padding(
              padding: const EdgeInsets.all(t.Spacing.s16),
              child: Align(
                alignment: Alignment.topCenter,
                child: mf.MermaidDiagram(
                  source: widget.source,
                  theme: _theme,
                  errorBuilder: (context, error) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text('无法渲染，显示源码：$error', style: t.TextStyles.secondary.copyWith(color: t.Semantic.error)),
                      const SizedBox(height: t.Spacing.s8),
                      MonoBlock(span: highlightCode(widget.source, null)),
                    ],
                  ),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.all(t.Spacing.s12),
              child: Text.rich(highlightCode(widget.source, null), softWrap: false),
            ),
        ],
      ),
    );
  }
}

/// 图形 / 源码 两段切换：surface 底、radius 4；选中段 popover 底 + accent 文字。
class _Segmented extends StatelessWidget {
  const _Segmented({required this.value, required this.onChanged});

  final MermaidView value;
  final ValueChanged<MermaidView> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: t.Controls.compact,
      decoration: BoxDecoration(color: t.Neutral.surface, borderRadius: t.Radii.control),
      padding: const EdgeInsets.all(t.Borders.width),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _seg('图形', MermaidView.diagram),
          _seg('源码', MermaidView.source),
        ],
      ),
    );
  }

  Widget _seg(String label, MermaidView v) {
    final selected = value == v;
    return GestureDetector(
      onTap: () => onChanged(v),
      child: Container(
        padding: t.Controls.padCompact,
        decoration: BoxDecoration(color: selected ? t.Surface.popover : null, borderRadius: t.Radii.chip),
        alignment: Alignment.center,
        child: Text(label, style: CardText.secondary.copyWith(color: selected ? t.Accent.text : t.Neutral.muted)),
      ),
    );
  }
}
