# 模块卡：会话 / 聊天（fork 自建，无上游参照）

## 职责

把 LocalChat 的「收发事件」投影成微信式会话视图：按对端设备聚合、双向记录、按最近活动排序。**不参与任何传输逻辑**——它只读事件，写自己的存储，失败时静默降级。

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
| `app/lib/util/conversation/send_failure.dart` | 失败原因（18 类）+ 三档分类器 + 文案，见「失败原因分类」 |
| `app/lib/provider/conversation/chat_transfer_provider.dart` | 上传进度与**发送阶段**旁路（每条消息一个 `ValueNotifier`） |
| `app/lib/pages/conversations_page.dart` | 列表 + 空态 + 全清 + 长按删除 + 待分享横幅（点会话确认后发送，见「系统分享落进会话」） |
| `app/lib/pages/conversation_page.dart` | 详情 + 底部输入栏（[附件][输入][发送]）+ 文字选区/右键「复制」菜单 + Ctrl+V 粘贴（文件 / 图片 / 文本）+ 气泡多选删除 |
| `app/lib/util/conversation/clipboard_image.dart` | 剪贴板文件与图片读取（原生通道）+ 落缓存目录 + 文件名消毒 |
| `app/lib/util/conversation/chat_presence.dart` | 只记「App 是否在前台」，决定收到消息要不要弹通知 |
| `app/lib/util/native/chat_notification.dart` | 通知的 Dart 入口：发送 / 清除 / 查状态 / 跳设置 / 点击回调 |
| `app/android/.../MainActivity.kt` | 通知渠道 `localchat_messages` 与 `showChatNotification` 等方法 |
| `app/windows/runner/clipboard_image_win.cpp` | WIC：剪贴板 PNG / JPEG / DIB → PNG 字节（不依赖 Flutter，可单独编译验证） |
| `app/windows/runner/clipboard_files_win.cpp` | `CF_HDROP` → 路径列表（拖动文件到剪贴板时只有这个格式） |
| `app/windows/runner/clipboard_ext.cpp` | Windows 侧方法通道 `getClipboardImage` / `getClipboardFiles` |
| `app/android/.../MainActivity.kt` | 同一个通道的 Android 实现（读 `ClipData` 的 content URI） |
| `app/lib/widget/chat/message_bubble.dart` | 文本气泡、头像、固定发出色 |
| `app/lib/widget/chat/file_message_card.dart` | 文件气泡 |
| `app/lib/widget/chat/top_toast.dart` | 顶部 Toast（替代 SnackBar） |
| `app/lib/util/conversation/peer_label.dart` | 重名消歧：指纹短码 / 名字分布统计 / 纯文本标题，见「重名消歧」 |
| `app/lib/widget/chat/peer_title.dart` | 会话标题组件（名字 + 同名时的指纹短码），列表与聊天页共用 |

## 卡片生成条件

一张卡片 = 一个 `Conversation` 对象。**没有"新建空会话"入口**，卡片只能是「消息被成功追加」的副产物。三个前提缺一不可（`conversation_provider.dart:48-56`）：

1. 走 `AppendChatMessageAction`；
2. `peerFingerprint` 非空（`peerKeyOf` 优先设备指纹，退化 `alias:<别名>`）；
3. 该 `message.id` 尚未存在于该会话（重复即只更新，不新增）。

五个实际触发点：收到文本（自动接收）、收到文件且落盘成功（`error == null && desiredName != null`）、自己发文本（先写"发送中"）、自己发文件（`deliverFiles` **在投递前**就写好"发送中"，不依赖 Started 事件）、`markSentFile` 兜底补插。

**普通「发送」Tab 也走同一套（2026-11-05 补）**：`send_provider.startSession` 在握手之前就调 `recordSentFileStart` 预置气泡（`_preRecordSessionMessages`），并把这些 id 记在 `_preRecordedMessages[sessionId]` 里。之前只在 `HttpUploadFileStartedEvent` 里写，结果是**连不上 / 被拒绝 / 对端一个文件都没勾选时，会话里什么都没有**——「我明明发过」这件事直接消失。收尾由 `_settlePreRecorded` 负责：握手阶段的每个终态分支、`_finish`、`closeSession` 都会调它，把还没结局的预置气泡标成失败（`FileStatus.finished` 的跳过，避免把已成功的改坏）。聊天页传了 `fileIdsOverride`，所以这条兜底完全绕开它（聊天自己那套要能重发、要精确 alias）。

**推论**：发送失败也会留卡片（末条 `failed`，列表显示红点）；接收被拒/接收失败不留卡片；从普通「发送」Tab 传文件也会刷新卡片（钩子在 `startSession` 里，不区分入口）。

## 重名消歧：标题后的指纹短码

会话主键是证书指纹，而 `peerAlias` 只是对端自报的字符串。两台设备可以合法同名
（都叫 `vivo`），也允许 A 把自己改成 B 的名字 —— 这时列表会出现两行一模一样的标题，
点进去标题栏也一样，光看界面分不清是谁。

规则：**只在同名时**在名字后面追加指纹末 4 位，形如 `B · 3F7A`；不同名时一个字都不加，
日常观感与原来完全一致。

| 关注点 | 做法 |
|---|---|
| 短码来源 | `peerShortCode(peerFingerprint)`，取 64 位十六进制指纹末 4 位并转大写（与设备详情页的完整指纹尾巴对得上） |
| 是否同名 | `peerNameCounts()` 先在整张列表上统计一次名字分布，`peerNameCollides()` 查表；**不用对象引用判断**（会话是不可变对象，每追加一条消息都会重建） |
| 渲染 | `widget/chat/peer_title.dart` 的 `PeerTitleText`，列表与聊天页标题栏共用；短码字号取生效样式的 0.78 倍 + `outline` 弱色，读起来像注释 |
| 纯文本场景 | `peerLabel(conversation, ambiguous: true)`，用于删除会话的确认文案，避免「确定删除 B？」而不知道是哪个 B |

