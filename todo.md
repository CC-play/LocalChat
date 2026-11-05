# Android 端 TODO

> 目标：让 fork 的会话/聊天功能在 Android 上跑通（与 Windows 端互通）。
>
> 当前状态（2026-11-03 23:30 复查）：
> - **Android 端已能构建、安装、运行**：APK 89.6 MB，模拟器 Pixel_8（API 36 / x86_64）实测启动正常。
> - 会话列表、会话页、输入条、发送中倒计时、失败红色感叹号、接收文本静默落库 —— 均已在模拟器上截图确认。
> - **环境坑已全部趟平并记录在 §0**（JDK 25、CMake、Gradle 发行包、Maven 镜像、ABI、Kotlin 增量缓存）。
> - 未验证项集中在需要真机 / 真实剪贴板 / 同网段对端的地方，见 §3 的 `⬜ 未验证`。
> - Windows 端已跑通：会话 Tab、文本/文件收发、2 分钟离线重试、拖拽、Ctrl+V 粘贴、回车语义。

---

## 0. 环境准备（已全部完成）

| 组件 | 要求 | 现状（2026-11-03 23:00） |
|---|---|---|
| `compileSdkVersion` | 36 | ✅ `platforms/android-36` 已装 |
| `targetSdkVersion` | 37 | ✅ `android-37.0`（原有） |
| NDK | `28.2.13676358` | ✅ 已装（~1.9 GB，AGP 会硬校验版本号） |
| build-tools | 36.0.0 | ✅ 原有 |
| CMake | **3.22.1（AGP 必需）** | ✅ 已装 —— 见 §0.3，**这是最隐蔽的一个坑** |
| cmdline-tools | sdkmanager | ✅ 12.0，装在 `Sdk\cmdline-tools\latest` |
| JDK | 17–21（Gradle 8.13 不支持 25） | ✅ 用 `~/.jdks/jbr-21.0.11`，见 §0.2 |
| Rust Android target | x86_64 + arm 两个 | ✅ 三个都装了 |
| 设备 | 真机或模拟器 | ✅ AVD `Pixel_8` |

### 0.1 装 cmdline-tools / platform / NDK

Google 直连会间歇 429，**cmdline-tools 走腾讯镜像更快**（146 MB / 5 秒）：

```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
Invoke-WebRequest -Uri https://mirrors.cloud.tencent.com/AndroidSDK/commandlinetools-win-11076708_latest.zip -OutFile "$env:TEMP\cmdtools.zip"
Expand-Archive "$env:TEMP\cmdtools.zip" "$env:TEMP\cmdtools" -Force
New-Item -ItemType Directory -Force "$sdk\cmdline-tools\latest" | Out-Null
Copy-Item "$env:TEMP\cmdtools\cmdline-tools\*" "$sdk\cmdline-tools\latest\" -Recurse -Force

& "$sdk\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root="$sdk" `
    "platforms;android-36" "ndk;28.2.13676358" "cmake;3.22.1"
