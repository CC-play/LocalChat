# 模块卡：会话 / 聊天（fork 自建，无上游参照）

## 职责

把 LocalSend 的「收发事件」投影成微信式会话视图：按对端设备聚合、双向记录、按最近活动排序。**不参与任何传输逻辑**——它只读事件，写自己的存储，失败时静默降级。

## 数据流

```
接收：Rust core ──ServerEventV2──> ReceiveController.onFileUpload / 文本分支
                                        │
                                        ├─> ReceiveHistoryProvider（上游，全局 30 条）
                                        └─> conversation_recorder.recordReceived*
                                                    │
发送：send_provider 事件流 ──Started/Finished/Failed──┤
      conversation_sender.sendTextMessage ──────────┤
                                                    ▼
                                    conversationProvider（Redux）
                                     ├─ AppendChatMessageAction（唯一建会话入口）
                                     ├─ UpdateChatMessageAction
                                     └─ setConversations → SharedPreferences('ls_conversations')
                                                    │
                                                    ▼
                              ConversationsPage（列表） / ConversationPage（详情）
```

## 文件

| 文件 | 角色 |
|---|---|
| `app/lib/model/conversation/conversation.dart` | `Conversation` / `ChatMessage` + 手写 JSON（刻意不用 `dart_mappable`，避免 build_runner 耦合）+ 两个上限常量 |
| `app/lib/provider/conversation_provider.dart` | Redux 状态 + 5 个 action + `unreadConversationCountProvider` |
| `app/lib/util/conversation/conversation_recorder.dart` | 接收侧写入口，`peerKeyOf()` 决定会话主键 |
| `app/lib/util/conversation/conversation_sender.dart` | 发送侧：`resolveConversationTarget` / `sendTextMessage` / `pickConversationFiles` + `deliverFiles`（含 2 分钟离线重试） |
| `app/lib/pages/conversations_page.dart` | 列表 + 空态 + 全清 + 长按删除 |
| `app/lib/pages/conversation_page.dart` | 详情 + 底部输入栏（[附件][输入][发送]）+ 文字选区/右键「复制」菜单 + Ctrl+V 粘贴（文件 / 图片 / 文本） |
| `app/lib/util/conversation/clipboard_image.dart` | 剪贴板文件与图片读取（原生通道）+ 落缓存目录 + 文件名消毒 |
| `app/windows/runner/clipboard_image_win.cpp` | WIC：剪贴板 PNG / JPEG / DIB → PNG 字节（不依赖 Flutter，可单独编译验证） |
| `app/windows/runner/clipboard_files_win.cpp` | `CF_HDROP` → 路径列表（拖动文件到剪贴板时只有这个格式） |
| `app/windows/runner/clipboard_ext.cpp` | Windows 侧方法通道 `getClipboardImage` / `getClipboardFiles` |
| `app/android/.../MainActivity.kt` | 同一个通道的 Android 实现（读 `ClipData` 的 content URI） |
| `app/lib/widget/chat/message_bubble.dart` | 文本气泡、头像、固定发出色 |
| `app/lib/widget/chat/file_message_card.dart` | 文件气泡 |
| `app/lib/widget/chat/top_toast.dart` | 顶部 Toast（替代 SnackBar） |

## 卡片生成条件

一张卡片 = 一个 `Conversation` 对象。**没有"新建空会话"入口**，卡片只能是「消息被成功追加」的副产物。三个前提缺一不可（`conversation_provider.dart:48-56`）：

1. 走 `AppendChatMessageAction`；
2. `peerFingerprint` 非空（`peerKeyOf` 优先设备指纹，退化 `alias:<别名>`）；
3. 该 `message.id` 尚未存在于该会话（重复即只更新，不新增）。

五个实际触发点：收到文本（自动接收）、收到文件且落盘成功（`error == null && desiredName != null`）、自己发文本（先写"发送中"）、自己发文件（`deliverFiles` **在投递前**就写好"发送中"，不依赖 Started 事件）、Started 丢失时 `markSentFile` 兜底补插。

**推论**：发送失败也会留卡片（末条 `failed`，列表显示红点）；接收被拒/接收失败不留卡片；从普通「发送」Tab 传文件也会刷新卡片（钩子在全局上传事件里，不区分入口）。

