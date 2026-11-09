# L2 不变量

> 只写「违反了会出事」的规则，每条给出**后果**。这里不是风格指南。

## 生成物

| 约束 | 违反后果 |
|---|---|
| `app/lib/gen/`、`*.mapper.dart`、`*.g.dart`、`*.mocks.dart` 手改无效 | 下次 codegen 全量覆盖，改动静默丢失 |
| 改了 `PersistenceService` 的接口，必须重跑 `fvm dart run build_runner build` | `MockPersistenceService` 缺实现 → 测试编译失败 |
| i18n 用 `fvm dart run slang`（**不是** build_runner，`build.yaml` 里 `slang_build_runner: enabled: false`） | 生成空实现，文案全部显示 key |
| 一次 slang 生成会改动 60+ 个 `strings_*.g.dart`，属正常 | 误以为是无关改动而 revert → 文案缺失 |
| CI 在 format 前删掉 `lib/gen`，生成物不参与格式检查 | 用 80 列工具重排生成物 = 纯噪音 diff |
| 改 Rust API 签名后跑 `flutter_rust_bridge_codegen generate`（在 `packages/localchat_isolates/`） | Dart 侧调用参数错位，运行期崩溃而非编译期 |

## 构建

| 约束 | 违反后果 |
|---|---|
| `packages/core` 一律 `--features full` 构建/测试 | 裸 `cargo check` 会因 feature 门控直接失败（模块无条件声明、依赖可选） |
| Windows 构建前把 VS18 的 `CMake\bin`、`Ninja` 前置到 PATH，并 `export CL="/source-charset:utf-8"` | PATH 里的 cmake 是坏的 venv shim（ModuleNotFoundError）；中文插件源码触发 C4819 被 `/WX` 升级为错误 |
| `app/windows/localchat_msix_helper.msix` 被 gitignore，需手工生成 | 干净检出后 Windows install 步骤失败 |
| 测启动存活前必须先关掉旧实例 | LocalChat 有单实例机制，第二个实例发 `/show` 后 `exit 0`，会误判为崩溃 |
| 本机用系统 Flutter 3.44.0（`fvm` 未装，`.fvmrc` 要求 3.41.9，`pubspec` 约束 `^3.41.0`） | 装 fvm 后行为可能变化，不要假设两端等价 |

## 状态管理

| 约束 | 违反后果 |
|---|---|
| 状态只能经 Redux action 改（`ref.redux(x).dispatchAsync(Action())`） | 直接改 state 会跳过持久化，重启丢数据 |
| `HomeTab` 枚举顺序 **必须**等于 `home_page.dart` 里 `PageView.children` 顺序 | Tab 与页面错位（点会话进发送页），且不报错 |
| 会话的唯一写入口是 `AppendChatMessageAction` | 绕过它插入会话 → 不走 `setConversations`，重启消失 |
| 会话记录失败必须被吞掉并记日志（`_appendSafely`） | 聊天存储异常会连累文件收发主流程 |
| 会话**不复用** `receiveHistory`（全局只留 30 条、仅接收方向） | 会话被截断到 30 条，且没有发出记录 |

## 传输协议

| 约束 | 违反后果 |
|---|---|
| LocalSend 协议没有聊天协议：一条消息 = 单文件 `FileType.text`，正文在 `FileDto.preview` | 自造端点 → 无法与官方客户端互通 |
| 接收端识别文本后 `acceptFileRequest({})` 返回空文件表 | 传了文件表 → 落盘 0 字节垃圾文件 |
| 文本消息判定必须排在 `showFromTray()` **之前** | 对方每说一句都抢走窗口焦点 |
| 消息 ID 复用 `fileId` / 源 `file.id` | 重传、重试会产生重复气泡 |

## 发送流程

| 约束 | 违反后果 |
|---|---|
| 校验和必须在重试窗口**之外**预计算（`_precomputeChecksums` → `checksumCache`），不要让 `startSession` 里的 `calculateFileHash` 落在 `.timeout()` 下面 | 30 GiB 在 dev 构建下算 7.4 分钟 > 130 秒窗口，`prepare-upload` 一次都发不出去，气泡报「发送失败」而对端没收到任何请求 |
| 气泡的 UI 兜底（`chatSendWatchdogTimeout`）在 `ChatTransferPhase.hashing` 阶段必须停止累加，批量发送要先把整批标 `hashing` | 大文件会被自己的看门狗判死；排在队尾、还没轮到算哈希的文件会停在旧阶段被误杀 |
| 失败必须经 `describeSendFailure` 写进 `ChatMessage.errorMessage`，不能只改 `status` | 气泡退回那句笼统的「发送失败」，18 类分类等于没做 |
| `SendFailure` 的定义只放 `util/conversation/send_failure.dart`（`conversation_sender` 只 export） | `send_provider` 需要这套分类，定义留在 sender 里会形成循环依赖 |
| 传输中的文件取消走 `cancelChatMessage`（整批 + 哈希令牌 + `closeSession`），不要在菜单里另写一套 | 只改气泡状态、不停真请求，会留下「取消了一条、其余几条还在后台上传」和读盘继续跑 |