```

- [x] `Sdk\platforms\android-36\android.jar` 存在
- [x] `Sdk\ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin\clang.exe` 存在
- [x] `Sdk\cmake\3.22.1\bin\{cmake,ninja}.exe` 存在
- 注：`sdkmanager` 会刷一串 `package.xml parsing problem` 警告（本机有 API 37 预览包，schema v4），不影响安装。

### 0.2 JDK：**必须显式指定，否则构建直接失败**

Flutter 会自动选中 Android Studio 自带的 JBR，本机那个是 **Java 25**（class 文件 major 69），
Gradle 8.13 读不了，报 `BUG! exception in phase 'semantic analysis' ... Unsupported class file major version 69`。

```powershell
flutter config --jdk-dir "C:\Users\94184\.jdks\jbr-21.0.11"
```

- [x] `app\android\gradlew.bat --version` 显示 `Launcher JVM: 21.x`
- 教训：报那个错时不要去改 Gradle 版本，先确认 Flutter 用的是哪个 JDK。

### 0.3 CMake：PATH 上的 pip 版 cmake 会顶掉 AGP 的

首次构建 37 分钟后倒在 `:app:configureCMakeDebug[arm64-v8a]`，原因是 AGP 找到了
`...\Python\RunCode\.venv\Scripts\cmake.exe`（pip 装的），不是 SDK 的 CMake。
已在 `app\android\local.properties`（该文件被 gitignore）显式指定：

```properties
cmake.dir=C\:\\Users\\94184\\AppData\\Local\\Android\\Sdk\\cmake\\3.22.1
```

- [x] `configureCMakeDebug` 通过
- 注：这个属性是本地专用，别写进仓库。

### 0.4 Gradle 发行包与 Maven 镜像（本机网络专用，写在 `~/.gradle`）

两个问题都在 `~/.gradle` 里解决，**不改仓库文件**：

1. **wrapper 下载超时**（`services.gradle.org` 直连 Connection timed out）。
   本机 `~/.gradle/wrapper/dists/gradle-8.13-all` 下已有一份完整发行版，但 hash 目录与
   `distributionUrl` 对不上。用目录联接把已有的接过去，并补 `.ok` 标记：

   ```powershell
   $base="$env:USERPROFILE\.gradle\wrapper\dists\gradle-8.13-all"
   New-Item -ItemType Junction -Path "$base\54h0s9kvb6g2sinako7ub77ku\gradle-8.13" `
       -Target "$base\bjf2jc8io67a4o2cq7ctduuqp\gradle-8.13"
   New-Item -ItemType File -Path "$base\54h0s9kvb6g2sinako7ub77ku\gradle-8.13-all.zip.ok" -Force
   ```

2. **`maven.google.com` 不可达**（本地代理 502，直连超时），Gradle 会卡到十几分钟不动。
   `~/.gradle/init.gradle` 把 `google()` / `plugins.gradle.org` 的 URL 重写到阿里云镜像。

   > ⚠️ 只重写 URL，**不要 `repositories.maven{}` 新增仓库**：Flutter 用
   > `RepositoriesMode.PREFER_SETTINGS`，注入项目级仓库会直接报
   > `repository 'maven' was added by settings file`。

3. **Kotlin 增量缓存跨盘失败**：pub 包在 C:、项目在 D:，Kotlin 增量缓存做相对路径时抛
   `this and base files have different roots`，每次构建多花好几分钟。
   `~/.gradle/gradle.properties` 里 `kotlin.incremental=false`。

### 0.5 Rust target

`packages/localchat_isolates/rust-toolchain.toml` 锁了 1.97.1 并声明了三个 Android target，
rustup 进入该目录会自动装；预装一份可以避免首次构建把网络问题误判成代码问题。

```bash
rustup target add x86_64-linux-android aarch64-linux-android armv7-linux-androideabi
```

- [x] `rustup target list --installed` 三个都在

### 0.6 模拟器

```powershell
Start-Process -FilePath "$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe" `
    -ArgumentList '-avd','Pixel_8','-no-snapshot-load','-no-audio','-no-boot-anim','-gpu','swiftshader_indirect'
```

- [x] `adb devices` 显示 `emulator-5554 device`
- [x] WHPX 可用（`emulator -accel-check` 返回 0）
- ⚠️ 两个踩过的坑：
  - **不要把 emulator 的输出接进 `| Select-Object -First N`**：管道被提前关闭会把模拟器一起带走（表现为进程秒退、退出码 0）。
  - 后台任务方式启动会卡在 shell 起来的那一步（只有 3 行日志、没有 qemu 子进程），用 `Start-Process` 才正常。

### 0.7 `flutter test` 会被 `http_proxy` 打死

本机环境里带着 `http_proxy=http://127.0.0.1:12815`（宿主的沙箱代理）。Dart 的 `HttpClient`
认这个变量，于是 `flutter test` 连 `flutter_tester` 的本地 WebSocket 也走代理，报：

```
Unable to connect to flutter_tester process:
WebSocketException: Invalid WebSocket upgrade request  (HTTP status code: 400)
```

