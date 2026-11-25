package org.localsend.localsend_app

import android.content.ActivityNotFoundException
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Parcelable
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File
import java.util.Locale

/**
 * 打开文件的结果，通过 MethodChannel 以 [wire] 字符串回给 Dart。
 *
 * [NO_APP] 和 [NOT_FOUND] 必须分开：一个是「手机上没有能打开这种格式的应用」，
 * 一个是「文件本身不在了」，给用户的提示完全不同。
 */
enum class OpenFileStatus(val wire: String) {
    OPENED("opened"),
    NO_APP("noApp"),
    NOT_FOUND("notFound"),
    FAILED("failed"),
}

/**
 * 用系统里真正能打开这个文件的应用打开 [uriStr]。
 *
 * 和直接 `startActivity(ACTION_VIEW)` 的三点区别：
 *
 * 1. **MIME 先问 `ContentResolver`**，猜不出来才按扩展名猜，最后兜底通配类型。
 *    以前兜底给的是 `vnd.android.document/directory`，于是 `content://media/external/images/media/123`
 *    这种末尾没有扩展名的 URI 全被当成「目录」，系统顺理成章地把请求交给了文档 UI /
 *    文件管理器 —— 点了图片跳进文件管理器，就是这么来的。
 * 2. **候选应用里剔掉文件管理器**。它们对通配类型声明了 VIEW，几乎总能出现在候选里，
 *    但「打开」不该落到一个让你再点一次文件的地方。
 * 3. **一个候选直接开**；多个候选且系统没有默认时，才弹选择器，且选择器里也只有
 *    筛选后的应用（用 `EXTRA_INITIAL_INTENTS` 拼装，不走原始 intent）。
 *
 * [isDirectory] 是给「在文件管理器中显示」用的例外：打开文件夹本来就该交给文档 UI，
 * 这时不猜 MIME，也不做文件管理器过滤。
 */
fun openUri(
    context: Context,
    uriStr: String,
    mimeTypeHint: String? = null,
    isDirectory: Boolean = false,
): OpenFileStatus {
    val uri = Uri.parse(uriStr)
    val mimeType = if (isDirectory) {
        DocumentsContract.Document.MIME_TYPE_DIR
    } else {
        resolveMimeType(context, uri, mimeTypeHint)
    }
    val intent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(uri, mimeType)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }

    val candidates = queryActivities(context, intent)
        .let { if (isDirectory) it else it.filter { info -> !isFileManager(info.packageName) } }
    if (candidates.isEmpty()) {
        return OpenFileStatus.NO_APP
    }

    return launch(context, intent, candidates)
}

/**
 * 打开本机某个绝对路径上的文件。
 *
 * 走 FileProvider 换成 content URI 再交给 [openUri]：Android 7+ 直接把 `file://`
 * 塞进 Intent 会抛 FileUriExposedException。这样绝对路径和 content URI 两条路
 * 共用同一套「按 MIME 找对应应用、剔掉文件管理器」的逻辑，行为不会两套。
 *
 * 故意不预判文件是否存在：Android 的 scoped storage 下 `File.exists()` 会因权限
 * 不足误报 false，把还能打开的文件挡掉。真不在了，打开器自己会报错。
 */
fun openFilePath(context: Context, path: String, mimeTypeHint: String? = null): OpenFileStatus {
    val file = File(path)
    val uri = try {
        FileProvider.getUriForFile(context, "${context.packageName}.localsend.fileprovider", file)
    } catch (_: IllegalArgumentException) {
        return OpenFileStatus.FAILED
    }
    // 这里不按文件名兜底猜 MIME：FileProvider 自己会根据扩展名回答
    // `ContentResolver.getType()`，比我们这张表准。
    return openUri(context, uri.toString(), mimeTypeHint)
}

/**
 * 打开一个「只写进了系统相册」的文件。
 *
 * 接收图片 / 视频时文件被搬进 MediaStore 后就删掉了缓存，消息里没有路径可交给
 * 打开器。这里按「文件名 + 大小」回查 MediaStore 拿到 content URI，再交给系统按
 * MIME 挑对应应用（图片查看器 / 播放器），而不是把用户丢进相册列表自己找。
 *
 * 查不到返回 [OpenFileStatus.NOT_FOUND] —— 记录还在但文件已经被删了，得说清楚。
 */
fun openGalleryMedia(
    context: Context,
    fileName: String?,
    fileSize: Long,
    timestampMs: Long?,
): OpenFileStatus {
    val entry = findGalleryEntry(context, fileName, fileSize, timestampMs)
        ?: return OpenFileStatus.NOT_FOUND
    return openUri(context, entry.first.toString(), entry.second)
}

