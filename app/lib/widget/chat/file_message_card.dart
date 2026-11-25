import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localchat_app/gen/strings.g.dart';
import 'package:localchat_app/model/conversation/conversation.dart';
import 'package:localchat_app/util/native/file_availability.dart';
import 'package:localchat_app/util/native/file_thumbnail.dart';
import 'package:localchat_app/util/native/platform_check.dart';
import 'package:localchat_app/util/native/video_frame.dart';
import 'package:localchat_isolates/model/file_type.dart';
import 'package:localchat_isolates/util/file_size_helper.dart';

IconData iconForFileType(FileType? type) {
  return switch (type) {
    FileType.image => Icons.image,
    FileType.video => Icons.movie,
    FileType.pdf => Icons.picture_as_pdf,
    FileType.text => Icons.description,
    FileType.apk => Icons.android,
    _ => Icons.insert_drive_file,
  };
}

/// [FORK] 判断「能不能出缩略图」时要按扩展名兜一层底。
///
/// 一是 `FileType` 只有六个桶，`guessFileType()` 也只认十几个扩展名——mkv / webm /
/// avi / webp 这些都很常见，却统统落进 `other`；二是历史消息里的 `fileType` 可能为
/// null。只按枚举判断，就会出现「系统明明能取到封面，卡片却画了一个空白页图标」。
/// 这里只补图片和视频两类（其余类型不出缩略图），故意不做全量的类型识别。
const _imageExtensions = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'bmp',
  'webp',
  'heic',
  'heif',
  'avif',
  'tif',
  'tiff',
  'dng',
  'ico',
};

const _videoExtensions = {
  'mp4',
  'mov',
  'mkv',
  'webm',
  'avi',
  'm4v',
  'wmv',
  'flv',
  'mpg',
  'mpeg',
  'ts',
  '3gp',
  'ogv',
};

/// 气泡内的文件卡片（图标 + 文件名 + 大小），可点击打开。
///
/// [FORK] 卡片会自己确认一次「本机还有没有这个文件」，因为 [ChatMessage] 里只记了
/// 一个路径，文件随时可能被移动 / 更名 / 删除：
/// - 磁盘上已经不在了 → 悬浮给一句提示，右键菜单里的「打开文件所在位置」置灰；
/// - `filePath` 为空（接收时没留下绝对路径，例如只存进了相册）→ 不算丢文件：
///   点击会由原生侧回查 MediaStore 找到那一项，再用图片查看器 / 播放器打开。
///
/// [FORK] 缩略图有两条来源：有可用路径的图片直接 `Image.file`；只进相册的媒体、
/// `content://` 的文件、以及 Android 上的视频首帧则交给原生取一张小图
/// （[FileThumbnailLoader]）——这几类没有 `Image.file` 能读的路径。
///
/// [FORK] 另外，**已传输完成**（sent / received）且在磁盘上确实存在的文件，鼠标
/// 悬浮到卡片上时会在大小右侧露出一个文件夹图标，点它直接在系统文件管理器里
/// 定位到这个文件——把右键菜单里藏得较深的一步搬到触手可及的位置。具体动作由
/// [onRevealInFolder] 提供，和右键菜单走同一份实现，行为不会出现两套。
class FileMessageCard extends StatefulWidget {
  final ChatMessage message;
  final bool isOutgoing;
  final VoidCallback? onTap;

  /// [FORK] 「在文件管理器中显示」的悬浮入口。为 null 表示这条消息不提供该入口
  /// （多选态、移动端），此时图标完全不出现。
  final VoidCallback? onRevealInFolder;

  const FileMessageCard({
    super.key,
    required this.message,
    required this.isOutgoing,
    this.onTap,
    this.onRevealInFolder,
  });

  @override
  State<FileMessageCard> createState() => _FileMessageCardState();
}

class _FileMessageCardState extends State<FileMessageCard> {
  /// 本机是否已经没有这个文件了。
  ///
  /// `null` = 还没查出来，按「可用」处理，避免在真相出来之前先把卡片画成不可用。
  bool? _missing;

