package org.localsend.localsend_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.core.content.FileProvider
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * 给聊天里的文件卡片取一张小缩略图，编码成 JPEG / PNG 字节回给 Dart。
 *
 * 为什么必须走原生：卡片的图源有两种情况，纯 Dart 都拿不到。
 * 1. **只写进了系统相册的媒体**——接收时被 `Gal` 搬进 MediaStore 后就删了缓存，
 *    消息里只剩文件名和大小，没有路径可交给 `Image.file`；
 * 2. **视频首帧**——Flutter 自己不解码视频，桌面端靠 Shell 的缩略图服务
 *    （见 `lib/util/native/video_frame.dart`），那条路在 Android 上没有。
 *
 * 拿不到就回 null：缩略图是「有更好」的东西，任何异常都不该冒到界面上，
 * 卡片自己会回落到类型图标。
 *
 * **注意**：这里可能读到别的应用写进相册的文件，所以全程用
 * `ContentResolver`（会按 UID 判权限），不要试图拼绝对路径去 `File()` 读。
 */
internal fun fileThumbnailBytes(
    context: Context,
    path: String?,
    fileName: String?,
    fileSize: Long,
    timestampMs: Long?,
    maxSizePx: Int,
): ByteArray? {
    val maxSize = maxSizePx.coerceIn(48, 512)
    val uri = resolveThumbnailUri(context, path, fileName, fileSize, timestampMs) ?: return null
    val mimeType = resolveThumbnailMimeType(context, uri, fileName)

    val bitmap = try {
        if (mimeType?.startsWith("video/") == true) {
            videoThumbnail(context, uri)
        } else {
            imageThumbnail(context, uri, maxSize)
        }
    } catch (_: Throwable) {
        null
    } ?: return null

    return try {
        encodeThumbnail(bitmap, maxSize)
    } finally {
        bitmap.recycle()
    }
}

/**
 * 定位要取图的那个 URI。
 *
 * - 有 `content://` 路径：直接用它（SAF 接收、选择器选中的文件都是这种）；
 * - 有绝对路径：换成自家 FileProvider 的 URI。Android 7+ 直接读 `file://` 会抛
 *   FileUriExposedException 且 scoped storage 下也读不到，FileProvider 是唯一两条路
 *   都能走通的中转；
 * - 都没有（只进了相册）：按名字 + 大小 + 接收时间去 MediaStore 回查，
 *   和点卡片打开时用的是同一套匹配（[findGalleryEntry]），不会「能打开但取不到图」。
 */
private fun resolveThumbnailUri(
    context: Context,
    path: String?,
    fileName: String?,
    fileSize: Long,
    timestampMs: Long?,
): Uri? {
    val raw = path?.takeIf { it.isNotBlank() }
    if (raw != null) {
        if (raw.startsWith("content://")) {
            return Uri.parse(raw)
        }
        return try {
            FileProvider.getUriForFile(context, "${context.packageName}.localsend.fileprovider", File(raw))
        } catch (_: IllegalArgumentException) {
            // 路径不在 file_paths.xml 允许的范围内（别的应用目录、挂载点等）。
            null
        }
    }
    return findGalleryEntry(context, fileName, fileSize, timestampMs)?.first
}

/**
 * 取 MIME 时**不能**只信扩展名：`content://` 的末段是数字 id，没有扩展名；
 * 而相册里的 MediaStore 项能直接回答准确类型。扩展名只在最后兜底。
 */
private fun resolveThumbnailMimeType(context: Context, uri: Uri, fileName: String?): String? {
    val fromResolver = try {
        context.contentResolver.getType(uri)
    } catch (_: Exception) {
        null
    }
    if (!fromResolver.isNullOrBlank()) {
        return fromResolver
    }
    val name = fileName ?: uri.lastPathSegment
    return name?.let { mimeTypeFromName(it) }?.takeIf { it != "*/*" }
}

/**
 * 图片缩略图。
 *
 * API 29+ 且是 MediaStore 里的项时优先用 `loadThumbnail`：它直接命中系统已经生成好的
 * 缩略图文件和缓存，比我们自己解码快一个数量级。自家 FileProvider 的 URI 不支持
 * `openTypedAssetFile`，会抛异常，落到下面的两趟解码。
 *
 * 两趟解码而不是「整个读进内存再解」：一张 10MB 的原图读进 ByteArray 再丢给
 * `BitmapFactory` 就是双倍内存，聊天列表里滚几张就可能 OOM。第一趟只读文件头拿
 * 尺寸（`inJustDecodeBounds`），第二趟按 `inSampleSize` 跳着解，峰值只有一个
 * 缩略图大小。
 */
private fun imageThumbnail(context: Context, uri: Uri, maxSize: Int): Bitmap? {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && uri.authority == "media") {
        try {
            return context.contentResolver.loadThumbnail(uri, Size(maxSize, maxSize), null)
        } catch (_: Exception) {
            // 缩略图没生成、权限被拒、provider 不支持…… 都退回自己解。
        }
    }

    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
        BitmapFactory.decodeFileDescriptor(pfd.fileDescriptor, null, bounds)
    }
    if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
        return null
    }

    val options = BitmapFactory.Options().apply {
        inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight, maxSize)
    }
    return context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
        BitmapFactory.decodeFileDescriptor(pfd.fileDescriptor, null, options)
    }
}