**为什么不用 IP**（考虑过并否掉）：`Conversation.peerIp` 记的是最后一次见到的地址，
DHCP 换租、对方切 Wi-Fi 后就过期，旧 IP 还可能被分给另一台设备 —— 标签会主动误导；
IPv6 链路本地地址形如 `fe80::3524:1f%3`，列表一行放不下；而且 `displayName` 被
删除确认文案复用，往里拼 IP 会污染整个界面。指纹不会变，是唯一稳定依据。

**没覆盖的地方**（如实记录）：通知标题仍只用 alias（`ChatNotification` 拿不到全量列表），
两台同名设备同时发消息时，两条通知标题一样 —— 但通知 tag 是指纹，不会互相顶掉。

## 从发送页发起会话（草稿会话）

发送页每张设备卡片右侧有两颗按钮：左边**发起会话**（气泡图标），右边**设备详情**（`i` 图标）。
点气泡直接进入与这台设备的聊天，不必先发一个文件把会话「撞」出来。

难点是：本地还没有这台设备的会话记录，而 `ConversationPage` 的数据全部来自
`conversationProvider`。做法是**用设备信息拼一个不落库的草稿会话**，而不是往 provider 里塞空会话。

| 关注点 | 做法 |
|---|---|
| 入口 | `pages/tabs/send_tab.dart` 的 `_startConversation()`；`widget/list_tile/device_list_tile.dart` 的 `onChatTap` |
| 没有指纹就不给按钮 | 会话主键是指纹，拿不到时上游会退化成 `alias:<名字>` 伪键，对方一改名就分裂，不如不开放 |
| 草稿 | `conversation_page.dart` 的 `_draftConversation()`：`stored ?? draft`，标题 / 头像 / 发送目标都能用 |
| 落库时机 | 第一条消息发出时 `AppendChatMessageAction` 发现不存在就新建，页面随即改用真会话，用户无感 |
| 不塞空会话的理由 | 否则点一下「发起会话」又退出，列表里就多一条预览为空、时间是刚刚的僵尸记录 |
| 判重名 | 草稿不在列表里，`peerNameCounts` 要把它自己算进去，否则「和已有会话同名的设备」开新会话时分不清是谁 |
| 拖拽 / 粘贴 | `_handleDrop` 与 `_currentTarget` 改用 `_effectiveConversation()`，草稿状态下也能直接投递文件 |

**边界**：`ConversationPage.device` 只在「发起会话」这条路径上传；从会话列表进来时它是 null，
找不到会话仍然显示「该会话已被删除」——即原有的删除后残留页面行为没有变。

## 发送阶段与超时结构

一次文件发送有四段**性质完全不同**的等待，各自该有独立的判死条件。混成一个总窗口会直接毁掉大文件传输（30 GB 在 dev 构建下光算校验和就要 7 分钟，130 秒的窗口连一次 `prepare-upload` 都发不出去，气泡报「发送失败」而手机根本没收到任何请求）。

| 阶段 | 判死条件 | 起算点 | 代码 |
|---|---|---|---|
| 本地校验和 | 无上限，只能用户取消 | 点击发送 | `_precomputeChecksums` |
| 连接 / 送达 | 压在上面的 2 分钟里（真正连不上会秒级被拒） | 校验完成 | `_deliverWithRetry` |
| 等待对方接受 | 2 分钟 | 请求真正送达 | 同上（`waitingAccept` 阶段） |
| 传输数据 | 60 秒无进度 | 拿到 upload token | `_watchStalledUploads` |

**校验和为什么必须在窗口之外**：`send_provider.startSession` 内部的 `await calculateFileHash` 原本也被 `.timeout(130s)` 包住。`createChecksums` 默认开启，30 GiB 的完整 SHA-256 在 `opt-level=0` 下约 7.4 分钟 —— 窗口先到，`SendFailure` 已经落地，请求一个字节都没出去。现在 `_precomputeChecksums` 在 `_deliverWithRetry` 之前跑：**不设时间上限**（纯本地，慢只该慢自己），但**可取消**（`_hashCancel` 按 sessionId 存 cancel token，取消时读盘立刻停），算完填进 `checksums`，`startSession` 命中 `checksumCache` 后直接跳过二次读盘。设置里关掉 `createChecksums` 时整段跳过。

**阶段状态机**（`chat_transfer_provider.dart`）：`ChatTransferPhase { hashing, connecting, waitingAccept, uploading }`，每条消息一个 `ValueNotifier`，与进度表同一套设计 —— 阶段变化只重建那一条气泡的页脚。

- `waitingAccept` 的判定是**单次 `prepare-upload` 超过 2 秒仍未返回**。局域网实测 TCP+TLS 只要 0.03 s，2 秒不回只可能是在等人点接受（接收端在「需要确认」模式下会 hold 住请求）。
- `uploading` 由 upload 事件驱动（`send_provider.dart` 的 `HttpUploadFileProgressEvent` 分支），不让发送流程在两个地方各写一次。
- `finish` / `reset` 一并清理阶段，避免重发时串阶段。

**两个必须一起改的坑**：

1. **`hashing` 阶段不能计入 UI 兜底**（`chatSendWatchdogTimeout = 135s`）。否则 30 GiB 在 dev 构建下算 7 分钟，气泡会被自己的看门狗判成失败 —— 这是「2 分钟失败」的第二条触发路径，和上一条独立。
2. **批量发送要在进校验前先把整批标成 `hashing`**，否则排在后面、还没轮到算哈希的文件阶段还停在旧值，会被同一个兜底误杀。

**收益**：校验和与「探测对端是否在线」本来是串行的（对方没开 App 也要先白等 10 分钟哈希才发现连不上）。分离后哈希阶段有独立进度，用户至少知道它在做什么。