## 离线重试（2 分钟窗口）

LocalSend **没有**可调的「发送超时」：对端 App 没开时 prepare-upload 会被系统 TCP 栈秒级拒绝（值不可配置）。所以「给对方时间拿起手机」只能靠重试。

- `textSendRetryWindow = 2min`，`_retryInterval = 2s`；全程复用同一个 `sessionId`，避免 `fileTransferProvider` 里堆积一次性状态。
- 只重试 `unreachable` / `unknown`；`peerDeclined` / `peerBusy` 是明确答复，立即失败。
- **文件只在握手阶段重试**：一旦 `session.files` 里有 `token != null`，说明已进入流式上传，重来会在对端留下半截文件 → 停止重试，后续交给 upload 事件。
- 跨重试复用 `checksumCache`（`send_provider.startSession` 的 `[FORK]` 参数），否则两分钟内会把几百 MB 文件反复读盘哈希。
- 投递全程在后台：页面不 `await`，输入框不锁；结果由气泡状态（转圈 / 红色感叹号）和顶部 Toast 表达。

## 失败重发（点红色感叹号）

- 入口：`MessageBubble.onRetry`。感叹号是 `InkResponse`（带 `Tooltip`「点击重发」），只在**发出方向 + `failed`** 时挂回调。
- 状态回退用 `MarkChatMessagePendingAction`：只接受「发出方向且已失败」的消息，改回 `pending` 并清掉 `errorMessage`。清空靠 `ChatMessage.copyWith(clearError: true)`——`copyWith` 原本是 `errorMessage ?? this.errorMessage`，传 null 无法置空。
- 重发**复用原 message id**：`sendTextMessage(messageIdOverride:)` / `deliverFiles(messageIds:)` 在拿到 id 时跳过 `recordSentFileStart`，所以不会多出气泡；结局仍由 `markSentFile` 和 upload 事件写回同一条，消息也留在历史位置不跳到底部。
- 文件重发前 `File(path).existsSync()`：粘贴的图片落在缓存目录，可能已被系统清理 → 返回 `SendFailure.fileMissing`（`t.conversation.fileMissing`「原文件已经不在了」），并把气泡标回失败。
- 页面用 `_retrying` 集合挡连点：重发期间点同一颗感叹号不再响应（气泡此时也已经是「发送中」）。

## 超时与看门狗

「气泡一直转圈」有两个互不相干的根因，修复方式也不同。

**1. 握手阶段可能永久挂起（不是窗口太短，是窗口根本不起作用）。**
`http_provider.dart` 创建 HTTP 客户端时只传 `privateKey/cert/expectedFingerprint`，Rust 的 `create_reqwest_client` 在 `timeout == None` 时**不给 reqwest 设任何超时**。于是 `prepare-upload` 对着一个「TCP 能连上但不应答」的地址会永久挂起。而重试循环里的 `deadline` 判断写在 `await` **之后**，永远执行不到 —— 2 分钟窗口形同虚设。

- 修法：把整段重试循环抽成 `_sendTextWithRetry` / `_deliverWithRetry`，外层 `.timeout(textSendRetryWindow + _timeoutGrace)`（`_timeoutGrace = 10s`，避免抢在「最后一次尝试正常结束」之前判超时）。
- `finally` 里的 `closeSession` 会顺带取消还挂着的 prepare-upload（cancel token），超时后不会留下仍在跑的请求。
- **不能简单地给 prepare-upload 加短超时**：接收端在「需要确认」模式下会一直 hold 住这个请求等用户点接受/拒绝，短超时会把正常场景误判成失败。所以用「总窗口」而不是「单次请求超时」。

**2. 上传阶段原本完全没有超时。**
`deliverFiles` 一旦 `enteredTransfer` 就 `return null`，终态全靠 upload 事件。对端在传输中途消失、TCP 半开，事件再也不来，气泡永远转圈。

