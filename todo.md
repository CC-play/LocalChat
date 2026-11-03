# Android 端 TODO

> 目标：让 fork 的会话/聊天功能在 Android 上跑通（与 Windows 端互通）。
> 当前状态：Android 从未构建过。代码层面共用同一份 Dart，理论差异只在环境与个别平台通道。

---

## 0. 环境准备（一次性，阻塞后续所有步骤）

现状（2026-11-02 实测）：

| 组件 | 要求 | 现状 |
|---|---|---|
| `compileSdk` | 36 | ❌ 只有 android-35 / android-37.0 |
| `targetSdk` | 37 | ✅ 有 android-37.0 |
| NDK | `28.2.13676358`（Flutter 3.44 固定值） | ❌ 完全没装 |
| build-tools | 36.0.0 | ✅ 已有 |
| platform-tools | 任意 | ✅ 37.0.1 |
| cmdline-tools / sdkmanager | 需要 | ❌ 没装（`Sdk\cmdline-tools` 是空目录） |
| JDK | 17+ | ✅ JBR 21.0.11 |
| Rust Android target | 4 个 ABI | ❌ 只有 `x86_64-pc-windows-msvc` |

预计下载量 ~2.5 GB。

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
    "ndk;28.2.13676358" `
    "build-tools;36.0.0"
```

- [ ] `Sdk\platforms\android-36` 存在
- [ ] `Sdk\ndk\28.2.13676358` 存在

### 0.3 Rust Android target

cargokit 在 Gradle 构建时通常会自己 `rustup target add`，但预装可以避免首次构建时报错难排查。

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android i686-linux-android
```

- [ ] `rustup target list --installed` 里能看到上述 4 个

### 0.4 连设备

- [ ] 手机开启「开发者选项 → USB 调试」
- [ ] `adb devices` 能列出设备（首次要在手机上点允许）

---

## 1. 首次构建

```bash
cd app
flutter run -d <deviceId>          # 或先 flutter build apk --debug
```

- [ ] `flutter build apk --debug` 成功 → `app/build/app/outputs/flutter-apk/app-debug.apk`

### 预期会踩的坑

1. **首次 Gradle 构建 10–20 分钟**：要编译 Rust 的 3 个 ABI，且下载 Gradle 8.13 发行包。
2. **JDK 版本**：Gradle 8.13 支持 JDK 21，但若报 `Unsupported class file major version`，在 `gradle.properties` 里加
   `org.gradle.java.home=C:\\Program Files\\Android\\Android Studio\\jbr`（本机无 AS，用当前 JBR 路径）。
3. **不要带 `CL=/source-charset:utf-8`**：那是 Windows 上 MSVC 用的，Android 走 clang，设了无害但没必要。
4. **NDK 版本不匹配**：AGP 会硬性校验 `ndkVersion`，装了别的版本会直接报错，必须精确到 `28.2.13676358`。
5. **Windows 路径过长**：Rust 增量构建目录较深，若报 `filename too long`，给仓库开长路径支持
   （`git config --system core.longpaths true` + 注册表 `LongPathsEnabled=1`）。

---

## 2. 聊天功能在 Android 上的验证清单

> 前提：Windows 端已跑通（会话 Tab、收发记录、文本输入框）。

- [ ] 底部导航是 4 个 Tab，且【会话】在中间
- [ ] 与 Windows 互传文件后，会话列表出现条目，气泡方向正确
- [ ] 会话页底部有 [附件][输入框][发送]，键盘弹出时输入框不被遮挡
- [ ] Android → Windows 发文本，Windows 端即时出现在会话里
- [ ] Windows → Android 发文本，**不弹接收确认页**，直接进会话
- [ ] 发送失败时，文字被还原回输入框
- [ ] 附件按钮走 SAF 选文件后能正常发送（`content://` URI）
- [ ] 返回键：会话页 → 会话列表 → 退出，不出现空栈
- [ ] Android 13+ 首次传输时会请求通知权限（前台服务需要）

---

## 3. 预判需要改的代码

| 位置 | 问题 | 处理 |
|---|---|---|
| `pages/home_page.dart` | Scaffold 默认 `resizeToAvoidBottomInset: true`，键盘弹出时整个 `Row`（含 NavigationRail）会被压缩 | 桌面无关；移动端本就走 `bottomNavigationBar`，需实测是否遮挡底部输入栏 |
| `pages/conversation_page.dart` `_Composer` | `SafeArea(top: false)` 在 Android 手势条下可能需要额外 bottom padding | 实测后调 `MediaQuery.viewInsets.bottom` |
| `util/conversation/conversation_sender.dart` | Android 分支用 `android_channel.pickFilesAndroid()`，返回的 `FileInfo.uri` 是 `content://` | 上游发送页走同一路径，理论上 OK；若失败，回退到 `file_selector.openFiles()` |
| `provider/network/server/controller/receive_controller.dart` | `autoAcceptTextMessages = true` 在 App 被系统冻结时收不到 | 属于系统限制，暂不处理（可后续加通知提醒） |
| `android/app/src/main/AndroidManifest.xml` | 确认 `POST_NOTIFICATIONS` 权限声明 | 上游已有，检查即可 |

---

## 4. 待定的设计决策

- [ ] 「自动接收文本消息」要不要做成设置项（当前是常量 `autoAcceptTextMessages`，硬编码 true）
- [ ] 收到文本时要不要发系统通知（后台场景），以及与现有「传输中」前台服务的关系
- [ ] 是否把会话 Tab 改成默认首页（目前默认仍是【接收】）

---

## 5. 已知限制（Windows / Android 共有）

- 输入框为单行，回车即发送；不支持 Shift+Enter 换行
- 单条文本上限 4000 字符（正文放在 `preview` 字段里传输）
- 对端若是**原版** LocalSend，收到文本仍会弹「接受」卡片——这是对方版本的限制
- 接收端只在 fork 版本上自动接收，原版不受影响

---

## 6. 打包（可选，自用可跳过）

- [ ] debug APK 足够自用，直接 `adb install -r app-debug.apk`
- [ ] 若要 release：需要 `app/android/key.properties` + keystore，否则 `signingConfigs.release` 为空会构建失败
