# Android 端 TODO

> 目标：让 fork 的会话/聊天功能在 Android 上跑通（与 Windows 端互通）。
>
> 当前状态（2026-11-03 15:20 复查）：
> - **Android 从未构建过**，`android-36` 平台与 NDK 仍缺，见 §0。
> - Android 侧的原生代码**已经写好但从未编译过**（剪贴板通道 `getClipboardImage` / `getClipboardFiles`），见 §2。
> - Dart 侧与 Windows 共用同一份代码，平台差异集中在输入法、快捷键与键盘遮挡，见 §4。
> - Windows 端已跑通：会话 Tab、文本/文件收发、2 分钟离线重试、拖拽、Ctrl+V 粘贴、回车语义。

---

## 0. 环境准备（一次性，阻塞后续所有步骤）

现状（2026-11-03 15:20 实测，与 11-02 记录一致，尚未打补丁）：

| 组件 | 要求 | 现状 |
|---|---|---|
| `compileSdkVersion` | 36（`app/android/app/build.gradle`） | ❌ 只有 `android-35` / `android-37.0`，**缺 `platforms/android-36`** |
| `targetSdkVersion` | 37 | ✅ `android-37.0` |
| NDK | `28.2.13676358`（`FlutterExtension.kt` 里的固定值，AGP 会硬校验） | ❌ `Sdk\ndk` 目录不存在 |
| build-tools | 36.0.0 | ✅ 34.0.0 / 35.0.0 / 36.0.0 |
| platform-tools / adb | 任意 | ✅ |
| cmdline-tools / sdkmanager | 需要 | ❌ `Sdk\cmdline-tools` 是空目录 |
| JDK | 17+ | ✅ JBR 21 |
| Rust Android target | 见 §0.3 | ❌ 只有 `x86_64-pc-windows-msvc` |
| 设备 | 真机或模拟器 | ✅ **已有 AVD `Pixel_8`**（`system-images;android-36;google_apis_playstore;x86_64`） |

预计下载量 ~2.5 GB（NDK 约 1.5 GB + 平台 0.2 GB + 模拟器相关）。

### 0.1 装 cmdline-tools（拿到 sdkmanager）

没有 Android Studio，只能手动解压。**注意 zip 内已经有一层 `cmdline-tools` 目录，解压后要再套一层 `latest`**，否则 sdkmanager 找不到 SDK。

```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
Invoke-WebRequest -Uri https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip -OutFile "$env:TEMP\cmdtools.zip"
Expand-Archive "$env:TEMP\cmdtools.zip" "$env:TEMP\cmdtools" -Force
New-Item -ItemType Directory -Force "$sdk\cmdline-tools\latest" | Out-Null
Move-Item "$env:TEMP\cmdtools\cmdline-tools\*" "$sdk\cmdline-tools\latest\" -Force
& "$sdk\cmdline-tools\latest\bin\sdkmanager.bat" --version
```

- [ ] sdkmanager 能打印版本号（如 `19.0`）

### 0.2 装 platform / NDK

```powershell
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
& "$sdk\cmdline-tools\latest\bin\sdkmanager.bat" --sdk_root="$sdk" `
    "platforms;android-36" `
    "ndk;28.2.13676358"
```

- [ ] `Sdk\platforms\android-36` 存在
- [ ] `Sdk\ndk\28.2.13676358` 存在
- [ ] `flutter doctor -v` 的 Android 段落不再报 NDK / platform 缺失

> `build-tools;36.0.0` 已装，不必重复。首次 `sdkmanager` 会要求接受 licenses，加 `--licenses` 或按提示敲 `y`。

### 0.3 Rust Android target

cargokit 在 Gradle 构建时通常会自己 `rustup target add`，但预装能避免首次构建时把「网络失败」误判成代码问题。

```bash
# 模拟器（Pixel_8 是 x86_64）
rustup target add x86_64-linux-android
# 真机
rustup target add aarch64-linux-android armv7-linux-androideabi
```

- [ ] `rustup target list --installed` 里能看到至少要用的那几个
- [ ] 只连模拟器时**不需要** arm 的两个 target，`flutter run` 默认只为目标 ABI 编译，能省一大截时间

### 0.4 设备

模拟器（推荐先走这条，不用碰手机）：

```bash
"$env:LOCALAPPDATA/Android/Sdk/emulator/emulator.exe" -avd Pixel_8   # 或 Android Studio 里启动
adb devices                                                          # 应出现 emulator-5554
```

- [ ] `adb devices` 能列出 `emulator-5554`
- [ ] 模拟器需要开启硬件加速（WHPX / Hyper-V），否则 x86_64 镜像起不来

真机：

- [ ] 手机开启「开发者选项 → USB 调试」
- [ ] `adb devices` 能列出设备（首次要在手机上点允许）

---

## 1. 首次构建

```bash
cd app
flutter run -d emulator-5554        # 调试跑；或 flutter build apk --debug
```

- [ ] `flutter build apk --debug` 成功 → `app/build/app/outputs/flutter-apk/app-debug.apk`
- [ ] 首次构建能过 `:app:compileDebugKotlin`（这一关会编译 §2 新增的剪贴板代码）

