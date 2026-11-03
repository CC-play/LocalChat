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
| `app/lib/util/conversation/conversation_sender.dart` | 发送侧：`resolveConversationTarget` / `sendTextMessage` / `sendFilesToConversation` |
| `app/lib/pages/conversations_page.dart` | 列表 + 空态 + 全清 + 长按删除 |
| `app/lib/pages/conversation_page.dart` | 详情 + 底部输入栏（[附件][输入][发送]） |
| `app/lib/widget/chat/message_bubble.dart` | 文本气泡、头像、固定发出色 |
| `app/lib/widget/chat/file_message_card.dart` | 文件气泡 |
| `app/lib/widget/chat/top_toast.dart` | 顶部 Toast（替代 SnackBar） |

## 卡片生成条件

一张卡片 = 一个 `Conversation` 对象。**没有"新建空会话"入口**，卡片只能是「消息被成功追加」的副产物。三个前提缺一不可（`conversation_provider.dart:48-56`）：

1. 走 `AppendChatMessageAction`；
2. `peerFingerprint` 非空（`peerKeyOf` 优先设备指纹，退化 `alias:<别名>`）；
3. 该 `message.id` 尚未存在于该会话（重复即只更新，不新增）。

五个实际触发点：收到文本（自动接收）、收到文件且落盘成功（`error == null && desiredName != null`）、自己发文本（先写"发送中"）、自己发文件（Started 事件，或被拒/忙/断网时补一条失败）、Started 丢失时 `markSentFile` 兜底补插。

**推论**：发送失败也会留卡片（末条 `failed`，列表显示红点）；接收被拒/接收失败不留卡片；从普通「发送」Tab 传文件也会刷新卡片（钩子在全局上传事件里，不区分入口）。

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