/** `inSampleSize` 只能是 2 的幂；取到「解码后仍不小于目标尺寸」的最小一档。 */
private fun sampleSizeFor(width: Int, height: Int, maxSize: Int): Int {
    var sample = 1
    while (maxOf(width, height) / (sample * 2) >= maxSize) {
        sample *= 2
    }
    return sample
}

/**
 * 视频首帧。
 *
 * 不直接用 `MediaStore` 的 `loadThumbnail`：系统生成封面时取的是最开头那一帧，
 * 而很多片源开头是黑场（淡入、片头），结果卡片就是一个纯黑方块，看起来像没取到图。
 * 这里自己按时间点试几帧，**跳过几乎全黑的**，取第一张有内容的。
 *
 * 取帧时 AFD 必须保持打开——`setDataSource(fd)` 只是记住描述符，真正读数据发生在
 * 取帧那一刻，提前关掉会解码失败。
 */
private fun videoThumbnail(context: Context, uri: Uri): Bitmap? {
    val retriever = MediaMetadataRetriever()
    return try {
        if (uri.scheme == "content") {
            val afd = context.contentResolver.openAssetFileDescriptor(uri, "r") ?: return null
            afd.use {
                retriever.setDataSource(it.fileDescriptor)
                firstNonBlankFrame(retriever)
            }
        } else {
            retriever.setDataSource(uri.path)
            firstNonBlankFrame(retriever)
        }
    } catch (_: Throwable) {
        null
    } finally {
        try {
            retriever.release()
        } catch (_: Throwable) {
            // release 失败不影响结果。
        }
    }
}

/**
 * 按「0 → 10% → 33% → 60%」几个时间点试帧，返回第一张不是黑场的。
 *
 * 全都很暗（夜景、纯黑片头）时退回第一张能解出来的——总比没有强。
 * 时间是按「视频时长」算的：短视频（几秒）也能落到有内容的画面上。
 */
private fun firstNonBlankFrame(retriever: MediaMetadataRetriever): Bitmap? {
    val durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
        ?.toLongOrNull()
        ?: 0L
    val times = if (durationMs <= 0) {
        listOf(0L)
    } else {
        listOf(0.0, 0.1, 0.33, 0.6)
            .map { (durationMs * it).toLong() }
            .distinct()
    }

    var fallback: Bitmap? = null
    for (timeMs in times) {
        val frame = try {
            // OPTION_CLOSEST_SYNC 只解关键帧，比逐帧解快得多；缩略图不在乎精确到毫秒。
            retriever.getFrameAtTime(timeMs * 1000, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
        } catch (_: Throwable) {
            null
        } ?: continue

        if (fallback == null) {
            fallback = frame
        }
        if (isNotBlank(frame)) {
            if (fallback !== frame) {
                fallback?.recycle()
            }
            return frame
        }
        // 黑帧且不是留作兜底的那张，当场回收——不然后面试几帧就白占几份大图内存。
        if (fallback !== frame) {
            frame.recycle()
        }
    }
    return fallback
}

/**
 * 这张图是不是「基本全黑」。缩到 8×8 再算平均亮度，开销可以忽略。
 *
 * 阈值取 24/255：纯黑、片头淡入的第一帧都远低于它，而正常的夜景画面也在它之上。
 */
private fun isNotBlank(frame: Bitmap): Boolean {
    val sample = try {
        Bitmap.createScaledBitmap(frame, 8, 8, false)
    } catch (_: Throwable) {
        return true
    }
    val pixels = sample.width * sample.height
    var sum = 0L
    for (y in 0 until sample.height) {
        for (x in 0 until sample.width) {
            val color = sample.getPixel(x, y)
            val r = (color shr 16) and 0xFF
            val g = (color shr 8) and 0xFF
            val b = color and 0xFF
            sum += (r * 299 + g * 587 + b * 114) / 1000
        }
    }
    if (sample !== frame) {
        sample.recycle()
    }
    return pixels > 0 && sum / pixels >= 24
}

/**
 * 缩到 [maxSize] 以内并编码。
 *
 * 有透明通道的（png / webp）保留 PNG，否则压 JPEG——聊天里的图绝大多数是照片，
 * JPEG 在同样观感下体积小好几倍，MethodChannel 传的字节数直接少一个量级。
 */
private fun encodeThumbnail(source: Bitmap, maxSize: Int): ByteArray? {
    val scaled = scaleToFit(source, maxSize)
    return try {
        val out = ByteArrayOutputStream()
        val format = if (scaled.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
        if (!scaled.compress(format, 85, out)) {
            return null
        }
        out.toByteArray()
    } finally {
        if (scaled !== source) {
            scaled.recycle()
        }
    }
}

private fun scaleToFit(bitmap: Bitmap, maxSize: Int): Bitmap {
    val width = bitmap.width
    val height = bitmap.height
    if (width <= 0 || height <= 0) {
        return bitmap
    }
    val longest = maxOf(width, height)
    if (longest <= maxSize) {
        return bitmap
    }
    val ratio = maxSize.toFloat() / longest
    val targetWidth = (width * ratio).toInt().coerceAtLeast(1)
    val targetHeight = (height * ratio).toInt().coerceAtLeast(1)
    return Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true)
}
