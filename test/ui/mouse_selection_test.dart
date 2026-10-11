// 输入框与用户气泡的鼠标选取测试：
// 1. AcpTextField 鼠标拖拽选区、双击选词、三击全选；
// 2. UserMessage 气泡在 SelectableRegion 中双击选词、跨段拖选不中断；
// 3. UserMessage 悬浮操作栏（Popover）在 Hover 时正常浮现并能点击。

import 'package:acp_agent_client/projection/entries.dart';
import 'package:acp_agent_client/projection/session_store.dart';
import 'package:acp_agent_client/projection/wire.dart';
import 'package:acp_agent_client/theme/tokens.dart' as t;
import 'package:acp_agent_client/ui/shell/shell_common.dart';
import 'package:acp_agent_client/ui/transcript/card_chrome.dart';
import 'package:acp_agent_client/ui/transcript/icons.dart';
import 'package:acp_agent_client/ui/transcript/user_message.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../gallery_harness.dart';

SessionStore newStore() {
  var t = DateTime.utc(2026, 9, 15, 12);
  return SessionStore(sessionId: 'test_sess', clock: () => t = t.add(const Duration(seconds: 1)));
}

JsonMap userChunk(String text) => <String, dynamic>{
      'sessionUpdate': 'user_message_chunk',
      'content': <String, dynamic>{'type': 'text', 'text': text},
    };