## 离线重试（2 分钟窗口）

LocalChat **没有**可调的「发送超时」：对端 App 没开时 prepare-upload 会被系统 TCP 栈秒级拒绝（值不可配置）。所以「给对方时间拿起手机」只能靠重试。

- `textSendRetryWindow = 2min`，`_retryInterval = 2s`；全程复用同一个 `sessionId`，避免 `fileTransferProvider` 里堆积一次性状态。
- **2 分钟只覆盖「连接 + 等对方点接受」，不含本地校验和**。校验和在 `_deliverWithRetry` 之前由 `_precomputeChecksums` 算完，见「发送阶段与超时结构」。
- 只重试 `peerOffline` / `peerNoResponse` / `localNetwork` / `unknown`（对端没给出明确答复）；其余一律立即失败，见「失败原因分类」。
- **文件只在握手阶段重试**：一旦 `session.files` 里有 `token != null`，说明已进入流式上传，重来会在对端留下半截文件 → 停止重试，后续交给 upload 事件。
- 跨重试复用 `checksumCache`（`send_provider.startSession` 的 `[FORK]` 参数），否则两分钟内会把几百 MB 文件反复读盘哈希。
- 投递全程在后台：页面不 `await`，输入框不锁；结果由气泡状态（转圈 / 红色感叹号）和顶部 Toast 表达。
- 这 2 分钟里用户可以随时点转圈取消（见「主动取消与界面兜底」），不必干等。

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

## 失败原因分类

定义在 `app/lib/util/conversation/send_failure.dart`（`enum SendFailure`，18 个取值 + `failureForStatusCode` + `classifySendErrorText` + `describeSendFailure`），`conversation_sender.dart` 再 `export` 一次，调用方 import 习惯不变。

**为什么单独一个文件**：`send_provider.dart` 也要用这套分类（发送 Tab / 收藏 / 地址等入口的气泡收尾），而 `conversation_sender` 已经 import 了 `send_provider`。定义留在 sender 里会让 provider 反向依赖它形成循环。

**三档来源，优先级从高到低**：

1. 结构化错误（`RsHttpClientError_StatusCode` / `_ConnectionError` 等）；
2. 错误文本关键词（`classifySendErrorText`）；
3. `unknown`。

关键词表的**顺序有讲究**：空间不足 / 校验不一致 / 证书 / PIN / 连接被拒 / DNS / 超时 / 连接重置，具体原因必须排在「超时」大类之前，否则所有超时都会被归到同一个笼统项。

**`peerNoResponse` 与 `acceptTimeout` 的区分**（最值得记的一条）：这两者在发送端**长得完全一样** —— 都是 `prepare-upload` 发出去后永远没有回音，最后被 130 秒硬超时砍掉。区别只在对端：

| 对端真实状态 | 网络指纹 | 归类 |
|---|---|---|
| App 进程被系统冻结（息屏 / 不在前台） | 内核接了 TCP，TLS 握手零字节超时 | `peerNoResponse`「已连上，但对方没有任何响应」 |
| App 正常、接收页开着但没人点 | 握手秒过，请求躺在应用层 | `acceptTimeout`「请求已送达，但对方没有在 2 分钟内接受」 |
| App 没开 / 服务未监听 | 连接被拒 | `peerOffline`「对方不可达」 |

判定方式是 `_diagnoseTimeout(target)`：硬超时**之后**用 `SecureSocket.connect(..., timeout: 2s, onBadCertificate: true)` 再握一次手 —— 只看连通性、不发任何数据。只在已经等满窗口之后跑，正常路径零开销。

**重试集合随之收紧**：只有 `peerOffline` / `peerNoResponse` / `localNetwork` / `unknown` 可重试（对端没给出明确答复）；其余（拒绝、忙、限流、204、PIN 错、证书不符、空间不足、写盘失败、校验不一致）立即定论 —— 重试只是把同一个错误再问一遍。

**分类必须落到气泡上**，否则等于没做：`_failPendingFiles` / `_failFilesAt` 接受 `failure` 参数，经 `describeSendFailure` 写进 `ChatMessage.errorMessage`，覆盖四条路径 —— 文本消息、文件投递失败、重发失败（源文件丢失）、上传看门狗。`send_provider._settlePreRecorded` 同步改。之前这些地方调 `markSentFile(success: false)` 时根本没传 `errorMessage`，气泡只能退回那句笼统的「发送失败」。

单测：`test/unit/util/send_failure_test.dart`（15 用例，含「具体原因优先于超时大类」这类顺序陷阱）。

## 主动取消与界面兜底

上一轮修掉「窗口根本不起作用」之后，仍然会收到「点了重发一直在转圈」的反馈。原因不同：**这次它确实在工作** —— 对着离线对端每 2 秒重试一次，界面只写「发送中…」，既看不出推进，也无法中止。超时存在不等于用户能感知。

三层，从主动到兜底：

1. **手动取消**：转圈本身是 `InkResponse`（`Tooltip`「点击取消发送」），只在发出方向 + `pending` 时挂 `onCancel`。`cancelChatMessage` 先把气泡写成 `failed`（`SendFailure.cancelled` →「已取消发送」），再 `closeSession` 断开后台会话，不等下一条事件。
2. **令牌阻止复燃**：`_SendTicket` + 模块级 `_inFlight: messageId -> ticket`。光 `closeSession` 不够 —— 它只取消当前挂着的 prepare-upload，重试循环下一轮还会再发一次，所以 `_sendTextWithRetry` / `_deliverWithRetry` **每轮开头**都要查 `ticket.cancelled`。一个文件批次共用一个令牌：取消任意一条就整批停，避免「取消了一条、剩下几条还在后台排队」。
3. **界面兜底**：`chatSendWatchdogTimeout = window + grace + 5s`。气泡下方的倒计时（`_SendProgressFooter` 的 1s ticker）走满就回调 `onStalePending` → 直接标失败。它不依赖任何后台任务，专门覆盖「发送流程已经不在了、气泡却还挂着」：异常逃逸，或**页面销毁后 `ref` 失效导致上传看门狗静默退出**（`_watchStalledUploads` 里 `ref.read` 抛异常就 `return`，正是最隐蔽的一条）。

