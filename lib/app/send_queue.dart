// Derived from zed-industries/zed crates/agent_ui/src/conversation_view/message_queue.rs @ d9e1c024f393832765a03f4de204d6c8cd9abcb2 (GPL-3.0-or-later)

import 'package:flutter/foundation.dart';

import '../projection/wire.dart';

/// 队列状态机的处理状态（对齐 Zed ProcessingState）。
enum ProcessingState {
  /// 正常排队，回合结束后自动按序发出。
  autoProcess,

  /// 上一轮出错或手动停止后安全挂起，不自动发。
  paused,

  /// 用户发起 Send Now / fast-track，正在等待当前回合 cancel 的 Stopped 事件，
  /// 吞掉该事件以防双发。
  absorbingCancel,
}

/// 队列中的一条消息项。
class QueueEntry {
  QueueEntry({
    required this.id,
    required this.content,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int id;
  final List<JsonMap> content;
  final DateTime createdAt;

  /// 提取纯文本正文用于标题与折叠摘要展示。
  String get plainText {
    final parts = <String>[];
    for (final b in content) {
      if (b['type'] == 'text' && b['text'] is String) {
        parts.add(b['text'] as String);
      }
    }
    return parts.join('\n').trim();
  }

  /// 提取所有非纯文本内容块（图片、文件资源引用等）。
  List<JsonMap> get attachmentBlocks =>
      content.where((b) => b['type'] != 'text').toList(growable: false);
}

/// 回合进行中的本地发送队列（对齐 Zed MessageQueue 状态机）。
/// 纯本地内存态：不落盘，切走会话保留、断开连接/关闭会话清空，只用 ACP 标准方法。
class SendQueue extends ChangeNotifier {
  final List<QueueEntry> _entries = <QueueEntry>[];
  ProcessingState _processingState = ProcessingState.autoProcess;
  bool _canFastTrack = false;
  int _nextId = 0;
  bool _isExpanded = false;

  bool get isEmpty => _entries.isEmpty;
  bool get isNotEmpty => _entries.isNotEmpty;
  int get length => _entries.length;
  List<QueueEntry> get entries => List<QueueEntry>.unmodifiable(_entries);

  QueueEntry? get first => _entries.isEmpty ? null : _entries.first;
  int? get firstId => _entries.isEmpty ? null : _entries.first.id;
  int? get lastId => _entries.isEmpty ? null : _entries.last.id;

  ProcessingState get processingState => _processingState;
  bool get isPaused => _processingState == ProcessingState.paused;
  bool get isAbsorbingCancel => _processingState == ProcessingState.absorbingCancel;
  bool get canFastTrack => _canFastTrack && _entries.isNotEmpty;

  bool get isExpanded => _isExpanded;
  set isExpanded(bool value) {
    if (_isExpanded != value) {
      _isExpanded = value;
      notifyListeners();
    }
  }

  void toggleExpanded() {
    _isExpanded = !_isExpanded;
    notifyListeners();
  }

  int nextId() => _nextId++;

  /// 入队一条新消息。入队是积极操作，若此前处于 Paused 态则自动恢复为 AutoProcess；
  /// 若处于 AbsorbingCancel（正在等待插队取消的在途回合结束），保持 AbsorbingCancel 不覆盖，防止取消收轮时双发。
  QueueEntry enqueue(List<JsonMap> content) {
    final entry = QueueEntry(id: nextId(), content: content);
    _entries.add(entry);
    if (_processingState == ProcessingState.paused) {
      _processingState = ProcessingState.autoProcess;
    }
    _canFastTrack = true;
    notifyListeners();
    return entry;
  }

  QueueEntry? remove(int id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index == -1) return null;
    final entry = _entries.removeAt(index);
    if (_entries.isEmpty) _canFastTrack = false;
    notifyListeners();
    return entry;
  }

  void clear() {
    _entries.clear();
    _canFastTrack = false;
    notifyListeners();
  }

  /// 将一条消息插回队首（用于发送冲突时安全回滚，不丢消息）。
  void prepend(QueueEntry entry) {
    _entries.insert(0, entry);
    notifyListeners();
  }

  /// 移除并返回队尾元素（空框按 ↑ 挪回输入框编辑用）。
  QueueEntry? popBack() {
    if (_entries.isEmpty) return null;
    final entry = _entries.removeLast();
    if (_entries.isEmpty) _canFastTrack = false;
    notifyListeners();
    return entry;
  }

  /// 用户在空输入框按 Enter 触发 fast-track 插队（Zed Send Now Enter）。
  /// 若当前正在生成，状态机转入 AbsorbingCancel；若当前空闲，则保持 AutoProcess。
  QueueEntry? tryFastTrack({required bool isGenerating}) {
    if (!canFastTrack) return null;
    _canFastTrack = false;
    if (_entries.isEmpty) return null;
    final entry = _entries.removeAt(0);
    _processingState = isGenerating
        ? ProcessingState.absorbingCancel
        : ProcessingState.autoProcess;
    notifyListeners();
    return entry;
  }

  /// 一轮生成结束时的收束调用：返回应自动出队发送的下一项（如有）。
  QueueEntry? onTurnStopped({bool isEditingFront = false}) {
    switch (_processingState) {
      case ProcessingState.absorbingCancel:
        // 由插队/Send Now 自身取消导致的 Stopped 事件：吞掉并重置为 AutoProcess，防止双发。
        _processingState = ProcessingState.autoProcess;
        notifyListeners();
        return null;
      case ProcessingState.paused:
        return null;
      case ProcessingState.autoProcess:
        if (isEditingFront) {
          return null;
        } else {
          if (_entries.isEmpty) return null;
          final entry = _entries.removeAt(0);
          if (_entries.isEmpty) _canFastTrack = false;
          notifyListeners();
          return entry;
        }
    }
  }

  /// 指定某项立即插队发送（Send Now）。
  /// 若回合在途，状态机转入 AbsorbingCancel。
  QueueEntry? sendNow(int id, {required bool isGenerating}) {
    final entry = remove(id);
    if (entry == null) return null;
    if (isGenerating) {
      _processingState = ProcessingState.absorbingCancel;
      notifyListeners();
    }
    return entry;
  }

  /// 手动停止或报错时挂起队列。
  void pause() {
    _processingState = ProcessingState.paused;
    notifyListeners();
  }

  /// 恢复队列自动出队（用户点击「恢复出队」或主动发消息）。
  void resume() {
    _processingState = ProcessingState.autoProcess;
    notifyListeners();
  }
}