而且它表现为 **17 个测试文件全部 "loading … failed"**，看起来像代码编译不过，实际是环境问题。
跑测试前先摘掉代理：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter test
```

- [x] 摘掉代理后 **107 个测试全过**

---

## 1. 构建与安装

```bash
cd app
flutter build apk --debug --target-platform android-x64
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n org.localsend.localsend_app.debug/org.localsend.localsend_app.MainActivity
```

- [x] 构建成功 → `app/build/app/outputs/flutter-apk/app-debug.apk`（89.6 MB）
- [x] APK 内含 `lib/x86_64/librust_lib_localsend_app.so`（38.1 MB）
- [x] debug 包名带 `.debug` 后缀（`applicationIdSuffix`）
- 耗时：首次 ~37 分钟（依赖下载 + CMake + Kotlin），之后 **1–3 分钟**

### 限制 ABI 是必须的

不限制 ABI 时 AGP 会为 arm64-v8a / armeabi-v7a / x86 / x86_64 各配一遍 CMake，
cargokit 也就为每个 ABI 跑一遍 cargo（**20 分钟还没编完**）。
`--target-platform android-x64` 只影响 Flutter 引擎，插件仍按 abiFilters 走，
所以在 `~/.gradle/init.gradle` 里把 `android.defaultConfig.ndk.abiFilters` 收成 `x86_64`（可用 `-Plocalchat.abi=...` 覆盖）。
出正式包时要显式放开成 `arm64-v8a,armeabi-v7a,x86_64`。

### 已知偶发失败

首次构建时 rustc 编 `byteorder` 崩过一次（`exit code 0xc0000005, STATUS_ACCESS_VIOLATION`），
重跑即过，且 **Gradle 仍报 BUILD SUCCESSFUL** —— 只是 APK 里没有 so，装上去会在启动时报
`Failed to load dynamic library 'librust_lib_localsend_app.so'`。
看到这个运行时错误，先解包确认 `lib/<abi>/librust_lib_localsend_app.so` 在不在。

另有一次更邪门的：`:app:compileFlutterBuildDebug` 的 `kernel_snapshot_program` 把
**`analysis_options.yaml` 当 Dart 源码**编译，刷了一百多行
`analysis_options.yaml:1:1: Error: Expected a declaration, but got '#'`，构建直接失败。
什么都没改、原样重跑就过了 —— 遇到这种「YAML 被当 Dart 编译」的日志，别去动代码，直接重跑。

---

## 2. Android 侧代码

| 位置 | 内容 | 状态 |
|---|---|---|
| `MainActivity.kt` | 方法通道 `org.localsend.localsend_app/localsend` 的 `getClipboardImage` / `getClipboardFiles` | ✅ `:app:compileDebugKotlin` 通过（未改动一行） |
| `MainActivity.kt` | `MAX_CLIPBOARD_FILES = 20`、单文件 ≤256 MB（Android 要把字节读进内存） | ✅ |
| `lib/util/conversation/clipboard_image.dart` | `isSupported` 只放 windows / android；`MissingPluginException` 当「剪贴板没东西」 | ✅ 与 Windows 共用同一份 |
| `lib/pages/conversation_page.dart` | `_PasteShortcuts`（Ctrl/Cmd+V）+ `_handleEnter()` | ✅ 编译通过；行为见 §4.1 |

- [x] Kotlin 剪贴板代码能编译（这是唯一有编译风险的部分，未报错）
- ⬜ 通道调用本身未验证：模拟器里没有真实「复制图片/文件」的场景，需要真机手动试

---

## 3. 验证清单（2026-11-03 实测）

> 验证方式：模拟器截图 + `adb shell input` 注入 + 一个走真实协议的最小发送端（见 §3.6）。
> 打 ✅ 的是截图确认过的，打 ⬜ 的是环境不具备、没测到的。

### 3.1 基础

- [x] 底部导航 4 个 Tab，【会话】在第一位且默认选中
- [x] 窄屏下没有侧边栏，底部只有图标
- [x] 空状态文案正常（"No chats yet"）
- ⬜ 返回键层级（会话页 → 列表 → 退出）
- ⬜ Android 13+ 通知权限弹窗（要真触发一次前台传输才看得到）

### 3.2 文本

- [x] 底部 `[附件][输入框][发送]`，占位符 "Message…"
- [x] 软键盘的回车键变成**发送箭头**（`textInputAction: send` 生效）
- [x] 点软键盘发送键 → 气泡立刻出现、输入框清空
- [x] 气泡下方显示「Sending 3s…」+ 不确定态扫动进度条（本轮新增的等待态在 Android 上正常）
- [x] 发送失败 → 红色感叹号 + "Failed to send" / "The device is not reachable…"
- [x] 点红色感叹号可重发（同一气泡复用，不新增一条）
- [ ] **外接键盘裸回车 = 换行，不是发送** —— 与桌面端不一致，原因与取舍见 §4.1
- [x] **长按发送按钮 → 插入换行**（§4.1.1；长按后输入框变两行、不发送、不弹 tooltip）
- [x] 短按发送按钮仍然正常发送（加了 `GestureDetector` 之后手势没有互相抢）
- [x] 两行文本 `AAA\nBBB` 发送后气泡里仍然分成两行（`trim()` 只裁首尾，内部换行保留）
- ⬜ 输入框长到 6 行后内部滚动
- ⬜ Android → Windows 发文本（本机网络限制，见 §3.6 末尾）
- [x] Windows → Android 发文本：**不弹确认页**，直接落进会话，未读角标 +1
- ⬜ 键盘弹出时输入框不被遮挡 / 手势条 padding（截图里未见异常，未严格验证）

### 3.3 文件

- ⬜ SAF 选文件后发送（需要真人点系统选择器）
- ⬜ 会话页拖拽（Android 只在分屏/多窗口下才有意义）
- ⬜ 文件发送失败不产生半截文件

### 3.4 粘贴

- ⬜ 物理键盘 Ctrl+V 粘图片 / 粘文件（模拟器剪贴板里没有真实内容）
- ⬜ 软键盘长按「粘贴」（预期不生效，走的是 `TextInputClient`，不经 `Shortcuts`）

### 3.5 视觉

- [x] 自己气泡 `#4C98FF` + 白字，`You` 头像
- [x] 对方气泡浅色 + 首字母头像
- [x] 时间分隔线（`2026-11-03 15:11`）
- ⬜ 文字气泡选中 + 「复制」菜单与系统选择手柄是否冲突