**取消后不再写终态**：`sendTextMessage` / `deliverFiles` 在 `ticket.cancelled` 时直接返回，不调 `markSentFile` / `_failPendingFiles`。否则会把「已取消」覆盖成「发送失败」，甚至在「用户点取消的同一瞬间刚好发成功」时改回「已发送」。

**兜底计时在 `hashing` 阶段暂停**：ticker 每轮先读一次 `phaseOf(messageId)`，等于 `ChatTransferPhase.hashing` 就直接 `return`，不累加 `_seconds`。校验和是本地读盘、有进度、可取消的工作，30 GiB 在 dev 构建下要几分钟，用它去触发「发送中太久」的兜底等于自我误杀 —— 这是「2 分钟失败」的第二条独立触发路径，只改窗口起点治不了它。批量发送同理：进校验前先把**整批**标成 `hashing`，否则排在后面、还没轮到算哈希的文件会停在旧阶段被误杀。

**倒计时是这次的关键**：`sending` 文案换成 `sendingCountdown`（「发送中 12s…」）。纯「发送中…」连续几十秒，用户无法区分「在工作」和「卡死」—— 这正是本次反馈的来源。

**`cancelChatMessage` 在 `_inFlight` 找不到令牌时也会标失败**：那种情况说明发送流程已经消失，气泡却还挂在 pending，是「永远转圈」最难看的样子。返回值 `false` 只表示「没有流程可停」，不影响收尾。

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
- 进度为 `null`（还没进入上传）时分两段表达，见下。
- 百分比用 `floor` 而不是 `round`：99.6% 还没传完，显示 100% 会让人以为卡住了。

**页脚按阶段渲染**（`ChatTransferPhase`，见「发送阶段与超时结构」）：同一行小字，三种形态。

| 阶段 | 文案 | 进度条 |
|---|---|---|
| `hashing` | 校验中 42%（`verifyingChecksum`） | 确定态，值来自哈希进度 |
| `connecting` | 正在连接…（`connectingPeer`） | 扫动（`value: null`） |
| `waitingAccept` | 等待对方接受…（`waitingForPeer`） | 扫动 |
| `uploading` | 发送中 42%（`sendingProgress`） | 确定态 |
| `null`（旧流程 / 未登记） | 发送中 12s…（`sendingCountdown`） | 优先真实进度，没有就扫动 |

- 没有真实百分比且**进入该阶段不足 3 秒**时只给一句话（`indeterminateAfter`），避免每条小消息都闪一下扫动条。
- 确定态与不确定态共用同一个 `_bar()`，固定 96×3，切换时不跳布局。
- 秒数由 `_SendProgressFooter` 自己的 1s ticker 驱动（只重建这一行小字），同一 ticker 还负责 `chatSendWatchdogTimeout` 的兜底 —— 但**读盘校验期间不累加**（见「主动取消与界面兜底」）。

## 气泡菜单：复制 / 多选 / 取消传输 / 打开文件所在位置 / 删除该条记录

菜单由页面统一弹（`_showMessageMenu`），桌面右键、移动端长按、桌面拖选三条入口共用一份。
显示顺序即 `_ChatMenuAction` 的声明顺序：复制 → 多选 → 取消传输 → 打开文件所在位置 → 删除该条记录
（「多选」是内容操作，紧跟复制；「取消传输」是当下最相关的止损动作，排在定位/删除之前；破坏性项仍排最后）。

| 入口 | 平台 | 菜单项 |
|---|---|---|
| 气泡右键（`MessageBubble.onSecondaryTap`） | 桌面 | 复制 + 多选 + 取消传输（仅传输中的文件）+ 打开文件所在位置（仅文件消息）+ 删除该条记录 |
| 气泡长按（`MessageBubble.onLongPress`） | 移动端 | 复制 + 多选 + 取消传输（同上）+ 删除该条记录 |
| 拖选 / 双击选词后自动弹（`Listener.onPointerUp` → `_autoShowMenu`） | 桌面 | 只有复制（选区不属于某一条消息，没有可多选的对象） |

**文字选区只在桌面开**（`_selectableTextSupported`）：移动端 `SelectionArea` 的选词手势
会在手势竞技场里赢走长按，而它的工具条又被 `contextMenuBuilder` 置空，导致手机上
选中文字**没有任何复制入口**——占着长按却不可用。所以移动端不套 `SelectionArea`，
把长按让给菜单，「复制」变成菜单项反而可用。

### 取消传输

只在下面三个条件同时成立时出现（`_showMessageMenu` 里的 `canCancelTransfer`）：

```dart
message.kind == ChatMessageKind.file &&
message.isOutgoing &&
message.status == ChatMessageStatus.pending
```

- **传完（sent / received）不显示**：没有进行中的任务可停。
- **失败（failed）不显示**：流程已经终止，恢复入口是红色感叹号重发。
- **接收方向不显示**：`cancelChatMessage` 找的是发送侧的 `_SendTicket`，接收方向上没有对应凭证 —— 硬用只会把气泡改成失败，真实请求还在跑，是个假按钮。接收端的中止在接收页上，语义是另一套。

动作不走新逻辑，直接复用点转圈的 `_cancelMessage` → `cancelChatMessage`：整批文件一起停、`_hashCancel` 中断读盘（正在算的 30 GB 校验和会立刻停）、`closeSession` 取消挂起的 `prepare-upload`。