- 修法：进入上传时 `unawaited(_watchStalledUploads(...))`。每 10 秒巡检一次，超过 `uploadStallTimeout = 60s` 没有任何进度事件 → `closeSession` + 把仍 pending 的气泡标失败（可点重发）。
- 活跃度取自 `chatTransferProvider.lastProgressOf(id)`，而**不是**气泡上的进度值：看门狗必须在「用户没打开会话页、没有气泡登记」时也能判断。所以 `report()` 里时间戳是**无条件**记录的，进度 notifier 才是按需创建。少了这条，后台正常传输的大文件会被误判成停滞。
- **按整批文件判断活跃度，不按单文件**：多文件是顺序上传的，逐文件计时会误伤排在后面、还没开始传的正常文件。
- 小文件可能一个 progress 事件都没有就传完了 —— 那时气泡已是终态，看门狗在下一轮巡检自然退出。

**3. 附带修复：异常逃逸。** 两条路径的 `catch` 现在都会把 `failure` 置为非空并继续走到 `markSentFile` / `_failPendingFiles`。之前中途抛异常会让已置为 pending 的气泡再也无人收尾。

## 进度条

气泡下方的细进度条 + 百分比，只在上传阶段出现。

**为什么不把 `progress` 放进 `ChatMessage`**：会话状态（Redux）每次变更都会 `setConversations` 整份序列化写盘，而上传进度每秒来好几次，几百条消息的会话会被高频全量写盘拖垮；同时 provider 一变，整页 `ConversationPage.build` 连同可见的每条气泡都要重建。上游的 `fileTransferProvider` 出于同样理由用 `ChangeNotifier`。

做法（`provider/conversation/chat_transfer_provider.dart`）：

- 不参与持久化，纯内存旁路；**每条消息一个 `ValueNotifier<double?>`**，进度变化只重建那一条气泡。
- 键是 `messageId`。聊天场景里消息 id 与上传使用的 `fileId` 是同一个值（`ConversationSender` 刻意复用），所以 `send_provider.dart` 拿到 `HttpUploadFileProgressEvent` 后可以按 `event.fileId` 直接回报。
- `report()` **只更新已登记的条目**：没气泡在等（从普通「发送」Tab 发出去的传输）就只刷新时间戳、不建 notifier，不给每个普通传输都留一个没人用的对象。
- 另有 `_lastProgressAt`（`lastProgressOf`）记录最后一次进度事件的时间，**无条件**写入，供上传看门狗判断传输是否还活着（见「超时与看门狗」）。
- 节流 0.5%：上传事件按块回报，1GB 文件上千次，逐次重绘没有意义。允许回退（重发从 0 重来）。
- 清理只有一处：`markSentFile` 开头 `finish(messageId)`。所有终态（成功 / 上传失败 / 对端未勾选 / 源文件丢失 / 重试超时）都经过它。
- `finish` 只从 map 移除、**不 `dispose`**：气泡可能还在同一帧挂着监听，dispose 过的 notifier 再加监听会抛错。
- 进度为 `null`（还没进入上传，例如正在算校验和、或正等对方接受）时退回原来的「发送中…」文字，不占额外高度。
- 百分比用 `floor` 而不是 `round`：99.6% 还没传完，显示 100% 会让人以为卡住了。

## 文字选区 / 复制菜单

`conversation_page.dart` 用 `SelectionArea` 让气泡文字可选，但**菜单是自己弹的**，不走框架工具条：

- 框架的 `SelectableRegion._handleMouseDragEnd` 在 desktop（windows/macOS/linux）分支里明确写了 *"The selection overlay is not shown on desktop platforms after a drag"*，所以拖选结束后不会出现任何菜单——想要「选中即弹」必须自己接管。
- 触发点：`Listener.onPointerUp` → `_autoShowMenu()`；`MessageBubble.onSecondaryTap`（右键）→ 同一条 `_showCopyMenu()`。
- **坑：`addPostFrameCallback` 不会调度帧**（源码里只是 `_postFrameCallbacks.add`）。桌面端拖选结束后没有重绘，回调会一直挂着，表现就是「选中了但菜单永远不来」。必须用 `WidgetsBinding.instance.endOfFrame`（idle 时它会 `scheduleFrame()`），再补几次 16ms 短重试兜住 pending 选区。
- 用 `_selectionTouched` 区分「本次按下产生了新选区」（拖选/双击选词，要弹）与「点空白处取消选区」（pointer up 前选区还是旧的，不能弹）。这个判断必须放在 `await endOfFrame` **之后**：双击选词发生在手势竞技场裁决阶段，比 `onPointerUp` 更晚。
- 菜单框显式描 `colorScheme.outlineVariant` 边框——`showMenu` 默认只有阴影，浅色背景下几乎看不到边缘。

