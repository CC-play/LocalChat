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
| `app/lib/pages/conversation_page.dart` | 详情 + 底部输入栏（[附件][输入][发送]）+ 文字选区/右键「复制」菜单 |
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

## 文字选区 / 复制菜单

`conversation_page.dart` 用 `SelectionArea` 让气泡文字可选，但**菜单是自己弹的**，不走框架工具条：

- 框架的 `SelectableRegion._handleMouseDragEnd` 在 desktop（windows/macOS/linux）分支里明确写了 *"The selection overlay is not shown on desktop platforms after a drag"*，所以拖选结束后不会出现任何菜单——想要「选中即弹」必须自己接管。
- 触发点：`Listener.onPointerUp` → `_autoShowMenu()`；`MessageBubble.onSecondaryTap`（右键）→ 同一条 `_showCopyMenu()`。
- **坑：`addPostFrameCallback` 不会调度帧**（源码里只是 `_postFrameCallbacks.add`）。桌面端拖选结束后没有重绘，回调会一直挂着，表现就是「选中了但菜单永远不来」。必须用 `WidgetsBinding.instance.endOfFrame`（idle 时它会 `scheduleFrame()`），再补几次 16ms 短重试兜住 pending 选区。
- 用 `_selectionTouched` 区分「本次按下产生了新选区」（拖选/双击选词，要弹）与「点空白处取消选区」（pointer up 前选区还是旧的，不能弹）。这个判断必须放在 `await endOfFrame` **之后**：双击选词发生在手势竞技场裁决阶段，比 `onPointerUp` 更晚。
- 菜单框显式描 `colorScheme.outlineVariant` 边框——`showMenu` 默认只有阴影，浅色背景下几乎看不到边缘。

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
cd app && flutter test test/unit/provider/conversation_provider_test.dart   # 12 个用例
NO_PROXY=localhost,127.0.0.1,::1 flutter test                              # 全量（HTTP_PROXY 会拦 localhost WebSocket）
```

## 已知限制

- `peerPort` 为空的旧会话无法主动发消息（`resolveConversationTarget` 返回 null，`https` 只能猜 false）。
- 对端改名后卡片名会更新，但**无指纹的对端**改名会分裂成新卡片（伪键 `alias:<别名>`）。
- 文本消息上限 4000 字符（`maxTextMessageLength`）。
