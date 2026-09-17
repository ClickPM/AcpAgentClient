// 画板 70 的 agent 列表行：随包分发的内置 agent（R7 的 zed-agent-acp sidecar）**可见、不可编辑、不可删**
// （docs/design.md § 8）。它的 command / args 是按可执行文件位置合成的，落盘到 settings.json 之后
// 用户条目优先，合成的 --user-data-dir / --zed-settings 就不再生效，换台机器那条绝对路径还会失效。
//
// 这条用例建**真的 SettingsPage**、点真的按钮：审查第 2 轮指出，只断言投影层的 `builtin` 标志
// 等于什么都没测（把 widget 里的判断改回去，那种测试照样绿）。核心侧的拒写有
// `rust/acp-core/src/builtin.rs` 的 `builtin_entry_is_not_written_to_settings_json` 兜着。

import 'package:acp_agent_client/projection/registry.dart';
import 'package:acp_agent_client/ui/settings/settings_page.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

RegistryEntryData _custom(String id, {bool builtin = false}) => RegistryEntryData(
      id: id,
      name: builtin ? 'Zed Agent' : id,
      version: '',
      description: '',
      kind: DistributionKind.custom,
      installed: true,
      builtin: builtin,
      custom: CustomCommand(command: 'x', args: const <String>[], env: const <String, String>{}),
    );

Future<void> _pump(WidgetTester tester, Widget page) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(data: const MediaQueryData(size: Size(1200, 900)), child: page),
      ),
    );

void main() {
  testWidgets('画板 70：内置条目的「编辑」与 Remove 都点不动，普通 custom 条目照常', (WidgetTester tester) async {
    final List<String> edited = <String>[];
    final List<String> removed = <String>[];
    await _pump(
      tester,
      SettingsPage(
        agents: <RegistryEntryData>[_custom('dsh'), _custom('zed', builtin: true)],
        dataDir: 'D:/data',
        onEdit: edited.add,
        onRemove: removed.add,
      ),
    );

    // 普通 custom 条目：两个按钮都能点。
    await tester.tap(find.text('编辑').first);
    await tester.tap(find.text('Remove').first);
    await tester.pump();
    expect(edited, <String>['dsh']);
    expect(removed, <String>['dsh']);

    // 内置条目：点了没有任何回调（按钮置灰 = onTap 为 null）。
    await tester.tap(find.text('编辑').last);
    await tester.tap(find.text('Remove').last);
    await tester.pump();
    expect(edited, <String>['dsh'], reason: '内置 agent 不可编辑');
    expect(removed, <String>['dsh'], reason: '内置 agent 不可删');
  });
}
