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
//
// 正在组的字画在终端光标处：用的是 xterm 自己的组字串绘制（`RenderTerminal.composingText`，终端字体 + 下划线），
// 不另叠浮层。Windows 引擎在 `WM_IME_SETCONTEXT` 里剥掉了 `ISC_SHOWUICOMPOSITIONWINDOW`（组字串约定由应用自己画），
// 不画的话光标处什么都没有，只有输入法候选框里看得到拼音。

import 'package:flutter/rendering.dart';
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

  /// 画在光标处的组字串（已垫好前导空格，见 [_showComposing]）；null = 没在组字。
  String? _composing;

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
    return _ComposingKeeper(onLayout: _applyComposing, child: widget.child);
  }

  /// 有焦点且进程在跑就该有连接，否则不该有。
  void _sync() {
    if (!mounted) return;
    if (widget.enabled && widget.focusNode.hasFocus) {
      _open();
    } else {
      _close();
      _showComposing(null);
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

  void _showComposing(String? text) {
    // 前面垫一格：xterm 从光标格起画组字串、再在光标格上盖实心块光标，不垫的话第一个字母被光标盖住。
    _composing = text == null || text.isEmpty ? null : ' $text';
    _applyComposing();
  }

  /// 写进 xterm 的渲染对象：`RenderTerminal.composingText` 是公开的 setter，TerminalView 自己存组字串的那份状态是私有的。
  void _applyComposing() {
    final xt.TerminalViewState? view = widget.viewKey.currentState;
    if (view == null) return;
    try {
      view.renderTerminal.composingText = _composing;
    } catch (_) {
      // 同 [_updateCaret]：viewport 这一帧还没建好，等下一次 layout 再写。
    }
  }

  // ---- TextInputClient

  @override
  TextEditingValue? get currentTextEditingValue => _value;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue value) {
    _value = value;
    // 还在组字：候选还没选定，什么都别发给 shell，只画在光标处。画整串而不是 composing 那一段：基准恒为空串、
    // 上屏前一个字都没交出去，部分选定的「你hao」也还全在这里。
    if (!value.composing.isCollapsed) {
      _showComposing(value.text);
      return;
    }
    _showComposing(null);
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
    _showComposing(null);
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

/// 组字串的保鲜层：[xt.TerminalView] 每次重建都会在 `updateRenderObject` 里把 `composingText` 清回它自己那份私有
/// 状态（我们不走它的 `CustomTextEdit`，那份恒为 null），而终端面板每来一段 shell 输出就重建一次。这里在同一帧的
/// layout 阶段（build 之后、paint 之前）写回去；放 post-frame 会先画出一帧空的，输出不断时组字串就一直闪。
class _ComposingKeeper extends SingleChildRenderObjectWidget {
  const _ComposingKeeper({required this.onLayout, required super.child});

  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderComposingKeeper(onLayout);

  @override
  void updateRenderObject(BuildContext context, _RenderComposingKeeper renderObject) {
    // 走到这里说明这一帧 TerminalView 也跟着重建了。
    renderObject
      ..onLayout = onLayout
      ..markNeedsLayout();
  }
}

class _RenderComposingKeeper extends RenderProxyBox {
  _RenderComposingKeeper(this.onLayout);

  VoidCallback onLayout;

  @override
  void performLayout() {
    super.performLayout();
    onLayout();
  }
}