结果文案按消息类型分岔：文件的 toast 与页脚是「已取消传输」（`transferCancelled`），文本仍是「已取消发送」（`sendCancelled`）—— 菜单里给的词和结果提示必须是同一个。

### 打开文件所在位置

只在桌面端、且消息是**文件**（`kind == file`）并带本地路径（`filePath != null`）时出现，
判断集中在 `_showMessageMenu` 里的 `canRevealInFolder`。移动端不给：手机上没有文件夹
可浏览，收到的路径还可能是 `content://`（相册 / 下载管理器），`openFolder` 在 Android
上走的是另一个分支，语义不是「定位到文件」。

`_revealInFolder(message)` 走 `openFolder(folderPath: parent, fileName: basename)`，
与接收历史页的「在文件夹中显示」是同一套实现（`util/native/open_folder.dart`）：
Windows 资源管理器 `/select` 选中该文件，macOS 访达、Linux 文件管理器同理。

两个细节：

- **文件名取磁盘上的**（`p.basename(filePath)`），不用 `message.fileName`：
  落盘时同名文件会被改名成 `xxx (1).txt`，用消息里记的名字会选不中。
- **目录不存在时提示一句**（`t.conversation.revealInFolderFailed`，`TopToast`）：
  资源管理器对不存在的路径既不报错也不开窗口，用户只会觉得「点了没反应」。

### 多选删除

入口在同一个菜单里：右键 / 长按气泡 →「多选」。点进去时**当前这条自动选中**——
点「多选」的意图通常是「删这条，顺便再勾几条」。拖选文字带出的菜单没有具体消息，
不显示这一项。

多选态下整行点击只做一件事：切换选中。菜单、打开文件、点转圈取消全部让位。
三条硬约束：

- 消息列表的 widget 树**保持不变**。`SelectionArea` 没有 `enabled` 参数，二选一渲染会让
  桌面端 `ListView` 整棵重建、`ScrollController` 的 offset 丢失，进多选会直接跳回顶部。
  所以只在 `_handlePointerUp` / `_handleBubbleMenu` 里 `if (_selecting) return`，
  并在进入时 `clearSelection()`。
- `MessageBubble` 的 `onFileTap` / `onCancel` / `onRetry` 一律传 `null`。文件卡片内层
  `InkWell` 在手势竞技场里优先于外层 `GestureDetector`，不置空就是「点了选中不了、
  反而把文件打开了」。
- 底部用 `Offstage` 保留 `_Composer`，不要 `if/else` 二选一。`_ComposerState` 持有
  `TextEditingController`，被移除会 dispose，输入到一半的草稿会丢。

底部面板 `_SelectionBar` 与输入栏同一底色、同一条顶部细线，切换时只是内容变了。
布局：左「已选 N 条」，右侧 [删除]（红色实心，N=0 置灰）+ [退出]（文字按钮，最右）。
右端拇指最易触达，留给非破坏性的退出。

退出有四条等价路径：面板「退出」；Android 返回键 / 预测性返回（走 `PopScope`）；
桌面 `Esc`；iOS 左边缘右滑。两个平台细节：

- **iOS 侧滑要自己补**。`PopScope(canPop: false)` 会连带关掉 `CupertinoPageRoute`
  的返回手势（`popGestureEnabled == false`），`onPopInvokedWithResult` 根本不会被调用。
  `_SelectionEdgeSwipe` 用 `Listener`（不进手势竞技场、不消费事件）在左边缘 24px 内
  跟踪指针，水平右滑超过 72px 且明显偏水平就退出。
- **Esc 要先抢焦点**。进入多选会 `unfocus` 收起键盘，焦点退回 route 自己的
  `FocusScope`（在页面**外层**），Esc 沿焦点链向上找不会经过 `_PasteShortcuts`。
  所以进入多选时 `requestFocus()` 到页面持有的 `_shortcutFocusNode`。

删除顺序与单条一致，不能换：取消传输中的（`cancelChatMessage` 按 ticket 整批收敛，
逐条调用幂等）→ 删接收历史（`RemoveHistoryEntriesAction`，一次写盘 + 一次联动）→
删会话消息（`DeleteChatMessagesAction`，删空则一并移除会话，页面随即 `maybePop`）。
选中的消息在别处已经被删掉时（例如在接收历史页联动了同一张卡片）直接退出，不弹确认框。

确认卡片 `showDeleteSelectedDialog` 不复用单条那张：一次勾二十条时只摆一条预览等于
没告诉用户删的是什么。预览最多列 3 条，其余折成「…等 N 条」；「含接收文件」
「含传输中」两个副作用按实际组成分别提示。

### 文件已不在本机

`ChatMessage.filePath` 只是一个路径，文件随时可能被移动 / 更名 / 删除，所以「还在不在」
是渲染时现查的。判断只有一处：`util/native/file_availability.dart` 的 `localFileExists`。

- `null` / 空串 → 不存在（这条消息本来就没有本地副本，例如接收时只存进了相册）；
- **只在桌面端 + 绝对路径下真的去 stat**：Android 的绝对路径可能落在 scoped storage，
  `exists()` 会因权限不足误报 false，宁可说「有」也不能把能打开的文件说成丢了；
  `content://` 这类 URI 不归 `File` 管，`exists()` 对它只会返回 false。

三处表现（都由这一个判断派生，不各说各话）：

| 位置 | 文件还在 | 文件已不在 |
|---|---|---|
| 卡片悬浮光标 | 手型 | 箭头 |
| 卡片悬浮提示 | 无 | 「文件已被移动、更名或删除」；`filePath` 为空时换成「这个文件不在本机」 |
| 菜单「打开文件所在位置」 | 可点 | 置灰（`enabled: false`），仍然显示 |

