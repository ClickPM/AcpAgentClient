// 终端的 IME 层（画板 61 的终端面板）：给 xterm 的 [xt.TerminalView] 补一条**带 viewId** 的平台文本输入连接，
// 中文输入法才能在终端里组字上屏。
//
// 为什么要自己开一条：TerminalView 走 `hardwareKeyboardOnly`（原因见 terminal_panel.dart 的注），那条路只认
// `KeyEvent.character`——而组字期间 Windows 把按键都报成 `VK_PROCESSKEY`，引擎当场判「已处理」、根本不发给框架
// （engine `keyboard_key_embedder_handler.cc`），组出来的字走的是 `WM_IME_*` → `TextInputPlugin`：没有一条文本输入
// 连接就没有 `active_model_`，一个字也收不到。xterm 自带的那条（`CustomTextEdit`）建连接时不带 `viewId`，正是
// Windows 引擎 `TextInput.setClient` 会直接拒掉的形状，所以这里自己开。
//
// 两条路不会打架：硬件按键被 xterm 判为已处理时引擎就不再派发 `WM_CHAR`（engine `keyboard_manager.cc` 的
// `HandleOnKeyResult`），所以 ASCII 只会进一次；组字期间没有按键事件，只有这条连接收得到。
//
// 参考 xterm 4.0.0 的 `lib/src/ui/custom_text_edit.dart`（MIT）改写：基准编辑状态恒为空串，上屏即交给终端再清回去
// （终端没有可编辑的文本模型，编辑器那套选区 / 删除都不需要）。

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:xterm/xterm.dart' as xt;

class TerminalIme extends StatefulWidget {
  const TerminalIme({
    super.key,
    required this.terminal,
    required this.focusNode,
    required this.viewKey,
    required this.enabled,
    required this.child,
  });

  final xt.Terminal terminal;

  /// 与 [xt.TerminalView] 同一个焦点节点：它拿到焦点就开连接，失焦就关。
  final FocusNode focusNode;

  /// 取光标矩形用（IME 候选框要贴着光标，不然停在窗口左上角）。
  final GlobalKey<xt.TerminalViewState> viewKey;

  /// 进程还在跑；终端只读（已退出）时不开连接。
  final bool enabled;

  final Widget child;

  @override
  State<TerminalIme> createState() => _TerminalImeState();
}

class _TerminalImeState extends State<TerminalIme> with TextInputClient {
  TextInputConnection? _connection;

  /// 基准编辑状态恒为空串：上屏的文本交给终端之后就清回这里。
  static const TextEditingValue _empty = TextEditingValue.empty;

  TextEditingValue _value = _empty;

  bool get _attached => _connection?.attached ?? false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_sync);
    // 首帧之后再开：`autofocus` 是在首帧的焦点结算里生效的，initState 这会儿还没有焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void didUpdateWidget(TerminalIme oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_sync);
      widget.focusNode.addListener(_sync);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_sync);
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 光标每帧回传一次：终端在滚、在打字，候选框得跟着走（没连接时是空操作）。
    _scheduleCaretUpdate();
    return widget.child;
  }

  /// 有焦点且进程在跑就该有连接，否则不该有。
  void _sync() {
    if (!mounted) return;
    if (widget.enabled && widget.focusNode.hasFocus) {
      _open();
    } else {
      _close();
    }
  }

  void _open() {
    if (_attached) return;
    _value = _empty;
    _connection = TextInput.attach(
      this,
      TextInputConfiguration(
        // 这一行就是 xterm 自带那条连接缺的东西（Windows 引擎缺它直接拒掉 setClient）。
        viewId: View.of(context).viewId,
        inputType: TextInputType.text,
        // 终端自己处理回车（keytab 出 `\r`），别让引擎再往编辑模型里塞换行。
        inputAction: TextInputAction.none,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
      ),
    )
      ..show()
      ..setEditingState(_empty);
    _scheduleCaretUpdate();
  }

  void _close() {
    final TextInputConnection? connection = _connection;
    _connection = null;
    _value = _empty;
    if (connection != null && connection.attached) connection.close();
  }

  void _scheduleCaretUpdate() {
    if (!_attached) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateCaret());
  }

  /// 把终端光标的位置交给引擎（`setEditableSizeAndTransform` + `setCaretRect`），IME 候选框才落在光标下面。
  void _updateCaret() {
    if (!mounted || !_attached) return;
    final xt.TerminalViewState? view = widget.viewKey.currentState;
    if (view == null) return;
    final RenderBox box;
    final Rect caret;
    try {
      // 两个取值都要穿过 TerminalView 里的 viewport key；这一帧还没建好时它会抛，跳过等下一帧。
      box = view.renderTerminal;
      caret = view.cursorRect;
    } catch (_) {
      return;
    }
    if (!box.attached || !box.hasSize) return;
    _connection
      ?..setEditableSizeAndTransform(box.size, box.getTransformTo(null))
      ..setCaretRect(caret);
  }

  // ---- TextInputClient

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    // 还在组字：候选还没选定，什么都别发给 shell。
    if (!value.composing.isCollapsed) return;
    final String text = value.text;
    if (text.isEmpty) return;
    widget.terminal.textInput(text);
    _value = _empty;
    _connection?.setEditingState(_empty);
  }

  @override
  void performAction(TextInputAction action) {
    // 回车、Tab 这些都由终端的 keytab 走硬件按键那条路，这里不重复。
  }

  @override
  void connectionClosed() {
    _connection = null;
    _sync();
  }

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}
}
