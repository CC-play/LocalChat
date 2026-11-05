package org.localsend.localsend_app

import android.annotation.SuppressLint
import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipboardManager
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone


private const val CHANNEL = "org.localsend.localsend_app/localsend"
private const val REQUEST_CODE_PICK_DIRECTORY = 1
private const val REQUEST_CODE_PICK_DIRECTORY_PATH = 2
private const val REQUEST_CODE_PICK_FILE = 3
private const val REQUEST_CODE_LOCAL_NETWORK = 4

// Not available as a constant in compileSdk 36.
private const val PERMISSION_ACCESS_LOCAL_NETWORK = "android.permission.ACCESS_LOCAL_NETWORK"
private const val API_LEVEL_ANDROID_17 = 37

// [FORK] 一次粘贴近似「全选相册」时，读字节会把内存打爆，这里给个上限。
private const val MAX_CLIPBOARD_FILES = 20
private const val MAX_CLIPBOARD_FILE_BYTES = 256L * 1024 * 1024

// [FORK] 聊天消息通知。
//
// 与传输进度用的前台服务通知是两套东西：那个由 flutter_foreground_task 以 LOW 优先级
// 常驻、静音、不能弹出；消息提醒必须能横幅 + 响铃 + 亮屏，所以这里单独建一个
// IMPORTANCE_HIGH 的渠道，用系统通知而不是前台服务。
private const val CHAT_CHANNEL_ID = "localchat_messages"
private const val EXTRA_CHAT_PEER = "localchat.chatPeer"

/// 通知 id 从 1000 起：1 被前台服务占用，两者不能互相覆盖。
private const val CHAT_NOTIFICATION_ID_BASE = 1000

/// 合并同一个对端的多条消息时，通知里最多列这么多行。
private const val MAX_INBOX_LINES = 6

/// 渠道名只在第一次创建时生效；Dart 侧会传当前语言的标题，这里只是兜底。
private const val DEFAULT_CHAT_CHANNEL_NAME = "Messages"

class MainActivity : FlutterActivity() {
    private var pendingResult: MethodChannel.Result? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    /// [FORK] 发通知与接收点击都走它，所以要在 configureFlutterEngine 里留一份引用。
    private var methodChannel: MethodChannel? = null

    /// [FORK] 用户点了通知、但 Dart 侧还没准备好接收时，先把对端指纹存这里。
    private val pendingChatTaps = mutableListOf<String>()
    private var chatTapReady = false

    /// [FORK] 每个对端最近几条消息，用于合并成一封通知。
    /// key 是对端指纹，顺序保持插入顺序，方便滚动展示最近几条。
    private val chatHistory = LinkedHashMap<String, MutableList<String>>()

    /// [FORK] 每个对端本次未读数。点开通知（或其会话被打开）后由 Dart 侧清零。
    private val chatUnread = mutableMapOf<String, Int>()

    /// share_handler drops share intents arriving via onNewIntent while the Dart side
    /// is not subscribed to its media stream yet, which happens when this singleTask
    /// activity is relaunched into an existing task while the app is still starting.
    /// Hold such intents back until Dart reports readiness ("shareIntentReady"), then
    /// replay them through the regular plugin path.
    private val pendingShareIntents = mutableListOf<Intent>()
    private var shareIntentReady = false

    override fun onNewIntent(intent: Intent) {
        // [FORK] 点通知进来时 Activity 是 singleTask，不会重建，只能在这里接。
        handleChatTapIntent(intent)
        if (!shareIntentReady && (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE)) {
            pendingShareIntents.add(intent)
            return
        }
        super.onNewIntent(intent)
    }

    /// [FORK] 把通知里的对端指纹交给 Dart；Dart 还没就绪就先攒着。
    private fun handleChatTapIntent(intent: Intent?) {
        val peer = intent?.getStringExtra(EXTRA_CHAT_PEER) ?: return
        // 同一个 Intent 可能被重复消费（Activity 重建、Dart 侧又来拉一次），
        // 消费后立刻清掉，免得同一条通知打开两次会话页。
        intent.removeExtra(EXTRA_CHAT_PEER)

        // 点了通知就是想看这个会话，未读累计和通知本身都到此为止。
        clearChatNotification(peer)

        if (chatTapReady) {
            methodChannel?.invokeMethod("onChatNotificationTap", peer)
        } else {
            pendingChatTaps.add(peer)
        }
    }

