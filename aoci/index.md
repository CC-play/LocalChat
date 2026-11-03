# L0 路由表

> 用法：先在这里定位 2-3 个文件再打开，不要一上来就全库搜索。
> 所有路径相对仓库根。带 `:行号` 的是「从这一行开始读」的建议锚点，会漂移，以符号名为准。

## 按意图路由

| 我要改… | 必读文件（按顺序） | 模块卡 | 改完验证 |
|---|---|---|---|
| 会话列表的卡片样式/排序/角标 | `app/lib/pages/conversations_page.dart` → `app/lib/provider/conversation_provider.dart` | [conversation](modules/conversation.md) | `flutter test test/unit/provider/conversation_provider_test.dart` |
| 会话页气泡/输入栏 | `app/lib/pages/conversation_page.dart` → `app/lib/widget/chat/message_bubble.dart` | [conversation](modules/conversation.md) | `flutter analyze` |
| 会话栏什么时候出现卡片 | `app/lib/util/conversation/conversation_recorder.dart` → `conversation_provider.dart:48` | [conversation](modules/conversation.md#卡片生成条件) | 手动：双端互发一次文本 |
| 发文本消息 | `app/lib/util/conversation/conversation_sender.dart` → `app/lib/provider/network/send_provider.dart:647` | [conversation](modules/conversation.md) | 双端收发 |
| 收文本消息（静默接收） | `app/lib/provider/network/server/controller/receive_controller.dart:168` | [conversation](modules/conversation.md) | 双端收发 |
| 收到文件的记录时机 | `receive_controller.dart:377`（`error == null` 分支） | [conversation](modules/conversation.md) | 传一个文件后看会话 |
| 会话持久化 / 迁移 | `app/lib/provider/persistence_provider.dart:60`（`ls_conversations`） | — | `flutter test` |
| 侧边栏 / Tab 顺序 | `app/lib/pages/home_page.dart` → `app/lib/pages/home_page_controller.dart` | — | `flutter analyze` |
| 主题色 / 气泡配色 | `app/lib/config/theme.dart` → `app/lib/widget/chat/message_bubble.dart` | — | 见 [不变量](invariants.md#ui) |
| 界面文案 | `app/assets/i18n/en.json` + `zh-CN.json` → `fvm dart run slang` | — | `flutter analyze` |
| 设备发现 / 扫描 | `app/lib/provider/network/nearby_devices_provider.dart` → `scan_facade.dart` → `packages/core/src/multicast/` | — | 见 `AGENTS.md` |
| HTTP 协议 / 传输 | `packages/core/src/http/` → `app/lib/provider/network/server/server_provider.dart` | — | `cargo test --features full` |
| 单条消息的状态机 | `app/lib/model/conversation/conversation.dart`（`ChatMessageStatus`） | [conversation](modules/conversation.md#状态机) | 单元测试 |

## 入口符号速查

| 符号 | 位置 | 作用 |
|---|---|---|
| `conversationProvider` | `provider/conversation_provider.dart` | 全部会话状态（Redux，唯一真相） |
| `AppendChatMessageAction` | 同上 | **唯一**能新建会话的 action |
| `sendTextMessage` | `util/conversation/conversation_sender.dart:87` | 会话页发文本 |
| `recordReceivedText` / `recordReceivedFile` | `util/conversation/conversation_recorder.dart` | 接收侧写会话的唯一入口 |
| `HomeTab` | `pages/home_page.dart` | 枚举顺序 == `PageView.children` 顺序 |
| `ReceiveController` | `provider/network/server/controller/receive_controller.dart` | 服务端事件处理器（非路由） |

## fork 插入点

改这些文件前先读 `invariants.md#fork`。校验脚本会检查下表中的文件都存在且确实含 `[FORK]` 标记。

| 文件 | 插入内容 |
|---|---|
| `app/lib/main.dart` | `HomePage(initialTab:)` 默认 Tab |
| `app/lib/pages/home_page.dart` | `HomeTab` 枚举、PageView children、纯图标侧边栏 |
| `app/lib/provider/network/server/controller/receive_controller.dart` | 文本静默接收、落盘成功后写会话 |
| `app/lib/provider/network/send_provider.dart` | Started / Finished / Failed 三处写会话；`sessionIdOverride` 参数 |
| `app/lib/provider/persistence_provider.dart` | `getConversations` / `setConversations` |
| `app/lib/util/conversation/conversation_recorder.dart` | 文件头注释即 fork 说明 |
| `app/lib/pages/conversation_page.dart` | 顶部说明 |
| `app/lib/widget/chat/message_bubble.dart` | 固定气泡色常量 |
| `app/lib/widget/chat/top_toast.dart` | 顶部 Toast 说明 |
| `app/lib/widget/chat/file_message_card.dart` | 发出方向前景色 |

## fork 独占文件（上游不存在）

```
app/lib/model/conversation/conversation.dart          264 行
app/lib/util/conversation/conversation_recorder.dart  200 行
app/lib/util/conversation/conversation_sender.dart    255 行
app/lib/provider/conversation_provider.dart           186 行
app/lib/pages/conversations_page.dart                 173 行
app/lib/pages/conversation_page.dart                  336 行
app/lib/widget/chat/message_bubble.dart               128 行
app/lib/widget/chat/file_message_card.dart             76 行
app/lib/widget/chat/top_toast.dart                    168 行
app/test/unit/provider/conversation_provider_test.dart 282 行（12 用例）
```

合计约 1,786 行新代码 + 上游文件内约 250 行钩子；相对 `v1.18.2` 全量为 28 文件、+2,763 / −101（含生成物）。
