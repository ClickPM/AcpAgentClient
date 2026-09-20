// 输入框（画板 01–03 / 40 / 42）的本地态（R7.5 从 workbench_controller.dart 拆出）：正文与焦点、待发的附件块、
// `@` / `/` 内联菜单（画板 42）、`+` 的四项（画板 40）、模型搜索框与三个弹层锚点、会话配置格的弹层锚点。
// 不知道会话：要用的三样（当前 store、当前项目目录、能不能发 / 能不能带图）经查询回调向组合根要；
// 发送本身在一轮对话控制器里，它取走正文与附件后调 [clearForSend]。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../projection/session_store.dart';
import '../projection/wire.dart';
import '../ui/popovers/inline_menus.dart';
import '../ui/shell/popover_anchor.dart';
import 'clipboard_image.dart';
import 'core_bridge.dart';
import 'guarded.dart';

class ComposerState extends ChangeNotifier with GuardedNotifier {
  ComposerState({
    required this.bridge,
    required this._store,
    required this._cwd,
    required this._canCompose,
    required this._canPromptImage,
  });

  final CoreCommands? bridge;

  /// 当前会话的 store（`/` 命令的来源、`@` 的根目录）。
  final SessionStore? Function() _store;

  /// 当前项目目录（没有会话时 `@` 的根目录退到它）。
  final String? Function() _cwd;

  /// 输入框可用（粘贴图片先看它）。
  final bool Function() _canCompose;

  /// `promptCapabilities.image`：不支持图片的 agent 连剪贴板都不用读。
  final bool Function() _canPromptImage;

  final TextEditingController editor = TextEditingController();
  final FocusNode focus = FocusNode();

  /// 输入框里待随下一条 prompt 发出的附件块（`+` 与 `@` 加进来的）。
  final List<JsonMap> pendingBlocks = <JsonMap>[];

  /// `@` / `/` 内联菜单（画板 42）的数据：两个来源同一时刻只可能有一个非空，都空 = 不显示。
  /// 存数据而不是存 widget，是因为键盘上下键要按它算高亮、Enter 要按它取项。
  List<MentionItem> _mentionFiles = const <MentionItem>[];
  List<MentionItem> _mentionDirs = const <MentionItem>[];
  List<AvailableCommandWire> _slashCommands = const <AvailableCommandWire>[];

  /// 键盘高亮下标（`@` 菜单里跨分组是全局的，与 [MentionMenu.items] 的拼接顺序一致）。
  int _inlineSelected = 0;

  /// 内联菜单 widget：null = 不显示。
  Widget? get inlineMenu {
    if (_slashCommands.isNotEmpty) {
      return SlashCommandMenu(commands: _slashCommands, selectedIndex: _inlineSelected, onPick: _pickCommand);
    }
    if (_mentionFiles.isNotEmpty || _mentionDirs.isNotEmpty) {
      return MentionMenu(
        files: _mentionFiles,
        directories: _mentionDirs,
        selectedIndex: _inlineSelected,
        onPick: _pickMention,
      );
    }
    return null;
  }

  final TextEditingController modelSearch = TextEditingController();
  final FocusNode modelSearchFocus = FocusNode();

  // ---- 弹层锚点（画板 40）
  final PopoverHandle plusAnchor = PopoverHandle();
  final PopoverHandle followAnchor = PopoverHandle();
  final PopoverHandle usageAnchor = PopoverHandle();

  /// 输入框右下每一格配置的弹层锚点：按 configOption 的 id 取（modes 回退那条用它的哨兵 id）。
  /// 惰性建、按 id 复用；换 agent 后旧 id 的锚点留着不回收（一个 agent 的条目是个位数），统一在 [dispose] 里收。
  final Map<String, PopoverHandle> _configAnchors = <String, PopoverHandle>{};

  /// 配置格的弹层锚点：id 一个，见 [_configAnchors]。
  PopoverHandle configAnchor(String id) => _configAnchors.putIfAbsent(id, PopoverHandle.new);