置灰**不写死颜色**：`PopupMenuItem(enabled: false)` 自带 disabled 样式——M3 文字取
`onSurface` 的 38%（浅色 → 灰 100 左右，深色 → `onSurface` 压暗到 38%），图标再叠
0.38 / 0.5 的不透明度，深浅主题自动跟。如果自己给图标或文字上色，会和框架的透明度
叠两层，反而更不协调。

`FileMessageCard` 为此从 `StatelessWidget` 变成 `StatefulWidget`：`initState` 查一次，
`MouseRegion.onEnter` 再查一次（文件可能是卡片渲染之后才被删的），结果有变化才 `setState`。
「点开」时的兜底仍在 `util/native/open_file.dart`（不存在就不交给系统打开器，
免得 Windows 先弹一个系统级「找不到文件」框）。这条提示走**顶部 toast**
（`TopToast`，红字、3 秒自动收起），不是 `CannotOpenFileDialog`：文件不见了属于
「点一下才知道」的轻量信息，弹框还得再点一次「关闭」，反而打断聊天。
`CannotOpenFileDialog` 仍保留给「文件在、但系统打不开」这条分支——那里有
「从历史里删除」的操作，需要按钮。

`TopToast` 的正文用 `colorScheme.error`（真红字），不用 `onErrorContainer`
——后者在浅色主题下是接近黑的深红（`#410002`），读起来不像告警。
同一时刻只保留一条，新的顶掉旧的，不会叠出两个。

`OverlayEntry` 的内容**不在任何 `Material` 之下**，会直接继承 `MaterialApp` 根部的
`_errorTextStyle`（`material/app.dart`：红色等宽字体 + 黄色双下划线，本是给
「缺 Material 的 Text」兜底的诊断样式）。所以 toast 里套了一层
`Material(type: MaterialType.transparency)`，并且 `TextStyle` 显式写
`decoration: TextDecoration.none`，两重保险。

### 删除该条记录

`_deleteMessage(message)` 按固定顺序做三件事：

1. **还在 `pending` 的先取消**（`cancelChatMessage`）：气泡马上要从列表消失，
   不取消的话后台会把文件继续传完，对端照样收到。
2. **删接收历史里同 id 的条目**（`RemoveHistoryEntryAction(message.id)`）：
   只有收到的文件才有对应条目（`entryId == fileId == message.id`），
   与 §「文件：两边都留，但删除联动」正好是反方向，两个视图始终一致。
3. **删会话里的这条消息**（`DeleteChatMessagesAction({id})`）。
   删空时会连会话一起移除，页面随即 `maybePop` 退回列表——
   否则留在页上只会看到「该会话已被删除」。
   （第 2 步内部也会联动删会话消息，第 3 步此时是幂等空转。）

不删磁盘上的文件：删除的是「记录」，不是用户的文件。

#### 删除前先确认

菜单点「删除该条记录」不会立刻删，先弹 `showDeleteRecordDialog`
（`widget/chat/delete_record_dialog.dart`），返回 `true` 才走上面的三步。

- 卡片顶部把**待删内容**摆出来（文本截断 4 行、文件名**单行**省略号——文件名没有可折行
  的位置，允许两行会把扩展名从中间劈成「…852.j / pg」），删除没有撤销入口，
  至少要让用户看清删的是哪一条。
- 正文按 `kind` + `direction` 分三种文案：文本只影响本机；**收到的**文件会连带删历史条目；
  **发出去的**文件本来就没有历史条目，不能照抄前一句。
- `pending` 的消息额外补一行红字：删除会先取消传输（对应第 1 步的副作用）。
- 取消＝中性灰描边，确认＝实心红（`colorScheme.error`），与菜单里的红字项呼应；
  点遮罩 / 按 Esc 关闭等同取消。

## 文字选区的两个实现坑

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

## 系统分享落进会话（Android share intent）

其它 App「分享 → 选中本应用」后的落点。`_HandleShareIntentAction`（`config/init.dart`）把文件加进 `selectedSendingFilesProvider` 后，**Tab 切到「会话」而不是「发送」**，列表顶部出现 `_ShareFilesBanner`（数量 + 总大小 + 关闭按钮）。此时点任意会话 → `showDialog` 确认「发送给 X？」→ 确认后 `ConsumeSelectionAction` + `deliverFilesInBackground` + 进入会话页看进度。

三个刻意的设计：

- **文件继续留在 `selectedSendingFilesProvider`**（横幅也从它读）：用户不愿意在会话列表里选时，切到「发送」Tab，原有「选设备 → startSession」流程原样可用，两条路共享同一份待发列表。
- **消费列表用 `ConsumeSelectionAction`，绝不用 `ClearSelectionAction`**。分享文件全在缓存目录里（`share_handler` 把共享内容拷成真实路径），`ClearSelectionAction` 的 after() 会清空整个缓存目录，把还在上传的源文件删掉。`Consume` 只清列表，缓存留给下次启动的 `ClearCacheAction` 兜底。
- **确认后才解析目标地址**：`resolveConversationTarget` 返回 null（会话不在当前局域网也没记录过 IP）时保留待分享列表，用户可换会话或去发送页。

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

## 接收文本：静默还是先确认

文本消息不落盘（接收端回 204，正文在 `preview` 里随 `prepare-upload` 到达），默认**静默接收**：不弹接收确认页、不抢焦点，直接写会话。开关在「设置 → 接收 → 自动接收文本消息」（`SettingsState.autoAcceptTextMessages`，默认 `true`，见 `receive_controller.onPrepareUpload`）。

| 开关 | 行为 |
|---|---|
| 开（默认） | `_recordTextMessage` → 回空文件表（204），发送端不进传输阶段 |
| 关 | 走普通接收页：用户点「接受」才 `_recordTextMessage` + 回 204；点「拒绝」回 409，会话里什么都不写 |

要点：