### 预期会踩的坑

1. **首次 Gradle 构建 10–20 分钟**：要编译 Rust 的多个 ABI，且会下载 Gradle 发行包。
2. **JDK 版本**：若报 `Unsupported class file major version`，在 `gradle.properties` 里加
   `org.gradle.java.home=<JBR 路径>`（本机无 AS，用当前 JBR）。
3. **不要带 `CL=/source-charset:utf-8`**：那是 Windows 上 MSVC 用的，Android 走 clang。
4. **NDK 版本不匹配**：AGP 会硬校验 `ndkVersion`，必须精确到 `28.2.13676358`。
5. **Windows 路径过长**：Rust 增量构建目录较深，若报 `filename too long`，开长路径支持
   （`git config --system core.longpaths true` + 注册表 `LongPathsEnabled=1`）。
6. **Kotlin 编译失败先看 §2**：`MainActivity.kt` 的剪贴板代码是本仓库新加的，从未编译过。

---

## 2. Android 侧已就位的代码（未编译、未验证）

| 位置 | 内容 |
|---|---|
| `android/.../MainActivity.kt` | 方法通道 `org.localsend.localsend_app/localsend` 新增 `getClipboardImage` / `getClipboardFiles`；`readClipboardImage()` 读 `primaryClip` 第 0 项的 `content://` URI；`readClipboardFiles()` 遍历 `ClipData`，取 mime + `OpenableColumns.DISPLAY_NAME` + 字节 |
| 同上（常量） | `MAX_CLIPBOARD_FILES = 20`、`MAX_CLIPBOARD_FILE_BYTES = 256MB`（Android 必须把字节读进内存，不设上限会 OOM） |
| `lib/util/conversation/clipboard_image.dart` | `isSupported` 只放 **windows / android**；`MissingPluginException` 当「剪贴板里没有东西」；文件名消毒 `<>:"|?*`、控制字符、尾部点/空格 |
| `lib/pages/conversation_page.dart` | 页面级 `_PasteShortcuts`（Ctrl/Cmd+V）+ `_handleEnter()`（Enter 发送 / Shift+Enter 换行） |

- [ ] `flutter build apk --debug` 能编译过这段 Kotlin（未验证过）
- [ ] 真机/模拟器上 `adb logcat | grep -i clipboard` 能看到通道调用（未验证过）

---

## 3. 验证清单

> 前提：Windows 端已跑通。按顺序做，前面的不过不用往后试。

### 3.1 基础

- [ ] 底部导航 4 个 Tab，【会话】在第一位且默认选中
- [ ] 侧边栏在窄屏（手机）不出现，底部 NavigationBar 只有图标
- [ ] 返回键：会话页 → 会话列表 → 退出 App，不出现空栈
- [ ] Android 13+ 首次传输时通知权限被请求（`POST_NOTIFICATIONS` 由 `flutter_foreground_task` 的 manifest 合并进来，见 `AndroidManifest.xml` 注释）

### 3.2 文本

- [ ] 底部有 `[附件][输入框][发送]`，键盘弹出时输入框不被遮挡
- [ ] **软键盘发送键**能发出消息（`TextInputAction.send` 在 Android 上的表现，见 §4.1）
- [ ] **回车键**能发出消息（裸 Enter；若软键盘把 Enter 变成换行，就是 §4.1 的问题）
- [ ] **Shift+Enter** 在物理键盘上换行、不发送
- [ ] 输入框长到 6 行后内部滚动，不把整个底部撑破
- [ ] Android → Windows 发文本，Windows 端即时出现在会话里
- [ ] Windows → Android 发文本，**不弹接收确认页**，直接进会话
- [ ] 离线发文本：气泡左侧出现转圈，2 分钟内对端上线会自动补发
- [ ] 发送失败：气泡左侧变红叹号 + 顶部 Toast，文字**不再**被还原回输入框（当前实现是清空后后台重试）

### 3.3 文件

- [ ] 附件按钮走 SAF 选文件后能正常发送（`content://` URI）
- [ ] 会话页可拖拽接收（见 §4.4，预期在分屏/多窗口下才有意义）
- [ ] 文件发送失败时不产生「半截文件」（只重试 prepare-upload 阶段）

### 3.4 粘贴（Android 独有大坑）

- [ ] 物理键盘 Ctrl+V：剪贴板是图片 → 弹确认卡片
- [ ] 物理键盘 Ctrl+V：剪贴板是文件（如相册「复制」/文件管理器）→ 弹确认卡片
- [ ] 软键盘长按「粘贴」：**当前预期不生效**（走 `TextInputClient`，不经过 `Shortcuts`），见 §4.2
- [ ] 粘贴后确认卡片关闭，焦点回到输入框

### 3.5 视觉

- [ ] 自己气泡固定 `#4C98FF` + 白字，头像跟随主题色
- [ ] 文字气泡可选中、选中后弹「复制」菜单（Android 上 `SelectionArea` + 自定义菜单是否与系统选择手柄冲突）
- [ ] 顶部 Toast 字号 16、不挡底部输入条