  /// 鼠标当前是否停在卡片上。用来决定「状态刚变过来时要不要补一次提示」。
  bool _hovered = false;

  /// 由 [Tooltip] 承载：文件在鼠标已经悬停之后才被删时，enter 事件已经错过了，
  /// 只能靠这个手动补一次显示。
  final _tooltipKey = GlobalKey<TooltipState>();

  /// 视频首帧。取一次就存着，卡片重建（悬浮、状态变化）不重新解码。
  Future<Uint8List?>? _videoFrame;
  String? _videoFramePath;

  /// [FORK] 由原生取回的缩略图，覆盖 `Image.file` 画不了的那几类：
  /// 只存进了相册的媒体（没有路径）、`content://` 的文件、以及 Android 上的视频首帧。
  /// 取一次存着，重建不重取；取不到就保持 null，卡片自然露出下面的类型图标。
  Future<Uint8List?>? _nativeThumb;
  String? _nativeThumbKey;

  /// 路径为空是确定的不存在，不必等 IO；有路径才去 stat。
  ///
  /// [FORK] 「只存进了相册」是例外：文件确实在本机，只是没有路径。这条不能标成
  /// `missing`，否则卡片会一直挂一句「已保存到相册」的提示，而它其实是能打开的
  /// —— 点击会由原生侧回查 MediaStore 再交给对应应用。
  @override
  void initState() {
    super.initState();
    _missing = _initialMissing();
    if (_missing == null) {
      unawaited(_refreshMissing());
    }
    _ensureVideoFrame();
    _ensureNativeThumbnail();
  }

  /// `null` 表示「有路径，得去查」，其余两种情况不用等 IO。
  bool? _initialMissing() {
    if (widget.message.isOnlyInGallery) {
      return false;
    }
    final path = widget.message.filePath;
    return (path == null || path.isEmpty) ? true : null;
  }

