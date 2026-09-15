// 画板对照 gallery（ROUNDS.md § 0 第 5 条）：每张画板的每个状态以画板 frame 尺寸、fixtures 数据渲染成
// build/gallery/NN-<状态>.png（test/gallery_test.dart 离屏渲染），与 design/round-design/NN-*.png 并排看。
// 只在 debug / test 里编入；R0 只有 00 的 token 样板页。

import 'package:flutter/widgets.dart';

import 'boards/tokens_board.dart';

class GalleryBoard {
  const GalleryBoard({required this.id, required this.title, required this.frame, required this.build});

  /// 输出文件名主干，例：`00-tokens`。
  final String id;
  final String title;

  /// 画板 frame 尺寸（design/round-design/canvas.json）。
  final Size frame;
  final WidgetBuilder build;
}

final List<GalleryBoard> galleryBoards = <GalleryBoard>[
  GalleryBoard(
    id: '00-tokens',
    title: 'Token 表',
    frame: const Size(1440, 924),
    build: (_) => const TokensBoard(),
  ),
];
