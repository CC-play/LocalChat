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
| 聊天页背景 / 对方气泡 / 输入栏一律取 `ChatPalette.of(context)`（`config/chat_palette.dart`），**不要**改 `ColorScheme.surface` | 改 surface 是全局的，会把设置页、发送页、对话框一起染灰 |
| Local Chat 主题的种子色只在 `config/theme.dart` 的 `kSeedColor` 改（`#1E90FF`），不要在别处再写死 `Colors.teal` | `localchat` 走 null 分支跟随 `defaultColorScheme`，写死第二处就会出现两套配色 |

## 为什么不做符号索引

1. 66% 的行是生成物（119k / 185k），全量符号表会把 codegen 桩当成真实调用点。
2. Dart↔Rust 靠 FRB 生成的胶水连接（16.9k 行），索引工具无法还原「Dart `rust_api.x()` ↔ `packages/core/src/` 哪个模块」的映射，产出的边大多是假的。
3. 上游仍在活跃演进（本 fork 常态落后 `origin/main` 数百提交），派生数据以周为单位腐烂；而「去哪读、不能碰什么」这类判断不会因上游提交而失效。