    private fun onShareIntentReady() {
        shareIntentReady = true
        val pending = pendingShareIntents.toList()
        pendingShareIntents.clear()
        for (intent in pending) {
            super.onNewIntent(intent)
        }
    }

    // Overriding the static methods we need from the Java class, as described
    // in the documentation of `FlutterActivity.NewEngineIntentBuilder`
    companion object {
        fun withNewEngine(): NewEngineIntentBuilder {
            return NewEngineIntentBuilder(MainActivity::class.java)
        }

        fun createDefaultIntent(launchContext: Context): Intent {
            return withNewEngine().build(launchContext)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        // [FORK] 通知点击要能主动回调 Dart，所以得留着这个 channel。
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDirectory" -> {
                    pendingResult = result
                    openDirectoryPicker(onlyPath = false)
                }

                "pickFiles" -> {
                    pendingResult = result
                    openFilePicker()
                }

                "pickDirectoryPath" -> {
                    pendingResult = result
                    openDirectoryPicker(onlyPath = true)
                }

                "createDirectory" -> handleCreateDirectory(call, result)

                "getFileDescriptor" -> handleGetFileDescriptor(call, result)

                "createFile" -> handleCreateFile(call, result)

                "openFileForWriting" -> handleOpenFileForWriting(call, result)

                "openContentUri" -> {
                    openUri(context, call.argument<String>("uri")!!)
                    result.success(null)
                }

                "openGallery" -> {
                    openGallery()
                    result.success(null)
                }

                "shareIntentReady" -> {
                    onShareIntentReady()
                    result.success(null)
                }

                "isAnimationsEnabled" -> {
                    result.success(isAnimationsEnabled())
                }

                "getClipboardImage" -> {
                    result.success(readClipboardImage())
                }

                "getClipboardFiles" -> {
                    result.success(readClipboardFiles())
                }

                "getDownloadsDirectory" -> {
                    result.success(getDownloadsDirectory())
                }

                "requestLocalNetworkPermission" -> {
                    if (hasLocalNetworkPermission()) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        requestPermissions(arrayOf(PERMISSION_ACCESS_LOCAL_NETWORK), REQUEST_CODE_LOCAL_NETWORK)
                    }
                }

                // [FORK] 聊天消息通知
                "showChatNotification" -> handleShowChatNotification(call, result)