- **手动确认模式下不要在 `onPrepareUpload` 里就记消息**：那样点「拒绝」也会在会话里留一条，等于开关白关。记录挂在 `onAccept` 里。
- 接收页的文本分支原来只有「关闭」一个按钮，而它调的是 `onAccept`（关掉 = 收下）。要真的能拒收，就得给 `receive_page.dart` 的 `_Actions` 补「拒绝」——这是 fork 改上游 UI 的一处，别在同步上游时弄丢。
- 静默分支必须排在 `showFromTray()` **之前**，否则对方每发一句话都会把桌面端窗口抢到前台。
- 关掉开关后，Android 后台收到消息只会挂一个待确认的接收页，**不会发通知**（通知只由 `recordReceivedText` 触发）。这是当前实现的后果，不是刻意设计：手动确认模式等于连提醒一起关掉。真要补，得给会话加一个「待确认」状态，再把通知挂在 `pending` 上。

### 文本消息只写会话，不写接收历史

早期版本把收到的文本**同时**写进接收历史和会话，两处各有独立 id、各有独立删除入口。「接收」页 → 历史 → 删除历史记录只清 `ls_receive_history`，会话读的是 `ls_conversations`，于是删完打开聊天页一条没少——用户看到的是「删除没生效」。

现在只有一条归属：

| 存储 | 内容 | 删除入口 |
|---|---|---|
| `ls_conversations` | 文本 + 文件（双向） | 会话列表长按 |
| `ls_receive_history` | **只记文件**（有落盘路径、可打开/定位） | 接收页 → 历史 |

- `_recordTextMessage` 只调 `recordReceivedText`，不再发 `AddHistoryEntryAction`。
- `ReceiveHistoryService.init()` 顺手清掉老数据里 `isMessage == true` 的条目（一次性，写回一次）。文本本身在会话里还在，不会丢消息。
- `receive_history_page.dart` 里「点历史条目 → 用 `ReceivePage` 展示正文」的分支随之删除，历史条目只剩「打开文件 / 在文件夹中显示 / 详情 / 删除」。
- `ReceiveHistoryEntry.isMessage` 字段保留：dart_mappable 的旧数据要能解析，删字段会让老包启动时炸。

### 文件：两边都留，但删除联动

文件不像文本那样可以只留一处：接收历史要提供「打开文件 / 在文件夹中显示 / 大小与来源」，会话要提供「谁在什么时候发的」。所以两份都留，靠 **id 相同 + 删除联动** 保持一致。

- 接收文件的 `ReceiveHistoryEntry.id` 与 `ChatMessage.id` 同取协议里的 `fileId`（`AddHistoryEntryAction(entryId: fileId)` / `recordReceivedFile(messageId: fileId)`），精确匹配，不需要「别名 + 文件名 + 时间」那种近似。
- 删单条历史（`RemoveHistoryEntryAction`）→ `ReceiveHistoryService.deleteLinkedChatMessages([id])` → `DeleteChatMessagesAction`。
- 清空历史（`RemoveAllHistoryEntriesAction`）→ 把当前 30 条历史里所有 id 一起传下去。**历史之外更早的消息不动**：历史只留 30 条，没有条目就没有联动依据。
- 会话被删空（只剩这张卡）时整条会话移除，避免列表里留一个空白项；未读数按剩余接收消息数收敛，不让角标指向一条不存在的消息。
- 磁盘文件不受影响：删除的只是两个视图里的记录，和上游「删除历史记录」的语义一致（弹窗文案已写明）。
- 反向（删会话 → 清历史）**没有做**：接收历史是日志，删聊天不该顺手销毁文件清单。


## 系统通知（收到消息的提醒）

只提醒**文本消息**，且只在 App 不在前台时。收到文件本来就会弹接收确认页，再补一条通知是重复打扰；App 在前台时列表里的未读角标已经说明了新消息。

| 环节 | 位置 |
|---|---|
| 触发 | `conversation_recorder.dart` 的 `recordReceivedText` 末尾（`_notifyIncomingText`） |
| 要不要弹 | `ChatPresence.isForeground`，由 `main.dart` 的 `LifeCycleWatcher` 维护 |
| 发通知 | `ChatNotification.show` → `MainActivity.kt` 的 `showChatNotification` |
| 点击进会话 | `PendingIntent` 带 `localchat.chatPeer` → `onNewIntent` / 冷启动握手 → Dart 回调 push `ConversationPage` |
| 被关掉的提示 | 会话列表顶部 `_NotificationsOffBanner`（`conversations_page.dart`） |

要点：

- 渠道 `localchat_messages` 是 `IMPORTANCE_HIGH`。它和传输进度用的前台服务渠道（`localchat_foreground_service`，LOW、静音、不能横幅）是**两套**，不能合并：一个要尽量安静，一个必须吵起来。
- 同一个对端共用一封通知（id 由指纹哈希决定），后续消息追加进 `InboxStyle` 并累加未读数；列表最多 6 行，超出显示 `+N`。不这么做的话对方连发几句就会把通知栏刷满。
- 点通知即视为已读：原生侧清未读累计并 `cancel` 通知；手动进会话页也会 `clear`（`ConversationPage.initState`）。
- 冷启动那次点击**没有 `onNewIntent` 可走**（Activity 是被 `PendingIntent` 拉起来的）。Dart 首帧后调 `chatNotificationsReady`，原生在这时把攒下的点击回放。
- 横幅出现条件三选一：`areNotificationsEnabled() == false`（整个 App 被关，vivo 这类 ROM 常见）、渠道 `importance == NONE`、没给 `POST_NOTIFICATIONS`。点「去开启」先试 `Permission.notification.request()`，拿不到就跳系统渠道设置页。
- 没有引入 `flutter_local_notifications`：项目已经在 `MainActivity` 上有自建 MethodChannel（SAF、剪贴板都走它），而现成的 `flutter_foreground_task` 只提供前台服务通知（静音、不可横幅）。加一个依赖还要动 manifest 的 receiver，不划算。