## 拖拽文件进入会话

- 会话页自己挂 `DropTarget`（`desktop_drop`）。**关键坑**：这个包不做冒泡/顶层判定，**所有**注册的 `DropTarget` 都会收到事件、各自用 `paintBounds` 命中。主页那层必须 `enable: ModalRoute.of(context)?.isCurrent`（`_ModalScopeStatus` 会在 push/pop 时通知依赖方重建），否则拖文件进会话页会同时被主页塞进「发送」Tab 并切走页面。
- 落下后先 `CrossFileConverters.convertXFile` 拿到 name/size，再弹 `showDropConfirmDialog`（`widget/chat/drop_confirm_dialog.dart`）：数量 + 合计大小 + 文件清单；取消＝红字红框，确认＝蓝底白字（复用 `kOutgoingBubbleColor`）。
- 确认后走 `deliverFilesInBackground`，与回形针**同一条**投递路径（2 分钟重试、预置「发送中」气泡、失败才提示）。
- 目录不展开（可能是整个盘），只提示跳过；拖拽悬停时整页盖一层 `_DropOverlay` 提示「松手即发」。

## 粘贴（Ctrl+V）：文件 / 图片 / 文本

Flutter 的 `Clipboard.getData` **只认纯文本**：`ClipboardData` 里只有 `text` 字段，实现里直接 `result['text'] as String`，位图根本没有通路。所以剪贴板走自建原生通道（通道名与 Android 共用一个：`org.localsend.localsend_app/localsend`），并且**按顺序问三种东西**：

1. `getClipboardFiles` —— 文件列表。资源管理器里 Ctrl+C 一个文件（含 `.jpg`）时，剪贴板里是 `CF_HDROP`（一组路径），不是位图；Android 对应的是带 `content://` URI 的 `ClipData`（可能是多条）。Windows 只回路径（文件已在磁盘上），Android 回 `{bytes, mime, name}`（没有路径可用），Dart 侧统一 `materialize` 成实体文件。
2. `getClipboardImage` —— 位图。Windows 先试注册格式 `PNG`，再试 `JFIF`/`JPEG`（少数看图工具只放这个），最后 `CF_DIBV5`/`CF_DIB` → 补 `BITMAPFILEHEADER` → WIC 解码 → **PNG 编码**。`OpenClipboard` 被占用时重试 5×20ms。
3. 文本 —— `Clipboard.getData(kTextPlain)`。

**为什么输出总是 PNG**：剪贴板里存的不是「图片文件」，而是解码后的像素（DIB）或一份流。PNG 只是我们落盘时选的容器（无损、能带 alpha），跟来源是 JPG / WebP / PNG 无关。复制一张 JPEG 照片粘贴进来，走的是第 2 步，转成 PNG 发出。

- Dart 侧把 `Ctrl/Cmd+V` 映射到私有 intent，在 **整个会话页**生效（`_PasteShortcuts`，不是只包输入框）：不点输入框也能粘。两个关键点：
  - 读剪贴板是异步的，而键事件必须同步给出「已处理」，所以文本粘贴也一并接管——没有文件/图片时走 `_insertText()`。
  - `_PasteShortcuts` 内部带一个 `Focus(autofocus: true)`：刚打开会话、什么都没点时，焦点是 route 自己的 `FocusScopeNode`，它在页面**外层**，沿 context 向上找 `Shortcuts` 根本不会经过本页（表现就是「没聚焦时按 Ctrl+V 无效」）。
- **不能用 `Actions.invoke(context, PasteTextIntent(...))` 把文本粘贴交回框架**：那个 action 由 `EditableTextState` 注册在它自己的子树里，`Actions.invoke` 只沿 context 向上找，从输入条 context 永远找不到，会静默 no-op（表现为「文本粘不进来」）。
- 文件/图片先落缓存目录（`getCacheDirectory()`；图片名为 `clipboard-yyyyMMdd-HHmmss.png`，Android 文件保留原名并消毒非法字符），再 `CrossFileConverters.convertFile` + **复用同一张 `showDropConfirmDialog`**，确认后走 `deliverFilesInBackground`（与拖拽、回形针同一条投递路径）。
- 文件夹不展开（和拖拽一致）：跳过并提示 `pasteSkipped`。
- 确认卡片会抢焦点，关闭后要 `_focusNode.requestFocus()` 把光标还给输入框。

