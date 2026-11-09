# L0 路由表

> 用法：先在这里定位 2-3 个文件再打开，不要一上来就全库搜索。
> 所有路径相对仓库根。带 `:行号` 的是「从这一行开始读」的建议锚点，会漂移，以符号名为准。

## 按意图路由

| 我要改… | 必读文件（按顺序） | 模块卡 | 改完验证 |
|---|---|---|---|
| 会话列表的卡片样式/排序/角标 | `app/lib/pages/conversations_page.dart` → `app/lib/provider/conversation_provider.dart` | [conversation](modules/conversation.md) | `flutter test test/unit/provider/conversation_provider_test.dart` |
| 两台设备同名了 / 想区分同名会话 | `app/lib/util/conversation/peer_label.dart`（`peerShortCode` / `peerNameCounts`）→ `app/lib/widget/chat/peer_title.dart`（`PeerTitleText`） | [conversation](modules/conversation.md#重名消歧标题后的指纹短码) | `flutter test test/unit/util/peer_label_test.dart`；手动：把 A 的别名改成 B 的名字，两个会话标题都应出现 `· XXXX` |
| 会话页气泡/输入栏 | `app/lib/pages/conversation_page.dart` → `app/lib/widget/chat/message_bubble.dart` | [conversation](modules/conversation.md) | `flutter analyze` |
| 会话栏什么时候出现卡片 | `app/lib/util/conversation/conversation_recorder.dart` → `conversation_provider.dart:48` | [conversation](modules/conversation.md#卡片生成条件) | 手动：双端互发一次文本 |
| 发文本消息 | `app/lib/util/conversation/conversation_sender.dart:106`（`sendTextMessage`）→ `app/lib/provider/network/send_provider.dart:681` | [conversation](modules/conversation.md) | 双端收发 |
| 发文件（含离线重试） | `app/lib/util/conversation/conversation_sender.dart`（`deliverFiles` → `_precomputeChecksums` → `_deliverWithRetry`）→ `send_provider.dart`（`startSession`） | [conversation](modules/conversation.md#发送阶段与超时结构) | 双端收发；大文件应依次看到「校验中 x%」→「等待对方接受…」→「发送中 x%」 |
| 发送卡住 / 一直转圈 | `app/lib/util/conversation/conversation_sender.dart`（`_precomputeChecksums` / 硬超时 / `_watchStalledUploads` / `_diagnoseTimeout`） | [conversation](modules/conversation.md#超时与看门狗) | 对端关机后点重发，窗口结束应给出「不可达」而不是笼统的「发送失败」 |
| 失败原因太笼统 / 想加一条失败文案 | `app/lib/util/conversation/send_failure.dart`（`SendFailure` / `failureForStatusCode` / `classifySendErrorText` / `describeSendFailure`）→ `app/assets/i18n/en.json` + `zh-CN.json` | [conversation](modules/conversation.md#失败原因分类) | `flutter test test/unit/util/send_failure_test.dart` |
| 想中止正在发送的消息 | `message_bubble.dart`（`onCancel`，转圈可点）→ `conversation_page.dart`（`canCancelTransfer`：右键 / 长按菜单的「取消传输」）→ `conversation_sender.dart`（`cancelChatMessage` + `_SendTicket`）→ 兜底 `chatSendWatchdogTimeout` | [conversation](modules/conversation.md#主动取消与界面兜底) | 手动：点重发后点转圈立刻停下；传输中的文件卡片右键也应有「取消传输」，传完的不应有 |
| 想删掉某一条消息 | `conversation_page.dart`（`_showMessageMenu` / `_deleteMessage`）→ `widget/chat/delete_record_dialog.dart`（确认框）→ `message_bubble.dart`（`onSecondaryTap` 右键 / `onLongPress` 长按）→ `conversation_provider.dart`（`DeleteChatMessagesAction`） | [conversation](modules/conversation.md#删除该条记录) | 手动：长按（或右键）任一气泡 → 「删除该条记录」→ 确认框点「取消」应什么都不删；确认后收到的文件还要看历史里同 id 条目是否一起消失 |
| 想在资源管理器里定位收到的文件 | `conversation_page.dart`（`canRevealInFolder` / `_revealInFolder`）→ `util/native/open_folder.dart`（`openFolder`） | [conversation](modules/conversation.md#打开文件所在位置) | 桌面端右键文件卡片 → 「打开文件所在位置」应在资源管理器里选中该文件；文本气泡不出现该项 |
| 收文本消息（静默接收 / 改成先确认） | `app/lib/provider/network/server/controller/receive_controller.dart`（`onPrepareUpload` 的文本分支 + `onAccept`）→ `settings_tab.dart`（「自动接收文本消息」） | [conversation](modules/conversation.md#接收文本静默还是先确认) | 关掉开关后用假对端发一条：应弹接收页，点「拒绝」会话里不留记录 |
| 收到文件的记录时机 | `receive_controller.dart:377`（`error == null` 分支） | [conversation](modules/conversation.md) | 传一个文件后看会话 |
| 会话持久化 / 迁移 | `app/lib/provider/persistence_provider.dart`（`ls_conversations`）→ `app/lib/util/shared_preferences/settings_migration.dart`（改名迁移） | — | `flutter test test/unit/util/shared_preferences/` |
| 侧边栏 / Tab 顺序 | `app/lib/pages/home_page.dart` → `app/lib/pages/home_page_controller.dart` | — | `flutter analyze` |
| 主题色 / 气泡配色 | `app/lib/config/theme.dart` → `app/lib/widget/chat/message_bubble.dart` | — | 见 [不变量](invariants.md#ui) |
| Windows 标题栏颜色不跟主题 | `app/lib/util/native/title_bar_theme.dart`（`TitleBarTheme`，挂在 `MaterialApp.builder`）→ `app/windows/runner/title_bar_ext.cpp`（`DwmSetWindowAttribute`） | — | `flutter test test/unit/util/title_bar_theme_test.dart`；手动：系统开深色、App 切浅色，标题栏应变浅 |
| 改自己的设备名称（接收页铅笔图标） | `app/lib/pages/tabs/receive_tab.dart`（`_editAlias`）→ `app/lib/widget/dialogs/device_name_dialog.dart` → `settingsProvider.setAlias` + `serverProvider.restartServerFromSettings` | [discovery](modules/discovery.md#改名的生效链) | 手动：接收页名字右边铅笔 → 改名 → 保存后名字应立刻变，设置页「设备名称」同步为同一个值 |
| 界面文案 | `app/assets/i18n/en.json` + `zh-CN.json` → `fvm dart run slang` | — | `flutter analyze` |
| 新增/修改一个设置项 | `app/lib/model/state/settings_state.dart`（加字段）→ `provider/settings_provider.dart`（init + setter）→ `provider/persistence_provider.dart`（key + getter/setter）→ `pages/tabs/settings_tab.dart`（`_BooleanEntry` / `_SettingsEntry`）→ 两份 i18n | — | `dart run build_runner build` + `dart run slang` + `flutter analyze` + `flutter test`（`mocks.mocks.dart` 会跟着重生成） |
| 设备发现 / 扫描 | `app/lib/provider/network/nearby_devices_provider.dart` → `scan_facade.dart` → `packages/core/src/multicast/` | [discovery](modules/discovery.md) | `python %TEMP%\lspeer\watch_mc.py 30`：发送页可见时每 8 s 三个报文 |
| 「附近设备」列表空 / 对端看不到 | `packages/localchat_isolates/lib/src/task/discovery/discovery.dart`（`_awaitDiscovery`）→ `app/lib/pages/tabs/send_tab.dart`（`_NearbyRefresh`） | [discovery](modules/discovery.md#三个已修的坑2026-11-05) | 同上 |
| HTTP 协议 / 传输 | `packages/core/src/http/` → `app/lib/provider/network/server/server_provider.dart` | — | `cargo test --features full` |
| 单条消息的状态机 | `app/lib/model/conversation/conversation.dart`（`ChatMessageStatus`） | [conversation](modules/conversation.md#状态机) | 单元测试 |
| 气泡上的进度条与发送阶段 | `app/lib/provider/conversation/chat_transfer_provider.dart`（`ChatTransferPhase`）→ `app/lib/widget/chat/message_bubble.dart`（`_SendProgressFooter`）→ `send_provider.dart`（`HttpUploadFileProgressEvent` 分支） | [conversation](modules/conversation.md#进度条) | `flutter test test/unit/provider/chat_transfer_test.dart` |

## 入口符号速查

| 符号 | 位置 | 作用 |
|---|---|---|
| `conversationProvider` | `provider/conversation_provider.dart` | 全部会话状态（Redux，唯一真相） |
| `AppendChatMessageAction` | 同上 | **唯一**能新建会话的 action |
| `sendTextMessage` | `util/conversation/conversation_sender.dart:106` | 会话页发文本（2 分钟重试窗口） |
| `deliverFiles` / `pickConversationFiles` | 同上 | 会话页发文件（只在握手阶段重试） |
| `describeSendFailure` / `failureForStatusCode` | `util/conversation/send_failure.dart` | 失败原因 → 气泡文案的唯一入口 |
| `recordReceivedText` / `recordReceivedFile` | `util/conversation/conversation_recorder.dart` | 接收侧写会话的唯一入口 |
| `HomeTab` | `pages/home_page.dart` | 枚举顺序 == `PageView.children` 顺序 |
| `ReceiveController` | `provider/network/server/controller/receive_controller.dart` | 服务端事件处理器（非路由） |

## fork 插入点

改这些文件前先读 `invariants.md#fork`。校验脚本会检查下表中的文件都存在且确实含 `[FORK]` 标记。

| 文件 | 插入内容 |
|---|---|
| `app/lib/main.dart` | `HomePage(initialTab:)` 默认 Tab |
| `app/lib/pages/home_page.dart` | `HomeTab` 枚举、PageView children、纯图标侧边栏 |
| `app/lib/pages/tabs/send_tab.dart` | `_NearbyRefresh`：发送页可见时每 8 s 重发一次多播通告（见 [discovery](modules/discovery.md)）；`_startConversation`：设备卡片上的「发起会话」（见 [conversation](modules/conversation.md)） |
| `app/lib/widget/list_tile/device_list_tile.dart` | `onChatTap`：卡片右侧「发起会话」按钮，与「设备详情」并排（没有指纹时不给） |
| `app/lib/provider/network/server/controller/receive_controller.dart` | 文本静默接收（受 `autoAcceptTextMessages` 设置控制）、落盘成功后写会话；文本**只**写会话，不进接收历史 |
| `app/lib/provider/receive_history_provider.dart` | `init()` 清掉老数据里 `isMessage == true` 的文本条目（文本改为只归会话，见 [conversation](modules/conversation.md)）；删条目的动作联动删掉会话里同 id 的文件卡片 |
| `app/lib/provider/conversation_provider.dart` | `DeleteChatMessagesAction`：按消息 id 批量删除（供接收历史联动），删空的会话一并移除 |
| `app/lib/provider/network/send_provider.dart` | Started / Finished / Failed 三处写会话；`sessionIdOverride` 参数；upload 事件的 `setPhase(uploading)` 与失败细分（`_settlePreRecorded`） |
| `app/lib/pages/receive_page.dart` | 文本消息的「接受 / 拒绝」两个按钮（上游只有「关闭」，等价于接受） |
| `app/lib/model/state/settings_state.dart` | `autoAcceptTextMessages`：文本消息是否静默接收（默认开，设置页可关） |
| `app/lib/provider/persistence_provider.dart` | `getConversations` / `setConversations`；`isAutoAcceptTextMessages`（默认 true） |
| `app/lib/util/shared_preferences/settings_migration.dart` | fork 新增的整个文件：`%APPDATA%\LocalSend` → `LocalChat` 的改名迁移（有单测） |
| `app/lib/util/conversation/conversation_recorder.dart` | 文件头注释即 fork 说明 |
| `app/lib/pages/conversation_page.dart` | 顶部说明；聊天页背景 / 输入栏取 `ChatPalette`；气泡菜单（复制 / 取消传输 / 打开文件所在位置 / 删除该条记录）与移动端长按入口；`device` 参数 + `_draftConversation()`：从发送页发起会话时的草稿会话 |
| `app/lib/widget/chat/delete_record_dialog.dart` | 整个文件为 fork 新增（删单条记录前的确认卡片，按文本 / 收到文件 / 发出文件分文案） |
| `app/lib/config/theme.dart` | `kSeedColor`（Local Chat 种子色 `#1E90FF`，上游是 `Colors.teal`）、`extensions: [chatPaletteFor(...)]`：把聊天配色挂进 ThemeData |
| `app/lib/config/chat_palette.dart` | 整个文件为 fork 新增（聊天页配色 `ChatPalette`，Local Chat + 浅色 → `#EBEBEB` 底 / `#FFFFFF` 对方气泡） |
| `app/lib/widget/chat/message_bubble.dart` | 固定气泡色常量；对方气泡取 `ChatPalette.incomingBubble` |
| `app/lib/widget/chat/top_toast.dart` | 顶部 Toast 说明 |
| `app/lib/main.dart` | `MaterialApp.builder` 挂 `TitleBarTheme`：主题变化时把颜色推给 Windows 标题栏 |
| `app/lib/widget/chat/file_message_card.dart` | 发出方向前景色 |
| `app/lib/pages/conversations_page.dart` | `_NotificationsOffBanner`：通知不可用时的提示条；标题改用 `PeerTitleText`，仅在重名时带指纹短码 |
| `app/lib/util/conversation/peer_label.dart` | 整个文件为 fork 新增（重名消歧：指纹短码与名字分布统计） |
| `app/lib/widget/chat/peer_title.dart` | 整个文件为 fork 新增（会话标题组件，列表与聊天页共用） |
| `app/lib/pages/tabs/receive_tab.dart` | 名字右边的铅笔图标 + `_editAlias`：改完立刻重启接收服务，让新名字马上生效 |
| `app/lib/widget/dialogs/device_name_dialog.dart` | 整个文件为 fork 新增（接收页改设备名称的输入框，取消返回 null） |
| `app/lib/util/conversation/chat_presence.dart` | 整个文件为 fork 新增（前台判断，决定要不要弹通知） |
| `app/lib/util/native/chat_notification.dart` | 整个文件为 fork 新增（通知发送 / 状态查询 / 点击回传） |
| `app/windows/runner/flutter_window.cpp` | `RegisterClipboardChannel` / `RegisterTitleBarChannel` 注册（后者把主窗口 HWND 交给通道） |
| `app/windows/runner/CMakeLists.txt` | 新的 runner 源文件（`title_bar_ext.cpp` 等）+ `windowscodecs` / `shell32` 链接（`dwmapi` 已在上游链接） |
| `app/android/.../MainActivity.kt` | `getClipboardImage` / `getClipboardFiles` 分支 + `readClipboardImage()` / `readClipboardFiles()` |
| `app/lib/util/conversation/clipboard_image.dart` | 整个文件为 fork 新增（剪贴板文件与图片读取） |
| `app/lib/util/conversation/conversation_media_picker.dart` | 整个文件为 fork 新增（会话页「相册」入口，wechat_assets_picker 多选） |
| `app/lib/widget/chat/drop_confirm_dialog.dart` | 整个文件为 fork 新增（拖拽/粘贴共用确认卡片） |
| `app/lib/model/conversation/conversation.dart` | `copyWith(clearError)`：`errorMessage` 需要能被置空（重发） |
| `app/lib/util/conversation/conversation_sender.dart` | `sendTextMessage(messageIdOverride)` / `deliverFiles(messageIds)` / `_precomputeChecksums`（校验和移出重试窗口，可取消）/ `retryChatMessage` / `cancelChatMessage` / `_diagnoseTimeout` / `_SendTicket` |
| `app/lib/util/conversation/send_failure.dart` | 整个文件为 fork 新增（失败原因 18 类 + 三档分类器 + 文案；`conversation_sender` 只 export） |
| `app/lib/provider/conversation/chat_transfer_provider.dart` | 整个文件为 fork 新增（上传进度与发送阶段旁路，每条消息一个 `ValueNotifier`） |
| `app/lib/provider/network/send_provider.dart`（进度） | `HttpUploadFileProgressEvent` 分支里的 `chatTransferProvider.report` |

## fork 独占文件（上游不存在）

```
app/lib/model/conversation/conversation.dart          266 行
app/lib/util/conversation/conversation_recorder.dart  209 行
app/lib/util/conversation/conversation_sender.dart   1126 行
app/lib/util/conversation/send_failure.dart           236 行（失败原因 18 类 + 三档分类器 + 文案）
app/lib/util/conversation/clipboard_image.dart         199 行（图片 + 文件列表两条通道）
app/lib/util/conversation/conversation_media_picker.dart  77 行（会话页相册多选）
app/lib/provider/conversation_provider.dart           229 行
app/lib/provider/conversation/chat_transfer_provider.dart  121 行（上传进度与发送阶段旁路）
app/lib/pages/conversations_page.dart                 173 行
app/lib/config/chat_palette.dart                      107 行（聊天页配色 ThemeExtension）
app/lib/pages/conversation_page.dart                 1621 行
app/lib/widget/chat/message_bubble.dart               374 行
app/lib/widget/chat/file_message_card.dart            198 行
app/lib/widget/chat/top_toast.dart                    168 行
app/lib/util/native/title_bar_theme.dart              117 行（标题栏跟随 App 主题，含 120ms debounce）
app/lib/widget/chat/drop_confirm_dialog.dart          128 行
app/windows/runner/clipboard_image_win.cpp            217 行（纯 Win32/WIC，可单独编译验证）
app/windows/runner/clipboard_files_win.cpp            74 行（CF_HDROP → 路径，shellapi）
app/windows/runner/clipboard_ext.cpp                   67 行
app/windows/runner/title_bar_ext.cpp                 114 行（DWM：caption / text / border 三个属性）
app/windows/runner/title_bar_ext.h                    16 行
app/test/unit/provider/conversation_provider_test.dart 368 行（16 用例）
app/test/unit/provider/chat_transfer_test.dart         127 行（11 用例）
app/test/unit/util/send_failure_test.dart             107 行（15 用例，含分类优先级）
app/test/unit/util/clipboard_image_test.dart           75 行（9 用例）
app/test/unit/config/chat_palette_test.dart            41 行（3 用例，锁死 #EBEBEB / #FFFFFF 只在 Local Chat 浅色生效）
app/test/unit/util/title_bar_theme_test.dart           44 行（3 用例：浅色 / 深色 / OLED 纯黑底的颜色映射）
```

合计约 1,786 行新代码 + 上游文件内约 250 行钩子；相对 `v1.18.2` 全量为 28 文件、+2,763 / −101（含生成物）。