### 提示音

系统通知覆盖不到三个场景：桌面端根本没有系统通知（托盘藏着时收消息零反馈）、文件接收请求从不发通知（直接弹接收页）、手机前台按设计不弹通知。这些地方补一声短音。

| 环节 | 位置 |
|---|---|
| 统一入口 | `util/native/notification_sound.dart`（`NotificationSound`） |
| 什么时候响 | `NotificationSoundGate`：600ms 合并窗口 + 按 `sessionId` 去重 |
| 收到文本 | `conversation_recorder.dart` 的 `recordReceivedText` 末尾 |
| 收到文件请求 | `receive_controller.dart` 的 `onPrepareUpload`，`push(ReceivePage)` 之前 |
| 自动接收落盘完成 | `receive_controller.dart` 的 `onFileUploadResult`，`error == null` 分支 |
| 音频资源 | `app/assets/audio/notify_message.wav`（玻璃双音，0.5s）、`notify_file.wav`（咚叮，0.42s） |
| 开关 | 设置 → 接收 → 提示音（`notificationSound`，默认开） |

要点：

- **手机后台绝不自播**：那条路径由系统通知渠道出声，两边都响就是「叮咚」两声。判断在 `playMessage` 里，条件是 `_isMobile && !ChatPresence.isForeground`。
- **文件按会话去重**：手动接受时「请求」响过一次，随后每个文件落盘还会再调一次 `playFile`，靠 `sessionId` 集合挡住；自动接收（quickSave）没有请求那一声，由落盘那次补上。
- **合并窗口必须大于音频时长**（600ms > 500ms）：否则对方连发两条会调用 `play()` 重新设置音源，第一声被截成半声。
- 音频上下文写在 `_audioContext()`：Android 用 `usage=notification` + `contentType=sonification` + `audioFocus=none`（默认 `usage=media` 走 STREAM_MUSIC，会**绕过静音和勿扰**）；iOS 用 `ambient`，静音键拨下时不响。
- 播放器常驻（`ReleaseMode.stop`）并在 `main.dart` 首帧后 `warmUp()`，否则第一声迟到 100~300ms。
- 依赖 `audioplayers`：Windows 走 Media Foundation、Linux 走 GStreamer（**deb/rpm 打包要声明 gstreamer 依赖**）、Android/iOS 走各自原生播放器。
- 音频后期：原始素材峰值只有 -8 dBFS（明显偏轻），已 +6 dB 归一到 -2 dBFS，并转单声道、裁剪尾部静音。

## 状态机

```
ChatMessageStatus:  pending ──成功──> sent
                       └────失败──> failed
接收侧恒为 received
```

去重靠 `message.id`：接收方向复用 `fileId`（重传天然幂等），发送方向复用源 `file.id` / 新 UUID。

**发文本必须把消息 id 交给 `startSession`（`fileIdsOverride: [messageId]`）**。少这一条时，`startSession` 会为 `FileDto` 另生成一个 uuid，上传事件按那个 id 又写一条「发送中」气泡 → **同一条消息两个气泡**（间隔一百多毫秒，接收端只收到一份）。2026-11-05 真机复现并修复：修复后手机 → Py Receiver 发一条 `dupfix-1125`，会话里只有 1 条 `sent`，其 id 与接收端日志里的 `fileId` 完全一致。历史数据里成对出现的旧气泡是修复前留下的，不会被自动清理。

## 上限与排序

- 每会话 `maxMessagesPerConversation = 500`，超出砍最旧消息，卡片保留。
- 全局 `maxConversations = 200`，超出按 `lastActivity` 倒序截断，**最久未活动的卡片直接消失**（不是折叠）。
- `unreadCount` 只统计接收方向；进入会话页由 `MarkConversationReadAction` 清零。

## 扩展点

| 想加 | 改哪里 |
|---|---|
| 图片/缩略图预览 | `ChatMessage` 加字段 + `file_message_card.dart` + `preview` 逻辑 |
| 消息重试 | `conversation_page.dart` 的 failed 气泡 + 复用 `sendTextMessage`（`messageId` 需换新） |
| 已读回执 | 需新协议：LocalChat 无此能力，只能在文本消息里塞约定字段 |
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
- Android 软键盘的「发送」键走 `performAction(send)`，与桌面一致。但 Android 上**框架收不到物理键盘的 Enter KeyEvent**（`FocusNode.onKeyEvent` 实测为空，IME 直接把它当 `\n` 提交），所以 `_handleEnter()` 在 Android 永远只被软键盘的发送键触发，物理键盘回车 = 换行。也因此「监听插入换行就撤回并发送」不可行：那时 Shift 已松开，Shift+Enter 会被误判成发送。
- 软键盘上没有换行键，换行入口挂在**长按发送按钮**上（`_handleSendButtonLongPress`，仅 Android）：短按发送、长按在光标处插 `\n`。注意 `IconButton` 的 `tooltip` 在移动端默认也是长按弹出，会抢同一个手势，所以 Android 上 `tooltip: null` 并外套 `Tooltip(triggerMode: manual)` 只为保住无障碍标签。
- 粘贴只在 **Windows / Android** 有原生实现（macOS / Linux / iOS 会走 `MissingPluginException` 分支，退化为普通文本粘贴）。
- Android 上粘贴依赖物理键盘的 Ctrl+V；软键盘长按弹出的系统「粘贴」走的是 `TextInputClient` 通道，不经过 `Shortcuts`。
- 剪贴板文件一次最多 100 个（Windows `kMaxFiles`）/ 20 个且单文件 ≤256MB（Android `MAX_CLIPBOARD_*`）：Android 是把字节读进内存再落盘，不设上限会 OOM。
- Windows 复制**文件夹**只会被跳过（`Directory.existsSync()` 判断），不展开递归。