## 状态机

```
ChatMessageStatus:  pending ──成功──> sent
                       └────失败──> failed
接收侧恒为 received
```

去重靠 `message.id`：接收方向复用 `fileId`（重传天然幂等），发送方向复用源 `file.id` / 新 UUID。

## 上限与排序

- 每会话 `maxMessagesPerConversation = 500`，超出砍最旧消息，卡片保留。
- 全局 `maxConversations = 200`，超出按 `lastActivity` 倒序截断，**最久未活动的卡片直接消失**（不是折叠）。
- `unreadCount` 只统计接收方向；进入会话页由 `MarkConversationReadAction` 清零。

## 扩展点

| 想加 | 改哪里 |
|---|---|
| 图片/缩略图预览 | `ChatMessage` 加字段 + `file_message_card.dart` + `preview` 逻辑 |
| 消息重试 | `conversation_page.dart` 的 failed 气泡 + 复用 `sendTextMessage`（`messageId` 需换新） |
| 已读回执 | 需新协议：LocalSend 无此能力，只能在文本消息里塞约定字段 |
| 群聊 | 协议层不支持（一条消息只有一个对端），需自定义 `FileType.text` 载荷 + 新聚合键 |
| 搜索 | `conversations_page` 加 TextField，直接在 `state.messages` 上过滤，无需新存储 |

## 测试

```bash
cd app && flutter test test/unit/provider/conversation_provider_test.dart   # 16 个用例
cd app && flutter test test/unit/provider/chat_transfer_test.dart           # 11 个用例（节流 / 回退 / 清理 / 时间戳）
NO_PROXY=localhost,127.0.0.1,::1 flutter test                              # 全量（HTTP_PROXY 会拦 localhost WebSocket）
```

## 已知限制

- `peerPort` 为空的旧会话无法主动发消息（`resolveConversationTarget` 返回 null，`https` 只能猜 false）。
- 对端改名后卡片名会更新，但**无指纹的对端**改名会分裂成新卡片（伪键 `alias:<别名>`）。
- 文本消息上限 4000 字符（`maxTextMessageLength`）。
- 输入条是**多行**输入框（`minLines: 1` / `maxLines: 6`），但 `textInputAction` 故意用 `send` 而不是 `newline`：Windows 引擎的 `TextInputPlugin::EnterPressed` 只在 `TextInputType.multiline + TextInputAction.newline` 组合下自己往文本里插换行，用 `send` 才能让每个 Enter 先经过框架的 `onSubmitted`，否则没有机会「按 Enter 发送」。
- 回车语义集中在 `_handleEnter()`：裸 Enter 发送；Shift+Enter 由自己 `_insertText('\n')` 补换行（引擎不会补）；Ctrl / Alt / Cmd + Enter 忽略。修饰键信息到不了 action（引擎只透传 `inputAction`），只能在 `onSubmitted` 里读 `HardwareKeyboard`。
- Android 软键盘的「发送」键走 `performAction(send)`，与桌面一致；Android 物理键盘的 Enter / Shift+Enter 通常由 IME 直接插换行，不经过这条路径。
- 粘贴只在 **Windows / Android** 有原生实现（macOS / Linux / iOS 会走 `MissingPluginException` 分支，退化为普通文本粘贴）。
- Android 上粘贴依赖物理键盘的 Ctrl+V；软键盘长按弹出的系统「粘贴」走的是 `TextInputClient` 通道，不经过 `Shortcuts`。
- 剪贴板文件一次最多 100 个（Windows `kMaxFiles`）/ 20 个且单文件 ≤256MB（Android `MAX_CLIPBOARD_*`）：Android 是把字节读进内存再落盘，不设上限会 OOM。
- Windows 复制**文件夹**只会被跳过（`Directory.existsSync()` 判断），不展开递归。
