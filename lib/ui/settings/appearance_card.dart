// 画板 70「设置」·「外观」小节：四个字体轴各一个下拉。
//
// 四行分两组：界面（西文 / 中文）与代码（西文 / 中文）。两组候选严格互不重叠——西文轴上只放对 CJK
// 覆盖为 0 的纯拉丁字体，否则它会把中文也吃掉、中文轴就失效了（理由见 `lib/app/appearance_prefs.dart` 文件头）。
//
// 下拉沿用画板 41 / 42 的弹层三件套（[PopoverAnchor] + [MenuPopover] + [MenuTwoLineRow]），
// 与权限卡的范围下拉同一套做法；样式只取 tokens（规则 3）。

import 'package:flutter/widgets.dart';

import '../../app/appearance_prefs.dart';
import '../../theme/tokens.dart' as t;
import '../popovers/menu.dart';
import '../shell/popover_anchor.dart';
import '../transcript/card_chrome.dart';
import '../transcript/icons.dart';
import 'settings_page.dart';

class AppearanceCard extends StatefulWidget {
  const AppearanceCard({super.key, required this.appearance, this.onOpenUrl});

  final AppearanceController appearance;

  /// 「去下载」：把候选的官网在系统浏览器里打开。设置页经 `url_launcher` 传进来。
  final ValueChanged<String>? onOpenUrl;

  @override
  State<AppearanceCard> createState() => _AppearanceCardState();
}

class _AppearanceCardState extends State<AppearanceCard> {
  /// 四个轴各一个弹层句柄。
  final Map<FontAxis, PopoverHandle> _handles = <FontAxis, PopoverHandle>{
    for (final FontAxis a in FontAxis.values) a: PopoverHandle(),
  };
  FontAxis? _open;

  @override
  void dispose() {
    for (final PopoverHandle h in _handles.values) {
      h.dispose();
    }
    super.dispose();
  }

  void _toggle(FontAxis axis) {
    if (_open == axis) {
      _handles[axis]!.hide();
      setState(() => _open = null);
      return;
    }
    // 别的轴开着就先收掉，同一时刻只开一个。
    if (_open != null) _handles[_open]!.hide();
    _handles[axis]!.show(
      (_) => _menuFor(axis),
      targetAnchor: Alignment.bottomRight,
      followerAnchor: Alignment.topRight,
      onDismiss: () {
        if (mounted) setState(() => _open = null);
      },
    );
    setState(() => _open = axis);
  }

  void _pick(FontAxis axis, FontChoice choice) {
    _handles[axis]!.hide();
    setState(() => _open = null);
    widget.appearance.setAxis(axis, choice.family);
  }

  Widget _menuFor(FontAxis axis) {
    final List<FontChoice> choices = fontCatalog[axis] ?? const <FontChoice>[];
    final String current = widget.appearance.fonts.resolved(axis);
    return MenuPopover(
      children: <Widget>[
        for (final FontChoice c in choices)
          MenuTwoLineRow(
            title: c.label,
            meta: widget.appearance.registry.isAvailable(c) ? (c.note ?? '') : '本机未找到 · ${c.note ?? ''}',
            selected: c.family == current,
            showCheck: c.family == current,
            onTap: () => _pick(axis, c),
          ),
      ],
    );
  }

  /// 轴上当前选中的候选。手写进 `settings.json` 的字体名不在候选表里时回 null。
  FontChoice? _choiceOf(FontAxis axis) {
    final String current = widget.appearance.fonts.resolved(axis);
    for (final FontChoice c in fontCatalog[axis] ?? const <FontChoice>[]) {
      if (c.family == current) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final List<FontAxis> axes = FontAxis.values;
    // 自己监听而不是靠宿主：换字体时组合根那层的 [ListenableBuilder] 会重建整棵树，
    // 但这张卡还要显示「当前选中 / 本机有没有」这些只有控制器知道的状态，不该假定宿主一定在听。
    return ListenableBuilder(
      listenable: widget.appearance,
      builder: (BuildContext context, Widget? _) => TranscriptCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int i = 0; i < axes.length; i++) _row(axes[i], bottomBorder: i < axes.length - 1),
          ],
        ),
      ),
    );
  }

  Widget _row(FontAxis axis, {required bool bottomBorder}) {
    final String current = widget.appearance.fonts.resolved(axis);
    final FontChoice? choice = _choiceOf(axis);
    // 候选表里没有 = 用户手写进 settings.json 的名字，照样认，只是不知道它在不在本机。
    final bool available = choice == null || widget.appearance.registry.isAvailable(choice);
    final String fallback = defaultFamilyFor(axis);
    return SettingsRow(
      label: axis.label,
      value: current,
      muted: !available,
      note: available
          ? choice?.note
          : '本机未找到这款字体，当前实际渲染回退到 $fallback；把字体装进系统，或把字体文件放进数据目录的 fonts 子目录。',
      bottomBorder: bottomBorder,
      trailing: <Widget>[
        if (!available && choice.downloadUrl != null) ...<Widget>[
          AcpButton(
            label: '去下载',
            icon: AcpIcons.download,
            onTap: widget.onOpenUrl == null ? null : () => widget.onOpenUrl!(choice.downloadUrl!),
          ),
          const SizedBox(width: t.Spacing.s4),
        ],
        PopoverAnchor(
          handle: _handles[axis]!,
          child: AcpButton(
            label: choice?.label ?? current,
            trailing: Chevron(expanded: _open == axis),
            onTap: () => _toggle(axis),
          ),
        ),
      ],
    );
  }
}
