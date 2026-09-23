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

  /// `promptCapabilities.image`：不支持图片的 agent 不取位图，复制的图片文件也按路径引用。
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
    await _updateMentionMenu(token);
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

  /// `token` 是发起这次查询时光标处的整个 `@…`（含 `@`）：fs 回来之后要拿它复核，见下面的过期判据。
  Future<void> _updateMentionMenu(String token) async {
    final b = bridge;
    // 提及的根用当前会话的 cwd（agent 按它解析路径），没有才回落到当前项目。
    final cwd = _store()?.cwd ?? _cwd();
    if (b == null || cwd == null) {
      _clearInlineMenu();
      touch();
      return;
    }
    final query = token.substring(1);
    final applied = await guard(() async {
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
      // 等 fs 的这几十到几百毫秒里用户可能已经改词、清空或把整句删掉：光标处的 token 不再是发起这次
      // 查询的那个就把结果丢掉，不写回也不通知——旧词的菜单不该盖在新词上，更不该在整句删完之后弹出来。
      // **只认正文**：Esc（[closeInlineMenu]）与点输入框外都不动正文，所以「一个字没改就按 Esc / 点走」
      // 那一下这里判不出来，结果照样写回；那半边要立「已被撤掉」的态，属机制类改动，没做（审查 P2，
      // 2026-09-22；所有者实测未复现，2026-09-23 关闭，见 `rounds/BACKLOG-CLOSED.md`）。
      if (_activeToken(editor.text) != token) return false;
      _clearInlineMenu();
      _mentionFiles = files;
      _mentionDirs = dirs;
      return true;
    });
    // 过期（false）不通知；桥抛错（null）由 `guard` 自己通知过了。
    if (applied == true) touch();
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

  /// Files & Directories（照 Zed 的做法）：往正文末尾插一个 `@`、聚焦，弹出画板 42 的 `@` 菜单——根目录一层的
  /// 文件与目录，接着打字就是搜索，挑中走 [_pickMention] 同一条路。不再弹原生对话框：Windows 的文件对话框只有
  /// 「选文件」与「选文件夹」两种模式，选文件那种点目录只会进到下一级，目录加不进来（所有者报障 2026-09-23）。
  /// 程序改 `editor.text` 不会触发输入框的 `onChanged`，所以这里自己调 [onChanged]。
  Future<void> startMention() async {
    final sep = editor.text.isEmpty || RegExp(r'\s$').hasMatch(editor.text) ? '' : ' ';
    editor.text = '${editor.text}$sep@';
    editor.selection = TextSelection.collapsed(offset: editor.text.length);
    focus.requestFocus();
    touch();
    await onChanged(editor.text);
  }

  /// 指向磁盘上某个文件或目录的 `resource_link`，正文里留一个 `@名字`（与 `@` 菜单挑中是同一个形状）。
  /// 粘贴进来的路径走这里：项目外的文件与目录只有这条路加得进来。
  void addResourceLink(String path) {
    final name = _baseName(path);
    pendingBlocks.add(<String, dynamic>{'type': 'resource_link', 'uri': _fileUri(path), 'name': name});
    // 光标处是还没打词的裸 `@`（刚点了 Files & Directories，或刚敲了 `@`）：贴进来的这条就是它的补全，
    // 不在正文里留一个孤零零的 `@` 跟着发出去（审查 P2，2026-09-23）。一次贴多条时只有第一条吃掉它。
    if (_activeToken(editor.text) == '@') editor.text = editor.text.substring(0, editor.text.length - 1);
    _appendToComposer('@$name');
  }

  /// 路径的最后一段（`D:\a\b\` → `b`）；整条都是分隔符（不该发生）就原样用。
  static String _baseName(String path) {
    final parts = path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty);
    return parts.isEmpty ? path : parts.last;
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

  /// 输入框里已有几张图（[promptImageCountLimit] 按它算剩几张）。
  int get _pendingImageCount => pendingBlocks.where((b) => b['type'] == 'image').length;

  /// 张数门的提示，剪贴板与文件选择器两条路同一句。
  static const String _tooManyImages = '一条消息最多带 $promptImageCountLimit 张图，多出来的没有加进输入框';

  /// 拿到原始字节的那条路（`+` → Image 从文件选择器挑的图）：张数门与大小门都在这里，**判在 base64 之前**。
  /// 超 [clipboardImageSizeLimit] 的直接回报、不编码——base64 出来的字符串比原字节还大三分之一，
  /// 在 UI isolate 上同步建那一下正是界面卡住的原因，判在 [addImage] 里就已经晚了。
  /// 文案与剪贴板那条路同一句、不写死 MB 数（两条路的门不是同一个数，见 [clipboardImageSizeLimit]）。
  void addImageBytes(Uint8List bytes, String mimeType, {String? path}) {
    if (_pendingImageCount >= promptImageCountLimit) {
      lastError = _tooManyImages;
      touch();
      return;
    }
    if (bytes.length > clipboardImageSizeLimit) {
      lastError = '图片太大，没有加进输入框';
      touch();
      return;
    }
    addImage(base64Encode(bytes), mimeType, path: path);
  }

  /// Ctrl/Cmd+V（输入框的按键回调只管调这里，判断全在这）：剪贴板里是文本就什么都不做——
  /// 那一下已经由 `EditableText` 自己贴进去了。资源管理器里复制的文件与目录默认按路径加成 `resource_link`
  /// （[addResourceLink]）；agent 收图时，图片文件与截图加成 `image` 块。怎么分见 [readClipboard]。
  Future<void> pasteFromClipboard() async {
    if (!_canCompose()) return;
    // 按键回调是 fire-and-forget（`onPaste?.call()` 没人 await），所以这里自己兜住：
    // `Clipboard.getData` 在剪贴板被别的进程占着时会抛 `PlatformException`，不兜就成了未捕获的异步错误。
    await guard(() async {
      final text = await Clipboard.getData(Clipboard.kTextPlain);
      if ((text?.text ?? '').isNotEmpty) return;
      // 不收图的 agent 照样要读：复制的文件按路径引用与图无关（位图那半 runner 就不取了）。
      // 剩几张按输入框里已有的算（满了传 0：剪贴板里真有图才报「最多 N 张」，空剪贴板不误报）。
      final remaining = promptImageCountLimit - _pendingImageCount;
      final result = await readClipboard(images: _canPromptImage(), maxImages: remaining < 0 ? 0 : remaining);
      var tooMany = result.skippedTooMany;
      var added = false;
      for (final image in result.images) {
        // 连按两下 Ctrl+V 时两次读取是并发的，各按读之前的余量收：落进输入框这一下再按当前的张数判一次。
        if (_pendingImageCount >= promptImageCountLimit) {
          tooMany = true;
          break;
        }
        addImage(base64Encode(image.bytes), image.mimeType, path: image.path);
        added = true;
      }
      // 路径不受张数门管（不进内存、不占 prompt 里的图片额度）。
      for (final path in result.paths) {
        addResourceLink(path);
        added = true;
      }
      if (tooMany) {
        // 两种都有时报张数：收满了，被大小门跳掉的那几张反正也进不来。
        lastError = _tooManyImages;
        touch();
      } else if (result.skippedTooLarge) {
        // 不写死 MB 数：截图位图有两道门（编码后 20 MB / 像素 256 MB），共用这一个旗标。
        lastError = '图片太大，没有加进输入框';
        touch();
      }
      if (added) focus.requestFocus();
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
    // 正文此刻以空格结尾，光标处不可能还有 `@` / `/` token：开着的内联菜单（先点了 Files & Directories 再
    // Ctrl+V）要一起关掉，否则 Enter 选的是菜单项而不是发送（审查 P2，2026-09-23）。在途的 fs 结果回来时
    // 按过期判据自己丢掉。
    _clearInlineMenu();
    touch();
  }
}
