// 换主题之后界面只切一半（iteration-02 第 3 组）：两条独立现象、同一个根因——
// 「element 压根没重建」，于是 build 里现取颜色 token 的代码根本没被再执行一次。
//
// ① 叶子 widget 在调用点写成 `const`：常量实例被规范化成同一个对象，父级重建时
//    `Element.updateChild` 见到 `child.widget == newWidget` 直接复用旧 element、不再 build，
//    颜色冻在首次构建那一套上（0c95a84 的 `AppLogo` 是同一类）。
// ② `MarkdownBody` 把解析出的块 widget 实例缓存在 State，`didUpdateWidget` 只比
//    data / onLink / mermaidFontFamily / baseStyle——换主题这四个都没变，缓存原样返回。
//
// 用例一律从**真实调用点**渲染（`ToneChip(...)` 自己新建一个实例是测不出来的：新实例本来就会
// 重建，退回修复也不会红）。每条都验证过「退回修复即失败」。

import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/files/file_tree.dart';
import 'package:acp_agent_client/ui/files/files_panel.dart';
import 'package:acp_agent_client/ui/registry/registry_entry.dart';
import 'package:acp_agent_client/ui/transcript/awaiting_bar.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/code_block.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:acp_agent_client/ui/transcript/markdown_body.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// 组合根的装配（`lib/app/app.dart`）：换主题后最外层的 `ListenableBuilder` 整棵重建。
/// [build] 每次重建都现造一个实例——修好之后的调用点就是这个样子。
Future<void> pumpUnder(WidgetTester tester, Listenable tick, Widget Function() build) {
  return tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: Size(900, 600)),
        child: ListenableBuilder(listenable: tick, builder: (_, _) => build()),
      ),
    ),
  );
}

/// 换到深色并重建一次（`Theming.apply` 只换颜色表，重建由调用方触发）。
Future<void> toDark(WidgetTester tester, ValueNotifier<int> tick) async {
  expect(t.Theming.apply(t.AppTheme.dark), isTrue, reason: '起点必须是浅色，否则下面的断言恒真');
  tick.value++;
  await tester.pump();
}

void main() {
  tearDown(t.Theming.reset);
  tearDown(t.Fonts.reset);

  testWidgets('转录正文：换主题后字色与行内代码底色跟着走', (WidgetTester tester) async {
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    final String md = '正文一段，里头有 `inline code`。';
    await pumpUnder(tester, tick, () => MarkdownBody(md));

    Text paragraph() => tester.widget<Text>(find.byType(Text).first);
    Color? inlineCodeBackground() {
      Color? found;
      paragraph().textSpan!.visitChildren((InlineSpan span) {
        final Color? bg = span.style?.backgroundColor;
        if (bg == null) return true;
        found = bg;
        return false;
      });
      return found;
    }

    expect(paragraph().style!.color, t.Theming.lightColors.text);
    expect(inlineCodeBackground(), t.Theming.lightColors.surface);

    await toDark(tester, tick);

    expect(paragraph().style!.color, t.Theming.darkColors.text, reason: '缓存的块实例原样返回的话这里还是浅色的字');
    expect(inlineCodeBackground(), t.Theming.darkColors.surface);
  });

  testWidgets('代码块：换主题后高亮色表跟着走（高亮结果按字体代数缓存）', (WidgetTester tester) async {
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    await pumpUnder(tester, tick, () => MarkdownBody('```dart\nvoid main() {}\n```'));

    // 关键字 `void` 的颜色（画板 13：关键字 = accent 文字色）。
    Color? keywordColor() {
      Color? found;
      tester.widget<Text>(find.descendant(of: find.byType(CodeBlock), matching: find.byType(Text)).last).textSpan!.visitChildren((InlineSpan span) {
        if (span is TextSpan && span.text == 'void') {
          found = span.style?.color;
          return false;
        }
        return true;
      });
      return found;
    }

    expect(keywordColor(), t.Theming.lightColors.accentText);
    await toDark(tester, tick);
    expect(keywordColor(), t.Theming.darkColors.accentText, reason: '高亮缓存没按代数失效的话还是浅色那套');
  });

  testWidgets('registry 行：徽章与占位菱形跟着换主题', (WidgetTester tester) async {
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    // `installed: true` → `const ToneChip('已安装', tone: ChipTone.success)`；
    // `iconSvg` 不给 → `AgentIconBox` 里是 `const _Diamond()`。
    final RegistryEntryData entry = const RegistryEntryData(id: 'demo', name: 'Demo', version: '1.0.0', description: '', installed: true);
    await pumpUnder(tester, tick, () => RegistryEntryRow(entry));

    Color chipBackground() =>
        tester.widget<Chip>(find.descendant(of: find.byType(ToneChip), matching: find.byType(Chip))).background;
    Color diamondColor() => tester
        .widgetList<Container>(find.descendant(of: find.byType(AgentIconBox), matching: find.byType(Container)))
        .firstWhere((Container c) => c.color != null)
        .color!;

    expect(chipBackground(), t.Theming.lightColors.successSoft);
    expect(diamondColor(), t.Theming.lightColors.placeholder);

    await toDark(tester, tick);

    expect(chipBackground(), t.Theming.darkColors.successSoft, reason: '常量实例被复用的话徽章还是浅色那套');
    expect(diamondColor(), t.Theming.darkColors.placeholder);
  });

  testWidgets('收起条的 chevron 跟着换主题', (WidgetTester tester) async {
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    void onTap() {}
    await pumpUnder(tester, tick, () => CollapseBar(onTap: onTap));

    Color? chevronColor() =>
        tester.widget<AcpIcon>(find.descendant(of: find.byType(Chevron), matching: find.byType(AcpIcon))).color;

    expect(chevronColor(), t.Theming.lightColors.placeholder);
    await toDark(tester, tick);
    expect(chevronColor(), t.Theming.darkColors.placeholder);
  });

  testWidgets('等待行的 spinner 跟着换主题', (WidgetTester tester) async {
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    await pumpUnder(tester, tick, () => AwaitingRow());

    Color? spinnerColor() =>
        tester.widget<AcpIcon>(find.descendant(of: find.byType(Spinner), matching: find.byType(AcpIcon))).color;

    expect(spinnerColor(), t.Theming.lightColors.accentBase);
    await toDark(tester, tick);
    expect(spinnerColor(), t.Theming.darkColors.accentBase);
  });

  testWidgets('文件查看器空态跟着换主题', (WidgetTester tester) async {
    final ValueNotifier<int> tick = ValueNotifier<int>(0);
    addTearDown(tick.dispose);
    final TextEditingController filter = TextEditingController();
    final FocusNode focus = FocusNode();
    addTearDown(filter.dispose);
    addTearDown(focus.dispose);
    final FileTree tree = FileTree(root: 'D:/ws/proj', loader: (_) async => <FileEntry>[]);
    await pumpUnder(tester, tick, () => FilesPanel(tree: tree, filterController: filter, filterFocusNode: focus));

    Color? emptyBackground() => tester
        .widget<Container>(find.descendant(of: find.byType(FileViewerEmpty), matching: find.byType(Container)).first)
        .color;

    expect(emptyBackground(), t.Theming.lightColors.canvas);
    await toDark(tester, tick);
    expect(emptyBackground(), t.Theming.darkColors.canvas);
  });
}