  void hideConfigPopovers() {
    for (final h in _configAnchors.values) {
      hidePopover(h);
    }
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[editor, modelSearch]) {
      c.dispose();
    }
    for (final f in <FocusNode>[focus, modelSearchFocus]) {
      f.dispose();
    }
    for (final h in <PopoverHandle>[plusAnchor, followAnchor, usageAnchor, ..._configAnchors.values]) {
      h.dispose();
    }
    super.dispose();
  }

  /// 发送时把正文、附件与内联菜单一起清掉（一轮对话控制器在取走快照之后调；不通知，收轮那次 `touch` 会带上）。
  void clearForSend() {
    editor.clear();
    pendingBlocks.clear();
    _clearInlineMenu();
  }

  // ---------------------------------------------------------------- 输入框的 @ 与 /

  /// 输入框正文变化：按最后一个 token 决定要不要出内联菜单（画板 42）。
  Future<void> onChanged(String text) async {
    final token = _activeToken(text);
    if (token == null) {
      closeInlineMenu();
      return;
    }
    if (token.startsWith('/')) {
      final q = token.substring(1).toLowerCase();
      final commands = <AvailableCommandWire>[
        for (final c in _store()?.commands ?? const <AvailableCommandWire>[])
          if (q.isEmpty || (c.name ?? '').toLowerCase().startsWith(q)) c,
      ];
      _clearInlineMenu();
      _slashCommands = commands;
      touch();
      return;
    }
    await _updateMentionMenu(token.substring(1));
  }

  /// 菜单开着（有东西可选）。
  bool get inlineMenuOpen => _inlineMenuCount > 0;

  int get _inlineMenuCount =>
      _slashCommands.isNotEmpty ? _slashCommands.length : _mentionFiles.length + _mentionDirs.length;

  void _clearInlineMenu() {
    _mentionFiles = const <MentionItem>[];
    _mentionDirs = const <MentionItem>[];
    _slashCommands = const <AvailableCommandWire>[];
    // 列表一换高亮就回第一条：每次改词后最匹配的那条在最上面。
    _inlineSelected = 0;
  }

  /// Esc：关掉菜单，输入框里的文本原样留着。
  void closeInlineMenu() {
    if (!inlineMenuOpen) return;
    _clearInlineMenu();
    touch();
  }

  /// 上下键移动高亮（`-1` / `+1`，首尾环绕）。
  void moveInlineMenuSelection(int delta) {
    final n = _inlineMenuCount;
    if (n == 0) return;
    _inlineSelected = (_inlineSelected + delta) % n;
    if (_inlineSelected < 0) _inlineSelected += n;
    touch();
  }

  /// Enter：把高亮项填进输入框（与鼠标点那一行同一条路，不发送）。
  void pickInlineMenuSelection() {
    if (!inlineMenuOpen) return;
    if (_slashCommands.isNotEmpty) {
      _pickCommand(_slashCommands[_inlineSelected]);
      return;
    }
    _pickMention(<MentionItem>[..._mentionFiles, ..._mentionDirs][_inlineSelected]);
  }

  /// 光标处的 `@` / `/` token：只在正文开头的 `/` 或空白后的 `@` 上触发。
  String? _activeToken(String text) {
    if (text.isEmpty) return null;
    if (text.startsWith('/') && !text.contains(RegExp(r'\s'))) return text;
    final m = RegExp(r'(?:^|\s)(@[^\s]*)$').firstMatch(text);
    return m?.group(1);
  }

  /// `@` 菜单一组最多几条（裸 `@` 列根目录、有词时是 `fs_search` 的 limit）。
  static const int _mentionLimit = 10;

  Future<void> _updateMentionMenu(String query) async {
    final b = bridge;
    // 提及的根用当前会话的 cwd（agent 按它解析路径），没有才回落到当前项目。
    final cwd = _store()?.cwd ?? _cwd();
    if (b == null || cwd == null) {
      _clearInlineMenu();
      touch();
      return;
    }
    await guard(() async {
      final List<MentionItem> files;
      final List<MentionItem> dirs;
      if (query.isEmpty) {
        // 裸 `@`：还没有可搜的词，`fs_search` 对空词按约定返回空结果（不做全量遍历），
        // 所以这一步改列项目根目录的一层——菜单一出来就有东西可选。
        final listing = await b.fsListDir(cwd, cwd);
        final entries = _toMentions(listing['entries']);
        files = <MentionItem>[for (final e in entries) if (!e.isDirectory) e].take(_mentionLimit).toList();
        dirs = <MentionItem>[for (final e in entries) if (e.isDirectory) e].take(_mentionLimit).toList();
      } else {
        final result = await b.fsSearch(cwd, query, limit: _mentionLimit);
        files = _toMentions(result['files']);
        dirs = _toMentions(result['directories']);
      }
      _clearInlineMenu();
      _mentionFiles = files;
      _mentionDirs = dirs;
    });
    touch();
  }

  List<MentionItem> _toMentions(Object? raw) => <MentionItem>[
        if (raw is List)
          for (final e in raw)
            if (e is Map)
              MentionItem(
                path: e['path'] as String? ?? '',
                name: e['name'] as String? ?? '',
                parent: e['parent'] as String? ?? '',
                isDirectory: e['isDir'] == true,
              ),
      ];

  void _pickCommand(AvailableCommandWire command) {
    editor.text = '/${command.name ?? ''} ';
    editor.selection = TextSelection.collapsed(offset: editor.text.length);
    _clearInlineMenu();
    focus.requestFocus();
    touch();
  }

  void _pickMention(MentionItem item) {
    final text = editor.text;
    final m = RegExp(r'(?:^|\s)(@[^\s]*)$').firstMatch(text);
    final replaced = m == null ? '$text@${item.name} ' : '${text.substring(0, m.start + (m.group(0)!.length - m.group(1)!.length))}@${item.name} ';
    editor.text = replaced;
    editor.selection = TextSelection.collapsed(offset: replaced.length);
    pendingBlocks.add(<String, dynamic>{
      'type': 'resource_link',
      'uri': _fileUri(item.path),
      'name': item.name,
    });
    _clearInlineMenu();
    focus.requestFocus();
    touch();
  }

  static String _fileUri(String path) => Uri.file(path, windows: Platform.isWindows).toString();

  // ---------------------------------------------------------------- `+` 的四项（画板 40）

  void addResourceLink(String path, String name) {
    pendingBlocks.add(<String, dynamic>{'type': 'resource_link', 'uri': _fileUri(path), 'name': name});
    _appendToComposer('@$name');
  }

  /// 输入框顶部芯片条的数据：待发的 `image` 块本身（规则 2，不另存一份视图状态）。
  List<ContentBlockWire> get pendingImages => <ContentBlockWire>[
        for (final b in pendingBlocks)
          if (b['type'] == 'image') ContentBlockWire(b),
      ];

  /// 芯片上的 ×。按**同一个 map 对象**删，不按内容比——两张一模一样的图也要能分别删掉。
  void removePendingBlock(ContentBlockWire block) {
    pendingBlocks.removeWhere((b) => identical(b, block.json));
    touch();
  }

  /// 图片不再往输入框塞 `[image]` 占位文本：它以芯片的形式显示在输入框顶部（[pendingImages]）。
  /// `path` 只在图来自磁盘上的文件时有，转成 `image` 块的可选 `uri`，芯片按它显示文件名。
  void addImage(String base64Data, String mimeType, {String? path}) {
    pendingBlocks.add(<String, dynamic>{
      'type': 'image',
      'data': base64Data,
      'mimeType': mimeType,
      if (path != null) 'uri': _fileUri(path),
    });
    touch();
  }

  /// Ctrl/Cmd+V（输入框的按键回调只管调这里，判断全在这）：剪贴板里是文本就什么都不做——
  /// 那一下已经由 `EditableText` 自己贴进去了；是截图 / 图片文件才加成 `image` 块。
  Future<void> pasteImageFromClipboard() async {
    if (!_canCompose()) return;
    // 按键回调是 fire-and-forget（`onPaste?.call()` 没人 await），所以这里自己兜住：
    // `Clipboard.getData` 在剪贴板被别的进程占着时会抛 `PlatformException`，不兜就成了未捕获的异步错误。
    await guard(() async {
      final text = await Clipboard.getData(Clipboard.kTextPlain);
      if ((text?.text ?? '').isNotEmpty) return;
      if (!_canPromptImage()) return; // 不支持图片的 agent：连剪贴板都不用读
      final result = await readClipboardImages();
      if (result.skippedTooLarge) {
        // 不写死 MB 数：剪贴板里的图有两道门（编码后 20 MB / 位图像素 256 MB），共用这一个旗标。
        lastError = '图片太大，没有加进输入框';
        touch();
      }
      if (result.images.isEmpty) return;
      for (final image in result.images) {
        addImage(base64Encode(image.bytes), image.mimeType, path: image.path);
      }
      focus.requestFocus();
    });
  }

  void addEmbeddedResource(String uri, String text, {String mimeType = 'text/plain'}) {
    pendingBlocks.add(<String, dynamic>{
      'type': 'resource',
      'resource': <String, dynamic>{'uri': uri, 'mimeType': mimeType, 'text': text},
    });
    _appendToComposer('[${Uri.parse(uri).pathSegments.isEmpty ? uri : Uri.parse(uri).pathSegments.last}]');
  }

  void _appendToComposer(String label) {
    final sep = editor.text.isEmpty || editor.text.endsWith(' ') ? '' : ' ';
    editor.text = '${editor.text}$sep$label ';
    editor.selection = TextSelection.collapsed(offset: editor.text.length);
    touch();
  }
}