## fork

| 约束 | 违反后果 |
|---|---|
| 上游文件里的改动一律加 `[FORK]` 注释标记 | 下次 rebase v1.19/v1.20 时分不清哪些是我们的 |
| 粘贴上游新代码时，先删旧钩子再重放（参考 `send_provider` 的 `updateSession` → `setTransferStatus` 重构） | 钩子引用了被删的 API，编译失败 |
| 生成物（gen/、mapper、mocks、plugin registrant、pubspec.lock）不单独提交，跟着 codegen 一起进 | 手动改的生成物与源文件不一致 |
| 全部 `[FORK]` 插入点清单见 [index.md#fork-插入点](index.md#fork-插入点) | 手工维护清单，漏了脚本会报警 |

## UI

| 约束 | 违反后果 |
|---|---|
| 发出气泡固定 `#4C98FF` + **白色前景**（`kOutgoingBubbleColor` / `kOnOutgoingBubbleColor`），不要用 `colorScheme.onPrimary` | 深色 M3 下 onPrimary 是深蓝，压浅蓝不可读 |
| "你"头像**跟随**主题色，与气泡不同色是**有意为之**，不要"顺手统一" | 用户明确要求回退过一次 |
| 失败气泡不换 `errorContainer` 底色，改用左侧 `Icons.error` | 底色会盖掉白字，文件卡片文字消失 |
| 聊天页提示用 `TopToast`，不要 `SnackBar` | SnackBar 只能贴底，挡住输入栏 |
| Windows 标题栏颜色由 `TitleBarTheme`（`MaterialApp.builder`）从 `ColorScheme` 推给 DWM，纯黑/纯白之类的颜色不要在原生侧写死 | DWM 只认系统深浅色，系统深 + App 浅时标题栏会一直是黑的 |
| 输入条只有一个右侧按钮：空输入 = 附件入口（桌面 `folder_outlined` 直接选文件、移动端 `add` 展开相册/文件面板），有文字 = 发送。不要再加回形针等第二个按钮 | 用户明确要求把两个入口合成一个，空态占位不要并排摆两个图标 |
| 聊天页背景 / 对方气泡 / 输入栏一律取 `ChatPalette.of(context)`（`config/chat_palette.dart`），**不要**改 `ColorScheme.surface` | 改 surface 是全局的，会把设置页、发送页、对话框一起染灰 |
| 输入框与附件面板**不描边**。输入框必须同时覆盖 `border` / `enabledBorder` / `focusedBorder` 为 `BorderSide.none` | 主题 `inputDecorationTheme` 给后两者设了 `secondaryContainer` 描边，只改 `border` 仍会画出边框 |
| 输入栏顶部 `outlineVariant` 0.5px 细线是**唯一**的区分手段（`localchat` 浅色下输入栏与消息区同色），不要顺手删 | 删掉后消息列表直接贴住输入区，没有视觉断点 |
| 提示音只在「手机前台 / 桌面端」自播；手机后台必须留给系统通知渠道 | 两条路径同时出声，用户听到「叮咚」两声 |
| 提示音的合并窗口（600ms）必须大于音频时长（500ms） | 连发两条时 `play()` 重设音源，第一声被截成半声 |
| 音频资源统一单声道 44.1kHz 16-bit WAV、峰值约 -2 dBFS | 原始素材 -8 dBFS 在各平台都明显偏轻；多声道/异采样率会让 GStreamer 与 Media Foundation 行为不一致 |
| Local Chat 主题的种子色只在 `config/theme.dart` 的 `kSeedColor` 改（`#1E90FF`），不要在别处再写死 `Colors.teal` | `localchat` 走 null 分支跟随 `defaultColorScheme`，写死第二处就会出现两套配色 |

## 为什么不做符号索引

1. 66% 的行是生成物（119k / 185k），全量符号表会把 codegen 桩当成真实调用点。
2. Dart↔Rust 靠 FRB 生成的胶水连接（16.9k 行），索引工具无法还原「Dart `rust_api.x()` ↔ `packages/core/src/` 哪个模块」的映射，产出的边大多是假的。
3. 上游仍在活跃演进（本 fork 常态落后 `origin/main` 数百提交），派生数据以周为单位腐烂；而「去哪读、不能碰什么」这类判断不会因上游提交而失效。