### 3.6 双端互通：本机验证到了哪一步

模拟器和 Windows 主机在同一台机器上，**多播发现走不通**：
- Windows 端启动日志里 `Could not bind UDP multicast socket ... os error 10013`（沙箱不允许绑多播）；
- 模拟器是 NAT 网络，广播出不了虚拟路由器。

所以「互相发现」这条路在本机没法测。绕开办法是**自己实现一个最小发送端**走真实协议：
`adb forward tcp:53318 tcp:53317` 把模拟器的 53317 桥到宿主机，Python 用自签证书做客户端，
调 `POST /api/localsend/v2/prepare-upload`。

实测结果：**返回 204**，说明走了「文本消息静默接收」分支（不返回任何文件、发送端不进入上传阶段），
会话立刻出现、未读角标 +1 —— 接收侧链路完整。

> 踩过的细节：`fileType` 在协议里是 **MIME**（`text/plain`），不是 `"text"`。
> 写成 `"text"` 会被解码成 `FileType.other`，于是不认成文本消息，弹出「想给你发文件」的确认页。

真机验证时直接两台设备连同一 Wi-Fi 即可，不需要这段桥接。

### 3.7 2026-11-05 真机补测：重复气泡 + 发送 Tab 写会话

**重复气泡（已修，真机验证通过）**
- 现象：手机上每发出一条文本，会话里出现**两个**一模一样的气泡（id 不同、间隔一百多毫秒），接收端只收到一份。
- 根因：`sendTextMessage` 先用 `messageId` 写气泡，但 `_attemptTextSend` 调 `startSession` 时**没传 `fileIdsOverride`**，
  `startSession` 为 `FileDto` 另生成一个 uuid；上传事件按那个 id 又写一条。失败的消息（没进入上传、
  没有 Started 事件）反而只有一个气泡——这条规律正好对上历史数据。
- 修法：`fileIdsOverride: [messageId]`（一行）。
- 验证：手机 → 本机 Python 假对端（`$TEMP/lspeer/recv.py`，接受上传），发 `dupfix-1125`：
  接收端日志 1 次 prepare + 1 次 upload，手机端只有 1 条气泡，持久化里只有 1 条消息，
  其 id `fc479498-…` 与接收端日志的 `fileId` 完全一致。