/**
 * 在 MediaStore 里找接收时存进相册的那个文件。
 *
 * 三级匹配，从准到松：
 * 1. 文件名 + 大小 —— Gal 一般沿用原文件名，这条命中率最高；
 * 2. 大小 + 接收时间前后十分钟 —— Gal 遇到重名会改名，名字对不上时还有这条；
 * 3. 只按大小 / 只按名字 —— 兜底，取最近加入的一条。
 */
private fun findGalleryEntry(
    context: Context,
    fileName: String?,
    fileSize: Long,
    timestampMs: Long?,
): Pair<Uri, String?>? {
    val name = fileName?.takeIf { it.isNotBlank() }

    if (name != null && fileSize > 0) {
        queryFirstMedia(
            context,
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.SIZE} = ?",
            arrayOf(name, fileSize.toString()),
        )?.let { return it }
    }

    if (fileSize > 0) {
        val seconds = timestampMs?.takeIf { it > 0 }?.div(1000)
        if (seconds != null) {
            queryFirstMedia(
                context,
                "${MediaStore.MediaColumns.SIZE} = ? AND ${MediaStore.MediaColumns.DATE_ADDED} BETWEEN ? AND ?",
                arrayOf(fileSize.toString(), (seconds - 600).toString(), (seconds + 600).toString()),
            )?.let { return it }
        }
        queryFirstMedia(
            context,
            "${MediaStore.MediaColumns.SIZE} = ?",
            arrayOf(fileSize.toString()),
        )?.let { return it }
    }

    if (name != null) {
        queryFirstMedia(
            context,
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
            arrayOf(name),
        )?.let { return it }
    }

    return null
}

/**
 * 只查图片和视频：相册里的文件不走 `MediaStore.Files` 之外的任何集合，加上这个条件
 * 才不会因为大小相同撞上某个无关的文档。
 */
private fun queryFirstMedia(
    context: Context,
    selection: String,
    selectionArgs: Array<String>,
): Pair<Uri, String?>? {
    val collection = MediaStore.Files.getContentUri("external")
    val projection = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.MIME_TYPE)
    val where = "($selection) AND (${MediaStore.MediaColumns.MIME_TYPE} LIKE ? OR ${MediaStore.MediaColumns.MIME_TYPE} LIKE ?)"
    val whereArgs = selectionArgs + arrayOf("image/%", "video/%")

    val cursor = try {
        context.contentResolver.query(
            collection,
            projection,
            where,
            whereArgs,
            "${MediaStore.MediaColumns.DATE_ADDED} DESC",
        )
    } catch (_: Exception) {
        null
    } ?: return null

    return cursor.use {
        if (!it.moveToFirst()) {
            return@use null
        }
        val id = it.getLong(0)
        val mimeType = it.getString(1)
        val base = baseCollectionFor(mimeType) ?: return@use null
        ContentUris.withAppendedId(base, id) to mimeType
    }
}

private fun baseCollectionFor(mimeType: String?): Uri? {
    return when {
        mimeType == null -> null
        mimeType.startsWith("image/") -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        mimeType.startsWith("video/") -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        else -> null
    }
}

/**
 * 真去开：一个候选直接开，多个候选尊重系统默认，没有默认才弹选择器。
 */
private fun launch(context: Context, intent: Intent, candidates: List<ActivityInfo>): OpenFileStatus {
    return try {
        if (candidates.size == 1) {
            context.startActivity(explicitIntent(intent, candidates[0]))
        } else {
            val default = defaultActivity(context, intent, candidates)
            if (default != null) {
                context.startActivity(explicitIntent(intent, default))
            } else {
                val chooser = Intent.createChooser(explicitIntent(intent, candidates[0]), null)
                // EXTRA_INITIAL_INTENTS 必须按 Parcelable[] 存，写成 Serializable 的话
                // 系统读不出来，选择器里就只剩第一个应用了。
                val others: Array<Parcelable> = candidates.drop(1)
                    .map { explicitIntent(intent, it) as Parcelable }
                    .toTypedArray()
                chooser.putExtra(Intent.EXTRA_INITIAL_INTENTS, others)
                context.startActivity(chooser)
            }
        }
        OpenFileStatus.OPENED
    } catch (_: ActivityNotFoundException) {
        OpenFileStatus.NO_APP
    } catch (_: Exception) {
        OpenFileStatus.FAILED
    }
}

/**
 * 系统当前会给这个 intent 用的默认应用 —— 但只有它本身是「能打开的应用」才算数：
 * 解析结果可能是系统的 `ResolverActivity`（选择器占位），那不算默认。
 */
@Suppress("DEPRECATION")
private fun defaultActivity(
    context: Context,
    intent: Intent,
    candidates: List<ActivityInfo>,
): ActivityInfo? {
    val resolved = try {
        context.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo
    } catch (_: Exception) {
        null
    } ?: return null
    return candidates.firstOrNull { it.packageName == resolved.packageName && it.name == resolved.name }
}

