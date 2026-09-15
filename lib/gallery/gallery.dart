// 画板对照 gallery（ROUNDS.md § 0 第 5 条）：每张画板以 fixtures 数据渲染成 build/gallery/NN-*.png
// （test/gallery_test.dart 离屏渲染），与 design/round-design/NN-*.png 并排看。只在 debug / test 里编入。
// R0：00 的 token 样板页（固定 frame）；R2：10–34 的画板页（宽 800、高随内容，见 lib/gallery/boards/transcript_boards.dart）。

import 'package:flutter/widgets.dart';

import 'boards/tokens_board.dart';
import 'boards/transcript_boards.dart';
import 'boards/transcript_boards_2.dart';

class GalleryBoard {
  const GalleryBoard({required this.id, required this.title, required this.frame, required this.build, this.fitContent = false});

  /// 输出文件名主干，例：`00-tokens`。
  final String id;
  final String title;

  /// 画板 frame 尺寸（design/round-design/canvas.json）；`fitContent` 时只取宽，高随内容。
  final Size frame;
  final WidgetBuilder build;
  final bool fitContent;
}

final List<GalleryBoard> galleryBoards = <GalleryBoard>[
  GalleryBoard(
    id: '00-tokens',
    title: 'Token 表',
    frame: const Size(1440, 924),
    build: (_) => const TokensBoard(),
  ),
  ...transcriptBoards,
  ...transcriptBoards2,
];