**发送 Tab 不写会话（已修，需人工点一次文件选择器复核）**
- 现象：从普通「发送」Tab 发文件，会话列表里没有任何痕迹。
- 根因：会话只在 `HttpUploadFileStartedEvent` 里写，而「连不上 / 被拒绝 / 对端没勾选」根本不产生 upload 事件。
- 修法：`send_provider.startSession` 在**握手之前**预置「发送中」气泡（`_preRecordSessionMessages`），
  登记 id 到 `_preRecordedMessages`；握手每个终态分支 + `_finish` + `closeSession` 调
  `_settlePreRecorded` 收尾（跳 `FileStatus.finished`，不会把成功的改坏）。聊天页传了
  `fileIdsOverride`，这条兜底对它无效（聊天自己预置、要能重发）。
- 待复核：需要真人点一次系统文件选择器（SAF），AI 点不动 → 手动发一个文件，看会话列表有没有新卡片。

### 3.8 2026-11-05「附近设备经常为空」三处成因与修法

真机现象：冷启动后打开发送页，明明对端在线，设备列表却是空的；点一下刷新才出现。
逐层查下来是三个独立的坑叠在一起：

**① 扫描请求被静默丢弃（最要命的那个）**
- `DiscoveryService.scanSubnet / discoverStaged / sendAnnouncement` 都是先读 `_discovery`，为 `null` 就
  打一行 info 然后 `return`。而 `_discovery` 要等 Rust 侧 `startDiscovery` 绑好 UDP socket 才有值 ——
  发送页偏偏在 `postInit`（还要先 `await startServerFromSettings`）之后立刻就请求第一次扫描。
  请求落在这一段空窗里就等于什么都没发生，而且**没有任何重试**。
- 修法：`packages/localchat_isolates/lib/src/task/discovery/discovery.dart` 增加 `_awaitDiscovery()`
  （`Completer` 按“代”切换 + 5 秒上限），四个入口全部改成“等它就绪再执行”。

**② 接口列表还没取到就开始扫**
- `StartSmartScan` 直接 `ref.read(localIpProvider).localIps`，而接口是异步拉的（`FetchLocalIpAction`）。
  取到空列表时这次扫描就退化成“只发通告、不做子网兜底”。
- 修法：`scan_facade.dart` 里 `initialized == false` 时先 `await` 一次 `FetchLocalIpAction`。

**③ 多播只有“启动那一下”**
- Rust 侧一次 `announce()` = 3 个 UDP 报文（+0.1s / +0.6s / +2.6s），之后再不发言；对端也只在**它自己**启动时发。
  于是“对端比我晚启动”或“我回到前台时对端早就启动完了”这两种常见场景下，双方谁都发现不了谁。
- 修法（两条）：
  - 发送页挂一个 `_NearbyRefresh`（`pages/tabs/send_tab.dart`）：可见期间每 8 秒重发一次**通告**（不重扫子网），
    首帧补一次；退到后台不发（省电），`dispose` 即停。
  - `main.dart` 的 `AppLifecycleState.resumed` 分支补一次通告。

**为什么“重发通告”就够了**：LocalChat 协议里收到通告的一方要主动向发送方发 HTTP `register`。
所以一次通告同时解决两件事 —— 对端进我的设备库（它注册到我服务器 → `onRegister` → `addDevice`），
我进对端的设备库（它把 register 打到我的服务器）。不需要双方约好一起发。

**顺带修的两处churn**（重发通告会放大它们）：
- `RegisterDeviceAction`：设备没变化时直接返回旧 state，不再每 8 秒重建一次设备列表；
- 同上：收藏别名只有**真的变了**才写盘，以前每次确认都会 `setFavorites` 落一次盘。

**实测（2026-11-05，手机 vivo / Android ↔ Windows，同一 Wi-Fi）**
- 发送页停留：多播监听器每 ~8 秒收到 3 个报文（`$TEMP/lspeer/watch_mc.py`）；
- 切回会话页：26 秒内 **0 个报文**，说明定时器随页面 `dispose` 一起停了；
- 切后台再回前台：立刻 3 个报文；
- 关键场景：手机停在**空列表**的发送页 → 启动电脑端 → 电脑端日志显示每 8 秒回连 `192.168.101.22:53317`
  注册成功，手机端**没有点刷新**就自己出现了「狡猾的黑莓」。