@Suppress("DEPRECATION")
private fun queryActivities(context: Context, intent: Intent): List<ActivityInfo> {
    return try {
        context.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            .mapNotNull { it.activityInfo }
            .filter { it.packageName != context.packageName }
    } catch (_: Exception) {
        emptyList()
    }
}

private fun explicitIntent(base: Intent, info: ActivityInfo): Intent {
    return Intent(base).setClassName(info.packageName, info.name)
}

/**
 * 打开器的 MIME。优先用调用方给的（相册回查时能从 MediaStore 拿到准确值），
 * 其次问 `ContentResolver`，最后才按扩展名猜。
 */
private fun resolveMimeType(context: Context, uri: Uri, hint: String?): String {
    if (!hint.isNullOrBlank()) {
        return hint
    }
    val fromResolver = try {
        context.contentResolver.getType(uri)
    } catch (_: Exception) {
        null
    }
    if (!fromResolver.isNullOrBlank()) {
        return fromResolver
    }
    return mimeTypeFromName(uri.lastPathSegment ?: uri.toString())
}

/**
 * 文件管理器 / 文档 UI 的包名特征。
 *
 * 不用精确包名表：各 ROM 的命名五花八门（`com.vivo.filemanager`、
 * `com.miui.fileexplorer`、`com.huawei.hidisk`、`com.google.android.apps.nbu.files`
 * …），按特征词匹配比维护一张永远不全的清单可靠。**不收录泛化的 `files`**，
 * 那会误伤名字里恰好带它的看图应用。
 */
private val fileManagerHints = listOf(
    "documentsui",
    "filemanager",
    "fileexplorer",
    "filebrowser",
    "files.manager",
    "hidisk",
    "nbu.files",
)

private fun isFileManager(packageName: String): Boolean {
    val pkg = packageName.lowercase(Locale.ROOT)
    return fileManagerHints.any { pkg.contains(it) }
}

private fun mimeTypeFromName(fileName: String): String {
    val fileExt = fileName.substring(fileName.lastIndexOf(".") + 1).lowercase(Locale.ROOT)
    return when (fileExt) {
        "3gp" -> "video/3gpp"
        "torrent" -> "application/x-bittorrent"
        "kml" -> "application/vnd.google-earth.kml+xml"
        "gpx" -> "application/gpx+xml"
        "apk" -> "application/vnd.android.package-archive"
        "asf" -> "video/x-ms-asf"
        "avi" -> "video/x-msvideo"
        "bin", "class", "exe" -> "application/octet-stream"
        "bmp" -> "image/bmp"
        "c", "conf", "cpp", "h", "java", "log", "prop", "rc", "sh", "txt", "xml" -> "text/plain"
        "doc" -> "application/msword"
        "docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        "xls", "csv" -> "application/vnd.ms-excel"
        "xlsx" -> "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        "gif" -> "image/gif"
        "gtar" -> "application/x-gtar"
        "gz" -> "application/x-gzip"
        "htm", "html" -> "text/html"
        "jar" -> "application/java-archive"
        "jpeg", "jpg" -> "image/jpeg"
        "js" -> "application/x-javascript"
        "m3u" -> "audio/x-mpegurl"
        "m4a", "m4b", "m4p" -> "audio/mp4a-latm"
        "m4u" -> "video/vnd.mpegurl"
        "m4v" -> "video/x-m4v"
        "mov" -> "video/quicktime"
        "mp2", "mp3" -> "audio/x-mpeg"
        "mp4", "mpg4" -> "video/mp4"
        "mpc" -> "application/vnd.mpohun.certificate"
        "mpe", "mpeg", "mpg" -> "video/mpeg"
        "mpga" -> "audio/mpeg"
        "msg" -> "application/vnd.ms-outlook"
        "ogg" -> "audio/ogg"
        "pdf" -> "application/pdf"
        "png" -> "image/png"
        "pps", "ppt" -> "application/vnd.ms-powerpoint"
        "pptx" -> "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        "rmvb" -> "audio/x-pn-realaudio"
        "rtf" -> "application/rtf"
        "tar" -> "application/x-tar"
        "tgz" -> "application/x-compressed"
        "wav" -> "audio/x-wav"
        "webp" -> "image/webp"
        "wma" -> "audio/x-ms-wma"
        "wmv" -> "audio/x-ms-wmv"
        "wps" -> "application/vnd.ms-works"
        "z" -> "application/x-compress"
        "zip" -> "application/x-zip-compressed"
        // 猜不出来就交给系统按通配处理。**不要**用 directory —— 那是文档 UI 的入口，
        // 会把「打开文件」变成「打开文件管理器」。
        else -> "*/*"
    }
}