  @override
  void didUpdateWidget(FileMessageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id || oldWidget.message.filePath != widget.message.filePath) {
      _missing = _initialMissing();
      if (_missing == null) {
        unawaited(_refreshMissing());
      }
      _ensureVideoFrame();
    }
    // 缩略图每次都问一遍：内部按 [_nativeThumbnailId] 判断要不要真去取，
    // 这样「接收完成后消息从占位变成『已存进相册』」这种同 id、同路径的变化也能补上图。
    _ensureNativeThumbnail();
  }

  /// 只在「确实是视频、而且路径变了」时才去取帧。
  void _ensureVideoFrame() {
    if (!_isVideo) {
      return;
    }
    // Android 的视频首帧由 [_ensureNativeThumbnail] 走原生取，这条路是 Windows
    // 专用的（Shell 缩略图服务），在这里调只会拿到 null。
    if (checkPlatform([TargetPlatform.android])) {
      return;
    }
    final path = widget.message.filePath;
    if (path == null || path.isEmpty || path == _videoFramePath) {
      return;
    }
    _videoFramePath = path;
    _videoFrame = VideoFrameLoader.load(path);
  }

  /// 这一步要不要交给原生取图。
  ///
  /// 判据和 [_buildThumbnail] 里 `Image.file` 的能力对齐：只有它画不了的才走原生。
  bool get _usesNativeThumbnail {
    if (!_isImage && !_isVideo) {
      return false;
    }
    // 只进了相册的媒体没有路径，只能回查 MediaStore。
    if (widget.message.isOnlyInGallery) {
      return true;
    }
    final path = widget.message.filePath;
    if (path == null || path.isEmpty) {
      return false;
    }
    // content:// 不是文件系统路径，Image.file / VideoFrameLoader 都读不了
    // （SAF 接收的文件、选择器选中的图片都是这种）。
    if (path.startsWith('content://')) {
      return true;
    }
    // 桌面端的视频首帧走 VideoFrameLoader，Android 没有那条路。
    return _isVideo && checkPlatform([TargetPlatform.android]);
  }

  /// 缓存键：只要这几项不变，取到的图就一直有效。
  String? get _nativeThumbnailId {
    if (!_usesNativeThumbnail) {
      return null;
    }
    final message = widget.message;
    // isOnlyInGallery 也放进键里：消息从「正在接收」变成「已存进相册」时路径可能没变，
    // 但这个标记会翻过来，不带它就是「永远不补图」。
    return '${message.id}|${message.filePath ?? ''}|${message.fileName ?? ''}|${message.fileSize}'
        '|${message.isOnlyInGallery}';
  }

  /// 只取一次：卡片重建（悬浮、状态变化、列表复用）不重新跨通道要图。
  void _ensureNativeThumbnail() {
    final id = _nativeThumbnailId;
    if (id == null || id == _nativeThumbKey) {
      return;
    }
    _nativeThumbKey = id;
    // 时间戳只在「没有路径、要回查相册」时有用：Gal 遇到重名会改名，名字+大小
    // 对不上时靠接收时间窗兜底。
    _nativeThumb = FileThumbnailLoader.load(
      key: id,
      path: widget.message.filePath,
      fileName: widget.message.fileName,
      fileSize: widget.message.fileSize,
      timestampMs: widget.message.timestamp.millisecondsSinceEpoch,
      size: 96,
    );
  }

  String? get _extension {
    final name = widget.message.fileName;
    if (name == null) {
      return null;
    }
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return null;
    }
    return name.substring(dot + 1).toLowerCase();
  }

  bool get _isImage => widget.message.fileType == FileType.image || _imageExtensions.contains(_extension);

  bool get _isVideo => widget.message.fileType == FileType.video || _videoExtensions.contains(_extension);

  /// 图标兜底时用的类型：枚举可能是 other / null（老消息、少见的容器），
  /// 但扩展名已经认出来是图片或视频了，就别再画一个空白页。
  FileType? get _displayType {
    if (_isVideo) {
      return FileType.video;
    }
    if (_isImage) {
      return FileType.image;
    }
    return widget.message.fileType;
  }

  /// 左侧方块的内容：能拿到图就画图，拿不到就画类型图标。
  ///
  /// 图标压在底层、缩略图盖在上面，是刻意的——图片解码失败、视频还没取到帧、
  /// 文件被删，都会自然露出下面的图标，不需要额外的状态判断。
  Widget _buildLogo(Color iconColor) {
    final thumbnail = _buildThumbnail();
    return Stack(
      fit: StackFit.expand,
      children: [
        Icon(iconForFileType(_displayType), color: iconColor),
        ?thumbnail,
      ],
    );
  }

  Widget? _buildThumbnail() {
    // 原生这张图能覆盖的前提先试——【只进相册 / content:// / Android 视频首帧】。
    final nativeThumbnail = _buildNativeThumbnail();
    if (nativeThumbnail != null) {
      return nativeThumbnail;
    }

    final path = widget.message.filePath;
    if (path == null || path.isEmpty) {
      return null;
    }

    if (_isImage) {
      // content:// 是 Android 的另一套 IO，得异步读字节——这种情况上面已经交给
      // 原生处理了，走到这里说明原生也没拿到；`Image.file` 读不了，回落到图标。
      if (path.startsWith('content://')) {
        return null;
      }
      return Image.file(
        File(path),
        fit: BoxFit.cover,
        // 40dp 的方块，2x 屏要 80px；96 留一点余量，也顺便限制解码后的内存。
        cacheWidth: 96,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }

    if (_isVideo && _videoFrame != null) {
      return FutureBuilder<Uint8List?>(
        future: _videoFrame,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null) {
            return const SizedBox.shrink();
          }
          return _withPlayBadge(Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true));
        },
      );
    }

    return null;
  }

  /// 原生取回的那张图。还没回来 / 取不到时返回 null，让调用方继续走路径那条路
  /// （或直接露出图标）。
  Widget? _buildNativeThumbnail() {
    final future = _nativeThumb;
    if (future == null) {
      return null;
    }
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return const SizedBox.shrink();
        }
        final image = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
        return _isVideo ? _withPlayBadge(image) : image;
      },
    );
  }

  /// 视频帧和图片长得很像，右下角给个播放角标，一眼区分。
  Widget _withPlayBadge(Widget child) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned(
          right: 2,
          bottom: 2,
          child: Container(
            padding: const EdgeInsets.all(1),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(3)),
            child: const Icon(Icons.play_arrow_rounded, size: 11, color: Colors.white),
          ),
        ),
      ],
    );
  }

  /// 查一次文件是否还在磁盘上，结果有变化才重建。
  ///
  /// 「怎么算不在」的统一规则在 [localFileExists]（桌面端 + 绝对路径才真的 stat），
  /// 右键菜单里的「打开文件所在位置」用的是同一个函数，两处不会说两套话。
  Future<void> _refreshMissing() async {
    // 只进相册的消息没有路径可 stat，但它是能打开的：不要把它算成「不见了」。
    if (widget.message.isOnlyInGallery) {
      if (_missing != false) {
        setState(() => _missing = false);
      }
      return;
    }
    final exists = await localFileExists(widget.message.filePath);
    if (!mounted || _missing == !exists) {
      return;
    }
    setState(() => _missing = !exists);
    if (!exists && _hovered) {
      // 判断结果是「刚变过来的」且鼠标正停在卡片上：Tooltip 的 enter 事件早就过去了，
      // 不补这一下的话，用户得把鼠标挪开再挪回来才看得到提示。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tooltipKey.currentState?.ensureTooltipVisible();
      });
    }
  }

  /// 还能不能打开：有本地副本、且磁盘上确实还在。
  ///
  /// [FORK] 只存在于相册里的文件也算「能打开」—— 点击会回查 MediaStore 再交给
  /// 对应应用，不是死路。
  bool get _isOpenable {
    if (widget.message.isOnlyInGallery) {
      return true;
    }
    if (_missing == true) {
      return false;
    }
    return widget.message.filePath?.isNotEmpty ?? false;
  }

  /// 不可用时悬浮显示的说明。
  ///
  /// 三种原因的措辞分开：只进了相册是「文件在，去相册看」（[isOnlyInGallery] 已经
  /// 不算 missing，正常走不到这一支，留着是为了语义完整）；没有路径且不是相册是
  /// 「本来就没存到本机」；路径还在但盘上没有是「原来有、现在没了」—— 混成一句
  /// 会把还躺在相册里的图说成「不在本机」。
  String get _unavailableHint {
    if (widget.message.isOnlyInGallery) {
      return t.conversation.fileInGallery;
    }
    final path = widget.message.filePath;
    if (path == null || path.isEmpty) {
      return t.conversation.fileUnavailable;
    }
    return t.conversation.fileMovedOrDeleted;
  }

  /// [FORK] 要不要在大小右侧露出「在文件管理器中显示」的图标。
  ///
  /// 四个条件缺一不可：
  /// - 调用方给了 [FileMessageCard.onRevealInFolder]（多选态、移动端为 null）；
  /// - 传输已经完成（sent / received）。还在发的文件连落盘都没有，谈不上定位；
  /// - 本机确实还有这个文件（[localFileExists] 的结论，和能打开的条件同源）；
  /// - 桌面端。手机上没有「文件夹」可浏览，接收路径还可能是 `content://`，
  ///   `openFolder` 在那边走的是另一套语义。
  bool get _canRevealInFolder {
    if (widget.onRevealInFolder == null) {
      return false;
    }
    final status = widget.message.status;
    if (status != ChatMessageStatus.sent && status != ChatMessageStatus.received) {
      return false;
    }
    if (!checkPlatformIsDesktop()) {
      return false;
    }
    return _isOpenable;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = widget.message;
    // [FORK] 发出的气泡是固定蓝底（见 message_bubble.dart 的 kOutgoingBubbleColor），
    // 所以这一侧的文字/图标固定用白色系，不跟主题的 onPrimary 走。
    final titleColor = widget.isOutgoing ? Colors.white : theme.colorScheme.onSurface;
    final subColor = widget.isOutgoing ? Colors.white.withValues(alpha: 0.75) : theme.colorScheme.outline;
    final iconBg = widget.isOutgoing
        ? Colors.white.withValues(alpha: 0.22)
        : theme.colorScheme.surfaceContainerHighest;
    final iconColor = widget.isOutgoing ? Colors.white : theme.colorScheme.primary;

    Widget card = InkWell(
      onTap: widget.onTap,
      // [FORK] InkWell 默认用 WidgetStateMouseCursor.adaptiveClickable，而它在非 Web 平台
      // 返回 SystemMouseCursors.basic（桌面原生 App 的惯例是按钮不给手型），所以 Windows /
      // macOS 上悬浮文件卡片是普通箭头。这里显式要手型，但只给真能打开的卡片：
      // 路径为空或文件已经不在时保持箭头，避免暗示一个点不动的东西可以打开。
      mouseCursor: _isOpenable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            // 图片/视频帧要跟着方块一起裁圆角，不裁就是四个直角。
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius: BorderRadius.circular(8),
            ),
            child: _buildLogo(iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message.fileName ?? '',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: titleColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // [FORK] 「在文件管理器中显示」的图标放在 size 这一行的**右端**：
                // 文件体积靠左、图标贴右边缘，中间用 Spacer 撑开。这样一列文件卡片
                // 的图标在同一条竖线上，扫视时不用跟着文件名的长短左右找。
                Row(
                  children: [
                    Text(
                      message.fileSize.asReadableFileSize,
                      style: TextStyle(fontSize: 11, color: subColor),
                    ),
                    if (_canRevealInFolder) ...[
                      const Spacer(),
                      AnimatedOpacity(
                        opacity: _hovered ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        // 透明时一并挡掉点击与悬浮：看不见的按钮还能被点到是最糟的。
                        child: IgnorePointer(
                          ignoring: !_hovered,
                          child: _RevealInFolderButton(
                            color: subColor,
                            hoverColor: titleColor,
                            hoverBackground: widget.isOutgoing
                                ? Colors.white.withValues(alpha: 0.18)
                                : theme.colorScheme.primary.withValues(alpha: 0.10),
                            onTap: widget.onRevealInFolder!,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // 不可用才挂提示；能打开的卡片不弹任何东西，免得划过列表一路冒气泡。
    if (_missing == true) {
      card = Tooltip(
        key: _tooltipKey,
        message: _unavailableHint,
        // 桌面端悬浮 0.4s 再出，划过列表时不会一路弹。
        waitDuration: const Duration(milliseconds: 400),
        child: card,
      );
    }

    // 悬停时再确认一次：文件可能是卡片渲染之后才被移动/删除的，
    // 靠 initState 那一次判断会一直显示过期的状态。
    // [FORK] 悬浮状态本身也要触发重建——「在文件管理器中显示」的图标靠它淡入淡出。
    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) {
          setState(() => _hovered = true);
        }
        unawaited(_refreshMissing());
      },
      onExit: (_) {
        if (_hovered) {
          setState(() => _hovered = false);
        }
      },
      child: card,
    );
  }
}

/// [FORK] 文件卡片上的「在文件管理器中显示」图标。
///
/// 用自绘的悬浮反馈而不是 `InkResponse`：气泡是一层带圆角的纯 `Container`，
/// 上面没有 `Material`，水波纹会画到页面级的 Material 上去（位置和形状都不对）。
class _RevealInFolderButton extends StatefulWidget {
  final Color color;
  final Color hoverColor;
  final Color hoverBackground;
  final VoidCallback onTap;

  const _RevealInFolderButton({
    required this.color,
    required this.hoverColor,
    required this.hoverBackground,
    required this.onTap,
  });

  @override
  State<_RevealInFolderButton> createState() => _RevealInFolderButtonState();
}

class _RevealInFolderButtonState extends State<_RevealInFolderButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: t.conversation.revealInFolder,
      // 和卡片上的其它提示保持一致：稍等一下再出，快速划过不闪。
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          // opaque：图标里 14px 的空白也要能点中，否则得瞄得很准。
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: _hover ? widget.hoverBackground : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              Icons.folder_open,
              size: 14,
              color: _hover ? widget.hoverColor : widget.color,
            ),
          ),
        ),
      ),
    );
  }
}