- 踩坑记录：`_NearbyRefresh` 最初把 `_announce()` 放在 `initState`，Refena 的 `context.ref` 会抛
  `dependOnInheritedWidgetOfExactType was called before initState completed`，页面直接变红屏。
  改成 `didChangeDependencies` + `addPostFrameCallback` 首帧。

---

### 3.9 2026-11-05 消息通知

之前收到文本消息**没有任何系统提醒**：App 在后台时，对方发了什么用户只能事后自己翻。这次补上。

**实现要点**
- 原生侧加在 `MainActivity` 既有的 MethodChannel 上（新增 `showChatNotification` /
  `clearChatNotification` / `getChatNotificationStatus` / `openChatNotificationSettings` /
  `chatNotificationsReady`），**不引入 `flutter_local_notifications`**：项目已有这条通道，
  而现成的 `flutter_foreground_task` 只会弹它那个 LOW 优先级、静音、不可横幅的前台服务通知。
- 渠道 `localchat_messages` 用 `IMPORTANCE_HIGH`（响铃 / 震动 / 亮屏），与传输进度的
  `localchat_foreground_service`（LOW）分开 —— 一个要尽量安静，一个必须吵起来。
- 同一对端合并成一封通知：id = 指纹哈希，`InboxStyle` 最多 6 行，超出显示 `+N`，未读数累加。
- 只在 App **不在前台**时弹。前台判断直接读 `WidgetsBinding.instance.lifecycleState`，不维护副本。
- 点通知 → `PendingIntent` 带对端指纹 → 热启动走 `onNewIntent`、冷启动走 `chatNotificationsReady`
  回放 → Dart 侧 push `ConversationPage`；点开即视为已读，通知和未读累计一起清掉。
- 会话列表顶部在通知不可用时显示「通知已关闭」横幅：点「去开启」先试权限框，拿不到就跳系统设置，
  从设置回来（`AppLifecycleListener.onResume`）横幅自动消失。

**真机实测（vivo / Android 15，同一 Wi-Fi，假对端 `lspeer/send2.py`）**

| 场景 | 结果 |
|---|---|
| App 在后台收到文本 | 通知栏出现「Fake Peer / notify-background-1」，`dumpsys` 里渠道 `localchat_messages`、`mImportance=4` |
| 后台连发三条 | 只有**一封**通知，展开后是 merge-a / merge-b / merge-c 三行 |
| 点通知 | 直接进入对应会话页，通知同时消失 |
| App 在前台收到文本 | 不弹通知（前台判断见下条坑 2） |
| `pm revoke POST_NOTIFICATIONS` 后重启 | 会话列表顶部出现提示条；点「去开启」跳到 vivo 的「允许通知」页；打开开关返回，横幅自动消失 |

**终版复测（2026-11-05 15:25，包 `org.localsend.localsend_app.debug` v1.18.2）**

| 场景 | 结果 |
|---|---|
| 会话页在前台，假对端发 `FG-CHECK-1526-不弹通知` | 消息入会话（列表显示 + 未读角标 1），`dumpsys notification` 里本包 0 条 → 前台确实不弹 |
| 按 HOME 后约 1 秒发 `BG-FAST-1532-应立即弹` | 通知栏出现「Fake Peer / BG-FAST-1532-应立即弹」，点开进入 Fake Peer 会话，通知同时清零 |
| 按 HOME 后 10 秒再发 | TLS 握手超时，`dumpsys activity processes` 显示 `isFrozen=true` → 系统已冻结，收不到 |

结论：前台/后台两条分支都符合预期；后台**只有刚切走的那几秒**能收到，
之后被 Android 冻结（本机约 10 秒内）就彻底收不到 —— 这是 4.9 表格里那条
「App 被系统冻结时收不到」的实测数据，要靠前台服务或用户加白名单解决，不是本函数的 bug。

**踩到的坑**
1. **vivo 不弹横幅**：`AppSettings` 里 `isShowHeadsUp=false`（vivo 默认关掉第三方 App 的悬浮通知）。
   即使渠道是 `IMPORTANCE_HIGH`，通知也只进通知栏 + 响铃，不会从顶部弹出。这是系统设置，
   代码改不了；提示条文案因此写的是「后台收到新消息时不会有提醒」，避免让用户以为一定会弹出来。