void main() {
  setUpAll(() async {
    await loadGalleryFonts();
    await precacheIcons();
  });

  group('AcpTextField 文本选区与手势', () {
    testWidgets('鼠标双击选中单词', (tester) async {
      final controller = TextEditingController(text: 'hello world delta');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        DefaultTextEditingShortcuts(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(
                  builder: (_) => Center(
                    child: SizedBox(
                      width: 300,
                      height: 50,
                      child: AcpTextField(
                        controller: controller,
                        focusNode: focusNode,
                        style: t.TextStyles.body,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFinder = find.byType(EditableText);
      expect(textFinder, findsOneWidget);

      final textTopLeft = tester.getTopLeft(textFinder);
      final clickPos = textTopLeft + const Offset(65, 10);

      final gesture = await tester.startGesture(clickPos, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.down(clickPos);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.selection.isCollapsed, isFalse, reason: '双击后应当建立非折叠选区');
      final selectedText = controller.text.substring(controller.selection.start, controller.selection.end);
      expect(selectedText, 'world');
    });

    testWidgets('鼠标拖拽拉取选区', (tester) async {
      final controller = TextEditingController(text: 'hello world delta');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        DefaultTextEditingShortcuts(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(
                  builder: (_) => Center(
                    child: SizedBox(
                      width: 300,
                      height: 50,
                      child: AcpTextField(
                        controller: controller,
                        focusNode: focusNode,
                        style: t.TextStyles.body,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFinder = find.byType(EditableText);
      final textTopLeft = tester.getTopLeft(textFinder);

      final startPos = textTopLeft + const Offset(45, 10);
      final endPos = textTopLeft + const Offset(100, 10);

      final gesture = await tester.startGesture(startPos, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(endPos);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.selection.isCollapsed, isFalse, reason: '拖拽后应当建立选区');
      expect(controller.selection.start, lessThan(controller.selection.end));
    });

    testWidgets('鼠标三击选中整行', (tester) async {
      final controller = TextEditingController(text: 'alpha beta gamma');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        DefaultTextEditingShortcuts(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(
                  builder: (_) => Center(
                    child: SizedBox(
                      width: 300,
                      height: 50,
                      child: AcpTextField(
                        controller: controller,
                        focusNode: focusNode,
                        style: t.TextStyles.body,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFinder = find.byType(EditableText);
      final textTopLeft = tester.getTopLeft(textFinder);
      final clickPos = textTopLeft + const Offset(50, 10);

      final gesture = await tester.startGesture(clickPos, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.down(clickPos);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.down(clickPos);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(controller.selection.isCollapsed, isFalse);
      expect(controller.selection.start, 0);
      expect(controller.selection.end, controller.text.length);
    });

    testWidgets('建立选区后按 Backspace 删除选区，保留未选中内容', (tester) async {
      final controller = TextEditingController(text: 'hello world delta');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        DefaultTextEditingShortcuts(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Overlay(
              initialEntries: <OverlayEntry>[
                OverlayEntry(
                  builder: (_) => Center(
                    child: SizedBox(
                      width: 300,
                      height: 50,
                      child: AcpTextField(
                        controller: controller,
                        focusNode: focusNode,
                        style: t.TextStyles.body,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFinder = find.byType(EditableText);
      final textTopLeft = tester.getTopLeft(textFinder);
      // 双击 "world" 建立选区
      final clickPos = textTopLeft + const Offset(65, 10);
      final gesture = await tester.startGesture(clickPos, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.down(clickPos);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 验证焦点和选区确实落在 "world" 上
      expect(focusNode.hasFocus, isTrue, reason: '双击手势后应当聚焦输入框');
      expect(controller.selection.isCollapsed, isFalse, reason: '双击后应当建立选区');
      final selectedSubstring = controller.text.substring(controller.selection.start, controller.selection.end);
      expect(selectedSubstring, 'world');

      // 发送真实键盘 Backspace 键事件
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();

      // 验证仅选中的 "world" 被删除，未选中的 "hello " 与 " delta" 被完整保留
      expect(controller.text, 'hello  delta');
      expect(controller.selection.isCollapsed, isTrue);

      // 全选并删除
      controller.selection = TextSelection(baseOffset: 0, extentOffset: controller.text.length);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(controller.text, isEmpty);
    });
  });

  group('UserMessage 气泡选区与悬浮交互', () {
    testWidgets('在 SelectableRegion 中双击气泡文字能选中单词', (tester) async {
      SelectedContent? currentSelection;
      final store = newStore();
      store.applyUpdateJson(userChunk('quick brown fox'));
      final entry = store.entries.whereType<MessageEntry>().single;
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => SelectableRegion(
                  focusNode: focusNode,
                  selectionControls: emptyTextSelectionControls,
                  onSelectionChanged: (s) => currentSelection = s,
                  child: Center(
                    child: SizedBox(
                      width: 400,
                      child: UserMessage(entry),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFinder = find.text('quick brown fox');
      expect(textFinder, findsOneWidget);

      final textTopLeft = tester.getTopLeft(textFinder);
      final clickPos = textTopLeft + const Offset(65, 10);

      final gesture = await tester.startGesture(clickPos, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.down(clickPos);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(currentSelection, isNotNull, reason: '双击后 SelectableRegion 应当产生选区');
      expect(currentSelection!.plainText.trim(), 'brown');
    });

    testWidgets('鼠标 Hover 时 Popover 正常浮现且点击触发回调', (tester) async {
      var restoreCalled = false;
      final store = newStore();
      store.applyUpdateJson(userChunk('hoverable message'));
      final entry = store.entries.whereType<MessageEntry>().single;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => Center(
                  child: SizedBox(
                    width: 400,
                    child: UserMessage(
                      entry,
                      onRestore: () => restoreCalled = true,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 初始非 hover 状态，Popover 的 Visibility visible: false
      final popoverVisibility = find.descendant(
        of: find.byType(UserMessage),
        matching: find.byType(Visibility),
      );
      expect(popoverVisibility, findsOneWidget);
      expect((tester.widget(popoverVisibility) as Visibility).visible, isFalse);

      // 鼠标移动到气泡上
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.text('hoverable message')));
      await tester.pumpAndSettle();

      // Hover 触发后，Popover 变为可见
      expect((tester.widget(popoverVisibility) as Visibility).visible, isTrue);

      // Popover 中的三个操作按钮可见
      final restoreIcon = find.descendant(
        of: find.byType(Popover),
        matching: find.byWidgetPredicate((w) => w is IconButtonGhost && w.icon == AcpIcons.rotateCcw),
      );
      expect(restoreIcon, findsOneWidget);

      await tester.tap(restoreIcon);
      await tester.pumpAndSettle();
      expect(restoreCalled, isTrue, reason: '点击 Restore 按钮应当触发 onRestore 回调');
    });

    testWidgets('跨越用户气泡边缘拖选时不中断、选区保持连贯', (tester) async {
      SelectedContent? currentSelection;
      final store = newStore();
      store.applyUpdateJson(userChunk('first user message'));
      final entry1 = store.entries.whereType<MessageEntry>().single;
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(
                builder: (_) => SelectableRegion(
                  focusNode: focusNode,
                  selectionControls: emptyTextSelectionControls,
                  onSelectionChanged: (s) => currentSelection = s,
                  child: Center(
                    child: SizedBox(
                      width: 400,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          UserMessage(entry1),
                          const SizedBox(height: 20),
                          Text('second assistant message', style: t.TextStyles.body),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final firstText = find.text('first user message');
      final secondText = find.text('second assistant message');
      expect(firstText, findsOneWidget);
      expect(secondText, findsOneWidget);

      final startPos = tester.getTopLeft(firstText) + const Offset(-2, 5);
      final endPos = tester.getBottomRight(secondText) + const Offset(10, 5);

      final gesture = await tester.startGesture(startPos, kind: PointerDeviceKind.mouse);
      await tester.pump();
      await gesture.moveTo(endPos);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(currentSelection, isNotNull);
      final text = currentSelection!.plainText;
      expect(text, contains('first user message'));
      expect(text, contains('second assistant message'));
    });
  });
}