                "clearChatNotification" -> {
                    val peer = call.argument<String>("peerFingerprint")
                    if (peer.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "Missing peerFingerprint", null)
                    } else {
                        clearChatNotification(peer)
                        result.success(null)
                    }
                }

                "getChatNotificationStatus" -> result.success(chatNotificationStatus())

                "openChatNotificationSettings" -> {
                    openChatNotificationSettings(call.argument<String>("channelName"))
                    result.success(null)
                }

                "chatNotificationsReady" -> {
                    // Dart 侧装好了回调，可以把这段时间攒下的点击补给它可以。
                    chatTapReady = true
                    // 冷启动：Activity 是被通知的 PendingIntent 拉起来的，
                    // 那次 Intent 从没走过 onNewIntent。
                    handleChatTapIntent(intent)
                    val queued = pendingChatTaps.toList()
                    pendingChatTaps.clear()
                    queued.forEach { methodChannel?.invokeMethod("onChatNotificationTap", it) }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    /// [FORK] 发一条聊天消息通知。
    ///
    /// 同一个对端共用一封通知（同一个 id）：后续消息追加进列表并累加未读数，
    /// 否则对方连发几句就会把通知栏刷满，也没法看出是同一个人的消息。
    @SuppressLint("MissingPermission")
    private fun handleShowChatNotification(call: MethodCall, result: MethodChannel.Result) {
        val peer = call.argument<String>("peerFingerprint")
        if (peer.isNullOrEmpty()) {
            result.error("INVALID_ARGUMENT", "Missing peerFingerprint", null)
            return
        }

        val channelName = call.argument<String>("channelName")?.takeIf { it.isNotBlank() } ?: DEFAULT_CHAT_CHANNEL_NAME
        val title = call.argument<String>("title")?.takeIf { it.isNotBlank() } ?: "LocalChat"
        val body = call.argument<String>("body") ?: ""

        ensureChatChannel(channelName)

        val lines = chatHistory.getOrPut(peer) { mutableListOf() }
        lines.add(body)
        while (lines.size > MAX_INBOX_LINES) {
            lines.removeAt(0)
        }
        val unread = (chatUnread[peer] ?: 0) + 1
        chatUnread[peer] = unread

        // 权限被收回 / 整个 App 的通知被关掉时直接放过：notify 在 Android 13+ 会抛
        // SecurityException，没必要让它炸在 Dart 侧。
        if (!NotificationManagerCompat.from(this).areNotificationsEnabled()) {
            result.success(false)
            return
        }

        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_CHAT_PEER, peer)
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            notificationIdOf(peer),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val style = NotificationCompat.InboxStyle()
        lines.forEach { style.addLine(it) }
        if (unread > lines.size) {
            style.setSummaryText("+${unread - lines.size}")
        }

        val notification = NotificationCompat.Builder(this, CHAT_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_chat)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(style)
            .setNumber(unread)
            .setWhen(System.currentTimeMillis())
            .setShowWhen(true)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .build()

        try {
            NotificationManagerCompat.from(this).notify(notificationIdOf(peer), notification)
            result.success(true)
        } catch (e: SecurityException) {
            result.success(false)
        }
    }

    /// [FORK] 会话被打开（或消息已读）时撤掉这个对端的通知，并清零本地的未读累计。
    private fun clearChatNotification(peer: String) {
        chatUnread.remove(peer)
        chatHistory.remove(peer)
        NotificationManagerCompat.from(this).cancel(notificationIdOf(peer))
    }

    /// 每个对端一个稳定的通知 id。1 被传输前台服务占用，所以从 1000 起。
    private fun notificationIdOf(peer: String): Int {
        val slot = (peer.hashCode().toLong() and 0x7fffffff).toInt() % 10000
        return CHAT_NOTIFICATION_ID_BASE + slot
    }

    /// 通知渠道只会在第一次创建时被读取，之后改名 / 改重要性都由用户在系统里决定。
    private fun ensureChatChannel(channelName: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHAT_CHANNEL_ID) != null) {
            return
        }
        val channel = NotificationChannel(CHAT_CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_HIGH).apply {
            enableLights(true)
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    /// [FORK] 通知现在到底能不能到用户眼前。
    ///
    /// 三个条件缺一不可：系统给了权限、App 的通知没被关、渠道重要性不是 NONE。
    /// vivo 这类 ROM 经常把整个 App 的通知关掉，Dart 侧据此显示提示条。
    private fun chatNotificationStatus(): Map<String, Any> {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val enabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
        val permissionGranted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

        var channelExists = false
        var channelImportance = -1000 // IMPORTANCE_UNSPECIFIED
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = manager.getNotificationChannel(CHAT_CHANNEL_ID)
            channelExists = channel != null
            if (channel != null) {
                channelImportance = channel.importance
            }
        }

        return mapOf(
            "enabled" to enabled,
            "permissionGranted" to permissionGranted,
            "channelExists" to channelExists,
            "channelImportance" to channelImportance,
        )
    }

    /// [FORK] 跳到本 App 的消息通知渠道设置页，用户在那里能打开被关掉的通知。
    private fun openChatNotificationSettings(channelName: String?) {
        // 渠道没建过时渠道设置页打不开，先建一个空的。
        ensureChatChannel(channelName?.takeIf { it.isNotBlank() } ?: DEFAULT_CHAT_CHANNEL_NAME)

        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                putExtra(Settings.EXTRA_CHANNEL_ID, CHAT_CHANNEL_ID)
            }
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", packageName, null)
            }
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            startActivity(intent)
        } catch (e: Exception) {
            // 个别 ROM 没有渠道设置页，退回应用详情，用户仍能从那里进通知管理。
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                    .apply { data = Uri.fromParts("package", packageName, null) }
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /// Android 17+ gates local network access behind a runtime permission; older versions grant it implicitly.
    private fun hasLocalNetworkPermission(): Boolean {
        if (Build.VERSION.SDK_INT < API_LEVEL_ANDROID_17) {
            return true
        }
        return checkSelfPermission(PERMISSION_ACCESS_LOCAL_NETWORK) == PackageManager.PERMISSION_GRANTED
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CODE_LOCAL_NETWORK) {
            pendingPermissionResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingPermissionResult = null
        }
    }

    /// Absolute path of the shared "Download" directory (usually /storage/emulated/0/Download).
    @Suppress("DEPRECATION")
    private fun getDownloadsDirectory(): String {
        return Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
    }

    private fun isAnimationsEnabled() : Boolean {
        return Settings.Global.getFloat(this.getContentResolver(),
            Settings.Global.ANIMATOR_DURATION_SCALE, 1.0f) != 0.0f;
    }

    /// [FORK] 读取系统剪贴板里的图片，供聊天输入框「粘贴图片」使用。
    ///
    /// Flutter 的 Clipboard.getData 只支持纯文本，图片只能走原生。
    /// 返回 null 表示剪贴板里没有图片，Dart 侧据此退回普通文本粘贴。
    private fun readClipboardImage(): Map<String, Any>? {
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return null
        val clip = manager.primaryClip ?: return null
        if (clip.itemCount == 0) return null

        // 只有「复制了一张图」的情况才带 URI；纯文本复制没有。
        val uri = clip.getItemAt(0).uri ?: return null
        val mime = contentResolver.getType(uri) ?: return null
        if (!mime.startsWith("image/")) return null

        val bytes = try {
            contentResolver.openInputStream(uri)?.use { it.readBytes() }
        } catch (e: Exception) {
            null
        } ?: return null
        if (bytes.isEmpty()) return null

        return mapOf("bytes" to bytes, "mime" to mime)
    }

    /// [FORK] 读取剪贴板里的文件条目（文件管理器 / 相册里「复制」放的是 content URI）。
    ///
    /// 和 Windows 的 CF_HDROP 对应，但 Android 只有 URI 没有路径，
    /// 所以这里直接读字节，交给 Dart 侧落到缓存目录。
    private fun readClipboardFiles(): List<Map<String, Any>> {
        val manager = getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return emptyList()
        val clip = manager.primaryClip ?: return emptyList()
        if (clip.itemCount == 0) return emptyList()

        val entries = mutableListOf<Map<String, Any>>()
        for (index in 0 until minOf(clip.itemCount, MAX_CLIPBOARD_FILES)) {
            // 纯文本复制没有 URI，直接跳过（Dart 侧会退回普通文本粘贴）。
            val uri = clip.getItemAt(index).uri ?: continue
            val mime = contentResolver.getType(uri) ?: continue
            if (isTooLarge(uri)) continue

            val bytes = try {
                contentResolver.openInputStream(uri)?.use { it.readBytes() }
            } catch (e: Exception) {
                null
            } ?: continue
            if (bytes.isEmpty()) continue

            entries.add(
                mapOf<String, Any>(
                    "bytes" to bytes,
                    "mime" to mime,
                    "name" to (queryDisplayName(uri) ?: uri.lastPathSegment ?: "clipboard-$index"),
                ),
            )
        }
        return entries
    }

    private fun isTooLarge(uri: Uri): Boolean {
        val size = try {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
        } catch (e: Exception) {
            null
        } ?: return false
        return size > MAX_CLIPBOARD_FILE_BYTES
    }

    private fun queryDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun handleGetFileDescriptor(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "r")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            // Ownership of the detached descriptor is transferred to the caller. It must be
            // closed by Rust (or whichever native consumer receives it) after use.
            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    /// Creates a new file inside a SAF directory and opens it for writing.
    ///
    /// Returns the URI of the created document (Android may rename the file on
    /// collisions) and an owned writable file descriptor. The descriptor must be
    /// closed by the native consumer it is passed to.
    private fun handleCreateFile(call: MethodCall, result: MethodChannel.Result) {
        val parentUriString = call.argument<String>("parentUri")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        if (parentUriString == null || fileName == null) {
            result.error("INVALID_ARGUMENT", "Missing parentUri or fileName", null)
            return
        }

        try {
            val parentUri = Uri.parse(parentUriString)

            // A pure tree URI (content://…/tree/X) must be converted to its
            // document form before it can be used as a parent document.
            val segments = parentUri.pathSegments
            val parentDocumentUri = if (segments.size == 2 && segments[0] == "tree") {
                DocumentsContract.buildDocumentUriUsingTree(
                    parentUri,
                    DocumentsContract.getTreeDocumentId(parentUri)
                )
            } else {
                parentUri
            }

            val documentUri =
                DocumentsContract.createDocument(contentResolver, parentDocumentUri, mimeType, fileName)
            if (documentUri == null) {
                result.error("CREATE_FAILED", "Could not create $fileName in $parentUriString", null)
                return
            }

            // "wt" is write + truncate: the document is new, unless the provider
            // handed out an existing one instead of creating a second document.
            val parcelFileDescriptor = contentResolver.openFileDescriptor(documentUri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(
                    mapOf(
                        "uri" to documentUri.toString(),
                        "fd" to it.detachFd(),
                    )
                )
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("CREATE_FAILED", e.message ?: "Failed to create file", null)
        }
    }

    /// Opens an existing document created by [handleCreateFile] for writing,
    /// discarding its current content.
    ///
    /// Used to write a file again after a failed attempt, so that it keeps its
    /// name instead of being created a second time under a numbered one.
    ///
    /// Returns an owned writable file descriptor. It stays open after this call
    /// and must be closed by the native consumer it is passed to.
    private fun handleOpenFileForWriting(call: MethodCall, result: MethodChannel.Result) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("INVALID_ARGUMENT", "Missing content URI", null)
            return
        }

        val uri = Uri.parse(uriString)
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            result.error("INVALID_ARGUMENT", "Expected a content:// URI", null)
            return
        }

        try {
            // "wt" is write + truncate. A document provider may ignore the
            // truncation, so the writer additionally shortens the file itself.
            val parcelFileDescriptor = contentResolver.openFileDescriptor(uri, "wt")
            if (parcelFileDescriptor == null) {
                result.error("OPEN_FAILED", "The content provider did not return a file descriptor", null)
                return
            }

            parcelFileDescriptor.use {
                result.success(it.detachFd())
            }
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message ?: "Permission denied for content URI", null)
        } catch (e: Exception) {
            result.error("OPEN_FAILED", e.message ?: "Failed to open content URI", null)
        }
    }

    private fun openDirectoryPicker(onlyPath: Boolean) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        startActivityForResult(
            intent,
            if (onlyPath) REQUEST_CODE_PICK_DIRECTORY_PATH else REQUEST_CODE_PICK_DIRECTORY
        )
    }

    private fun openFilePicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            putExtra("multi-pick", true)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_CODE_PICK_FILE)
    }

    @SuppressLint("WrongConstant")
    @Override
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode == Activity.RESULT_CANCELED) {
            pendingResult?.error("CANCELED", "Canceled", null)
            pendingResult = null
            return
        }

        if (resultCode != Activity.RESULT_OK || data == null) {
            pendingResult?.error("Error $resultCode", "Failed to access directory or file", null)
            pendingResult = null
            return
        }

        when (requestCode) {
            REQUEST_CODE_PICK_DIRECTORY -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)

                    val files = mutableListOf<FileInfo>()
                    listFiles(uri, files)
                    val resultData = PickDirectoryResult(uri.toString(), files)
                    pendingResult?.success(resultData.toMap())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_DIRECTORY_PATH -> {
                val uri: Uri? = data.data
                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (uri != null) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    pendingResult?.success(uri.toString())
                    pendingResult = null
                } else {
                    pendingResult?.error("Error", "Failed to access directory", null)
                    pendingResult = null
                }
            }

            REQUEST_CODE_PICK_FILE -> {
                val uriList: List<Uri> = when {
                    data.clipData != null -> {
                        val clipData = data.clipData
                        val uris = mutableListOf<Uri>()
                        for (i in 0 until clipData!!.itemCount) {
                            uris.add(clipData.getItemAt(i).uri)
                        }
                        uris
                    }

                    data.data != null -> listOf(data.data!!)
                    else -> {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                }

                val takeFlags: Int =
                    data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)

                val resultList = mutableListOf<FileInfo>()
                for (uri in uriList) {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                    val documentFile = FastDocumentFile.fromDocumentUri(this, uri)
                    if (documentFile == null) {
                        pendingResult?.error("Error", "Failed to access file", null)
                        return
                    }
                    resultList.add(
                        FileInfo(
                            name = documentFile.name,
                            size = documentFile.size,
                            uri = uri.toString(),
                            lastModified = documentFile.lastModified?.toRfc3339(),
                        )
                    )
                }

                pendingResult?.success(resultList.map { it.toMap() })
                pendingResult = null
            }
        }
    }

    private fun listFiles(uri: Uri, files: MutableList<FileInfo>) {
        val pickedDir: FastDocumentFile = FastDocumentFile.fromTreeUri(this, uri)

        for (file in pickedDir.listFiles()) {
            if (file.isDirectory) {
                // Recursive call
                listFiles(file.uri, files)
            } else if (file.isFile) {
                files.add(
                    FileInfo(
                        name = file.name,
                        size = file.size,
                        uri = file.uri.toString(),
                        lastModified = file.lastModified?.toRfc3339(),
                    ),
                )
            }
        }
    }

    @SuppressLint("WrongConstant")
    private fun handleCreateDirectory(call: MethodCall, result: MethodChannel.Result) {
        val documentUri = Uri.parse(call.argument<String>("documentUri")!!)
        val directoryName = call.argument<String>("directoryName")!!

        if (folderExists(documentUri, directoryName)) {
            result.success(null)
            return
        }

        DocumentsContract.createDocument(
            context.contentResolver, documentUri, DocumentsContract.Document.MIME_TYPE_DIR,
            directoryName
        )

        result.success(null)
    }

    private fun folderExists(documentUri: Uri, folderName: String): Boolean {
        var cursor: Cursor? = null
        try {
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(documentUri, DocumentsContract.getDocumentId(documentUri))
            cursor = contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE
                ),
                null,
                null,
                null,
            )

            if (cursor != null) {
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(0)
                    val mimeType = cursor.getString(1)

                    if (folderName == displayName && DocumentsContract.Document.MIME_TYPE_DIR == mimeType) {
                        return true
                    }
                }
            }
        } finally {
            cursor?.close()
        }
        return false
    }

    private fun openGallery() {
        val intent = Intent()
        intent.action = Intent.ACTION_VIEW
        intent.type = "image/*"
        startActivity(intent)
    }
}

data class PickDirectoryResult(
    val directoryUri: String,
    val files: List<FileInfo>,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "directoryUri" to directoryUri,
            "files" to files.map { it.toMap() }
        )
    }
}

data class FileInfo(
    val name: String,
    val size: Long,
    val uri: String,
    val lastModified: String?
) {
    fun toMap(): Map<String, Any?> {
        return mapOf(
            "name" to name,
            "size" to size,
            "uri" to uri,
            "lastModified" to lastModified
        )
    }
}

/// Formats milliseconds since epoch as an RFC 3339 string in UTC.
private fun Long.toRfc3339(): String {
    val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    format.timeZone = TimeZone.getTimeZone("UTC")
    return format.format(Date(this))
}