2. **前台判断不要自己维护副本**：最初用 `LifeCycleWatcher` 回调维护 `bool _foreground`，
   出现过一次「后台收到消息但没提醒」。改为直接读 `WidgetsBinding.instance.lifecycleState` 后一致。
3. 锁屏状态下 `adb install` 会直接失败（`INSTALL_FAILED_ABORTED: User rejected permissions`），
   要先解锁手机；不是包的问题。
4. **手机上有两个包，别测错**：`org.localsend.localsend_app` 是 2024 年的旧版上游 App（3 个 Tab、
   没有会话页），调试包是 `org.localsend.localsend_app.debug`（4 个 Tab）。`build.gradle` 里
   debug 带 `applicationIdSuffix ".debug"`，所以 `adb install` 装的是后者。用
   `am start -n org.localsend.localsend_app/.MainActivity` 会拉起旧版，而且它一旦在前台就
   抢着绑 53317，调试包直接 bind 失败、`send2.py info` 报 connection refused —— 测到的东西全是假的。
   正确做法：`am force-stop org.localsend.localsend_app` 再启 `.debug` 包，
   并核对 `dumpsys window | grep mCurrentFocus` 里的包名。
5. 调试包刚启动那几秒 53317 可能还没绑上（Rust 侧异步起服），`send2.py info` 会先 refused，
   等 5~10 秒重试即可，不是崩溃。
6. `run-as` 拿不到持久化：`run-as: package not debuggable`。这台机器上别指望直接 cat
   shared_prefs，验证入库还是看会话列表截图。

---

## 4. 需要知道的平台差异

### 4.1 回车键：Android 上无法接管（已实测，别再试了）

结论表：

| 平台 | 外接/物理键盘回车 | 软键盘回车 | Shift+Enter | 长按发送按钮 |
|---|---|---|---|---|
| Windows | **发送** | — | 换行 | —（未启用，桌面有 Shift+Enter） |
| Android | **换行** | **发送**（`action=send` 显示为 ➤） | 换行（与裸回车无法区分） | **换行** |

原因：桌面端引擎会把 Enter 翻成 `TextInputAction.send`，`onSubmitted` 收得到；
Android 引擎没有这一步，**软键盘的回车本身就是发送键**，而外接键盘的回车会被 IME
直接当成 `\n` 提交进文本 —— 框架层**连一个 KeyEvent 都收不到**。

验证方式：在 `FocusNode.onKeyEvent` 里打日志，按回车后 logcat 里一条都没有。

那条「监听控制器插入了一个换行就撤回并发送」的路子也试过：能发出去，但 **Shift+Enter 也被判成发送**
（换行落地时 Shift 早已松开，读不到修饰键状态）。误发到对端比多一个空行有害，因此放弃，保留引擎默认语义。
这段推理已写进 `conversation_page.dart` 的注释，避免以后有人再走一遍。

如果要让 Android 也「裸回车发送」，只有两个选择，都要付代价：
1. 改成单行输入框（`maxLines: 1`）—— 彻底没有换行，长消息只能横向滚；
2. 加一个「回车发送 / 回车换行」设置项，默认按平台给不同值。

### 4.1.1 换行入口：长按发送按钮（已实现）

「长按软键盘的回车键换行」在框架层**做不到**：软键盘的键是输入法自己画的，
长按事件在输入法进程内部消化，连 KeyEvent 都不会传给 App（同 §4.1 的实测）。
能挂手势的只有我们自己渲染的那个发送按钮，于是换行挂在那里：

- 短按发送按钮 → 发送（原行为）
- **长按发送按钮 → 在光标处插入换行**，同时给一次 `selectionClick` 触觉反馈
- 只在 Android 启用（`Platform.isAndroid`）；Windows 已有 Shift+Enter，不改手感
- 实现：`conversation_page.dart` 的 `_handleSendButtonLongPress` + `_buildSendButton`
- 坑：`IconButton` 的 `tooltip` 在移动端默认**也是长按弹出**，会和换行抢同一个手势。
  所以 Android 上传 `tooltip: null`，外面套一个 `Tooltip(triggerMode: manual)`
  只为保住无障碍标签（TalkBack 仍能念出「发送」）。