---

## 4. 预判需要改的代码

### 4.1 回车语义在 Android 上很可能不成立（最高优先级）

Windows 引擎的规则是：`inputType == multiline && inputAction == newline` 才由引擎插换行，否则交给框架 `onSubmitted`。**Android 没有这一层**——`textInputAction: send` 在 `TextInputType.multiline` 下，IME 通常把回车渲染成**换行键**（`IME_ACTION_NONE`），直接 `updateEditingState` 插入 `\n`，`performAction(send)` 根本不触发。

备选（按推荐顺序，实测后定）：

1. 监听 `_controller` 变化，检测「插入了一个 `\n` 且当前没按 Shift」→ 撤回该字符并发送。与 Windows 的行为对齐，代价是脏。
2. `keyboardType: TextInputType.text` + `maxLines: 1`（失去多行，Shift+Enter 无处可换）。
3. 试 `TextInputAction.done`：部分 IME 在 `text` 类型下会显示「完成/发送」键，但多行类型下依旧被忽略。

### 4.2 软键盘的「粘贴」不走 `Shortcuts`

`_PasteShortcuts` 只对硬件键盘生效。软键盘长按弹出的系统「粘贴」由 `TextInputClient` 处理，Dart 侧收不到。要支持得给 `TextField` 传 `contextMenuBuilder`，在系统菜单里插一项「粘贴图片 / 文件」，点击时调 `_handlePaste()`。

### 4.3 键盘遮挡与多行输入框

- `SafeArea(top: false)` 在 Android 手势条下可能需要额外 bottom padding；多行输入框长到 6 行时空间更紧。
- 实测后按需用 `MediaQuery.viewInsets.bottom` 或 `AnimatedPadding` 处理。
- `home_page.dart` 的 `Scaffold` 默认 `resizeToAvoidBottomInset: true`，键盘弹出时 `Row`（含 NavigationRail）会被压缩——桌面无关，移动端走 `bottomNavigationBar`，需实测。

### 4.4 `desktop_drop` 在 Android 的行为

`desktop_drop 0.7.1` **有 Android 实现**（`one.mixin.desktop.drop`），所以会话页的 `DropTarget` 不会抛 `MissingPluginException`。但 Android 的拖拽只在分屏/多窗口、或从其他 App 拖入时才有意义，普通全屏场景基本摸不到。实测确认不崩即可，不追求可用。

### 4.5 其他

| 位置 | 问题 | 处理 |
|---|---|---|
| `util/conversation/conversation_sender.dart` | Android 分支用 `android_channel.pickFilesAndroid()`，返回 `content://` URI | 上游发送页走同一路径，理论 OK；失败则回退 `file_selector.openFiles()` |
| `util/native/directories.dart` `getCacheDirectory()` | 走 `path_provider.getTemporaryDirectory()` | Android 正常（app 私有 cache），无需改 |
| `provider/network/server/controller/receive_controller.dart` | `autoAcceptTextMessages = true`，App 被系统冻结时收不到 | 系统限制，暂不处理 |
| `android/app/src/main/AndroidManifest.xml` | `POST_NOTIFICATIONS` 来自 `flutter_foreground_task` 的 manifest 合并，本文件未显式声明 | 已确认注释在案；若通知不弹，先 `adb shell dumpsys package ... \| grep POST_NOTIFICATIONS` |

---

## 5. 待定的设计决策

- [ ] 「自动接收文本消息」要不要做成设置项（当前硬编码 `autoAcceptTextMessages = true`）
- [ ] 收到文本时要不要发系统通知（后台场景），以及与现有「传输中」前台服务的关系
- [ ] 会话 Tab 已是默认首页（Windows 端已改），Android 端确认一致即可
- [ ] 拖拽确认卡片在手机上是否改用底部 Sheet（当前是居中 Dialog，窄屏下已按 `min(380, 宽-120)` 收窄）

---

## 6. 已知限制（Windows / Android 共有）

- 输入框**多行**（`minLines: 1` / `maxLines: 6`）：裸 Enter 发送，Shift+Enter 换行，Ctrl / Alt / Cmd + Enter 忽略。
- 单条文本上限 4000 字符（正文放在 `preview` 字段里传输）。
- 对端若是**原版** LocalSend，收到文本仍会弹「接受」卡片——对方版本的限制。
- 接收端只在 fork 版本上自动接收，原版不受影响。
- 剪贴板文件一次最多 100 个（Windows）/ 20 个且单文件 ≤256MB（Android）。
- Windows 复制**文件夹**只跳过并提示，不递归展开。
- 粘贴的原生实现只有 **Windows / Android**：macOS / Linux / iOS 会走 `MissingPluginException` 分支，退化成普通文本粘贴。

---

## 7. 打包（可选，自用可跳过）

- [ ] debug APK 足够自用，直接 `adb install -r app-debug.apk`
- [ ] 若要 release：需要 `app/android/key.properties` + keystore，否则 `signingConfigs.release` 为空会构建失败