- 空输入框时长按无反应（插一个孤零零的换行没有意义）。
- 实测（Pixel_8 / `adb shell input swipe … 900ms`）：长按后光标落到第二行、输入框长高，
  **没有发送、没有弹 tooltip**；短按仍照常发送。`AAA` → 长按 → `BBB` 发出去，气泡里是两行。

### 4.2 软键盘的「粘贴」不走 `Shortcuts`

`_PasteShortcuts` 只对硬件键盘生效。软键盘长按弹出的系统「粘贴」由 `TextInputClient` 处理，
Dart 侧收不到。要支持得给 `TextField` 传 `contextMenuBuilder`，在系统菜单里插一项
「粘贴图片 / 文件」，点击时调 `_handlePaste()`。

### 4.3 键盘遮挡与多行输入框

`SafeArea(top: false)` 在 Android 手势条下可能需要额外 bottom padding；实测截图里输入条位置正常。
`home_page.dart` 的 `Scaffold` 默认 `resizeToAvoidBottomInset: true`，键盘弹出时移动端走
`bottomNavigationBar`，未见异常。

### 4.4 `desktop_drop` 在 Android 的行为

`desktop_drop 0.7.1` 有 Android 实现（`one.mixin.desktop.drop`），会话页的 `DropTarget` 不会抛
`MissingPluginException`。Android 的拖拽只在分屏/多窗口下有意义，不追求可用。

### 4.5 其他观察

| 位置 | 现象 | 处理 |
|---|---|---|
| 模拟器（debug + swiftshader） | 冷启动约 40 秒，冷启动期的 `adb input` 会撞上 ANR（`Input dispatching timed out (Application does not have a focused window)`） | 环境问题（软件渲染 + debug），真机无此现象；等首页出现后再操作 |
| `LocalIpService.FetchLocalIpAction` | 启动后会连续触发几次 | 上游行为，未动 |
| `util/native/directories.dart` | `getCacheDirectory()` 走 `path_provider` | Android 正常 |
| `receive_controller.dart` | `autoAcceptTextMessages = true`，App 被系统冻结时收不到 | 系统限制，暂不处理；实测冻结在切后台后 10 秒内发生（`isFrozen=true`），前台/刚切走时正常 |

---

## 5. 待定的设计决策

- [x] 回车语义：维持「软键盘回车 = 发送」，换行改由**长按发送按钮**提供（见 §4.1.1），不为它牺牲多行输入
- [ ] 「自动接收文本消息」要不要做成设置项（当前硬编码 `autoAcceptTextMessages = true`）
- [x] 收到文本时要不要发系统通知（后台场景），与现有「传输中」前台服务的关系
      → 已实现（§3.9）：自建 `localchat_messages`（HIGH）渠道，不共用传输那条 LOW 前台服务通知
- [ ] 后台保活：实测切后台 10 秒内进程 `isFrozen=true`，之后完全收不到消息。
      要不要上一个常驻前台服务（或引导用户把 App 加进「后台高耗电/自启动」白名单），
      让「后台收消息」真的可用
- [ ] 拖拽确认卡片在手机上是否改用底部 Sheet（当前是居中 Dialog）

---

## 6. 已知限制（Windows / Android 共有）

- Windows 输入框多行：裸 Enter 发送，Shift+Enter 换行，Ctrl / Alt / Cmd + Enter 忽略。
- Android 输入框多行，但**软键盘没有换行键**（回车即发送）；要换行只能**长按发送按钮**，或接外接键盘。
- 单条文本上限 4000 字符（正文放在 `preview` 字段里传输）。
- 对端若是**原版** LocalSend，收到文本仍会弹「接受」卡片——对方版本的限制。
- 剪贴板文件一次最多 100 个（Windows）/ 20 个且单文件 ≤256MB（Android）。
- Windows 复制**文件夹**只跳过并提示，不递归展开。
- 粘贴的原生实现只有 **Windows / Android**：macOS / Linux / iOS 走 `MissingPluginException` 分支。

---

## 7. 打包（可选，自用可跳过）

- [x] debug APK 足够自用，`adb install -r app-debug.apk`
- [ ] release 需要 `app/android/key.properties` + keystore，否则 `signingConfigs.release` 为空会构建失败
- [ ] release 还要放开 ABI 限制（见 §1），否则只有 x86_64，装不进真机
