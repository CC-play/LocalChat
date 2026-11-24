# Privacy Policy

Last updated: 2026-11-24 · applies to LocalChat 0.1.0 and later

LocalChat has no account system, no backend and no analytics. It works over your local network, and nothing is uploaded anywhere unless you send it to another device.

## What the app does not do

- No account, e-mail address or phone number.
- No telemetry, analytics, crash reporting or advertising SDKs.
- No server owned or operated by this project — there is nothing to upload to.
- No access to your contacts, photo library, location or clipboard history. Files are read only when you pick them or paste them.

## What is stored on your device

| Data | Where |
|---|---|
| Settings (device name, port, theme, …) | App data directory — `%APPDATA%\LocalChat\` on Windows, private app storage on Android |
| Favourite devices | Display name and certificate fingerprint of devices you marked |
| Transfer history | Same local store |
| Chat messages and their attachments' metadata | Same local store, in plain text |

None of this is synchronised to any cloud service, and the app does not create backups. Deleting a conversation inside the app removes it from that store; uninstalling the app removes the whole directory. Contents may still be captured by your operating system's own device backup if you have that enabled — that is the OS's behaviour, not the app's.

Received files are written to the destination folder you configure (default: your Downloads folder).

## Local network

To find other devices, the app joins a UDP multicast group on port 53317 and broadcasts an announcement. That announcement contains:

- the device name and device type/model you see in the app,
- the protocol version,
- a certificate fingerprint that identifies the device,
- the port the device's HTTPS server listens on.

Any device running LocalSend or LocalChat on the same network can see those fields — that is how the protocol discovers peers. Transfers themselves go directly to the peer over HTTPS on the same port, authenticated by those certificate fingerprints. Nothing leaves your local network in this mode.

## Connecting to a device on another network

When a peer is not on your local network, the app uses WebRTC. The defaults are:

- signalling: `wss://public.localsend.org/v1/ws`
- STUN: `stun.localsend.org:3478`

**Both are operated by the upstream LocalSend project, not by this fork.** We have no access to their logs or data.

What is sent to the signalling server: a random session identifier, your device's public-key fingerprint, device name, device type/model, protocol version, and the WebRTC handshake (session description and ICE candidates, which can include IP addresses).

What is not sent: file names, file contents, and chat text. The actual transfer runs over an encrypted peer-to-peer channel (DTLS), and both sides confirm a PIN before data is exchanged.

Version 0.1.0 has no setting to change these servers; they are compile-time defaults. If you need different servers, build from source.

## Permissions (Android)

| Permission | Why |
|---|---|
| `INTERNET`, `ACCESS_LOCAL_NETWORK` | Device discovery and transfers |
| `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`, `READ_MEDIA_IMAGES`, `READ_MEDIA_VIDEO`, `ACCESS_MEDIA_LOCATION` | Picking files to send, saving received files |
| `FOREGROUND_SERVICE_DATA_SYNC` | Keeping a transfer alive while the app is in the background |
| `QUERY_ALL_PACKAGES`, `REQUEST_INSTALL_PACKAGES` | Inherited from upstream: listing installed apps you choose to share, and opening APKs you received |
| Notifications | Locally generated chat and transfer alerts |

## Donations

The WeChat reward code in the app and in this repository is a static image. Displaying it sends nothing and collects nothing. Any payment happens inside WeChat, under Tencent's own privacy policy; the app never sees your payment details.

## Children

LocalChat is not directed at children and collects no personal data from anyone.

## Changes and contact

This policy is versioned with the code; the date at the top changes when it does. Questions or corrections: open an issue at <https://github.com/CC-play/LocalChat/issues>.

---

# 隐私政策

最后更新：2026-11-24 · 适用于 LocalChat 0.1.0 及之后的版本

LocalChat 没有账号体系、没有后端、没有统计。它在你的局域网内工作，除非你主动发给另一台设备，否则任何内容都不会被上传。

## 这个应用不会做的事

- 不要求注册、邮箱或手机号。
- 没有埋点、统计、崩溃上报或广告 SDK。
- 本项目没有任何自有服务器，也就没有可上传的地方。
- 不读取通讯录、相册、位置或剪贴板历史。只有你主动选择或粘贴文件时才会读取该文件。

## 存在你设备上的数据

| 数据 | 位置 |
|---|---|
| 设置（设备名、端口、主题等） | 应用数据目录 —— Windows 为 `%APPDATA%\LocalChat\`，Android 为应用私有存储 |
| 收藏设备 | 你标记过的设备的显示名与证书指纹 |
| 传输历史 | 同一个本地存储 |
| 聊天消息及其附件元信息 | 同一个本地存储，明文保存 |

这些数据不会同步到任何云服务，应用也不会自动备份。在应用内删除会话会把对应数据从存储中移除；卸载应用会删除整个目录。若你的操作系统开启了整机备份，该目录可能被系统备份一并复制——那是系统行为，不是应用行为。

接收到的文件会写入你配置的目标目录（默认是“下载”文件夹）。

## 局域网

为了发现设备，应用会加入端口 53317 上的 UDP 组播组并广播一条公告，其中包含：

- 你在界面上看到的设备名、设备类型/型号，
- 协议版本，
- 标识该设备的证书指纹，
- 该设备 HTTPS 服务监听的端口。

同一局域网内任何运行 LocalSend 或 LocalChat 的设备都能看到这些字段——这正是协议的发现机制。传输本身通过同一端口上的 HTTPS 直连对端，并用上述证书指纹校验身份。该模式下数据不会离开你的局域网。

## 连接另一个网络中的设备

当对端不在局域网内时，应用使用 WebRTC。默认配置为：

- 信令：`wss://public.localsend.org/v1/ws`
- STUN：`stun.localsend.org:3478`

**这两项都由上游 LocalSend 项目运营，与本项目无关。** 我们无法访问其日志或数据。

发送给信令服务器的内容：随机会话标识、你设备的公钥指纹、设备名、设备类型/型号、协议版本，以及 WebRTC 握手信息（会话描述与 ICE 候选地址，其中可能包含 IP 地址）。

不会发送：文件名、文件内容、聊天文本。实际传输走加密的点对点通道（DTLS），并且双方需要确认一致的 PIN 才会交换数据。

0.1.0 版本没有提供修改这些服务器的设置项，它们是编译期默认值。如需更换，请从源码构建。

## Android 权限

| 权限 | 用途 |
|---|---|
| `INTERNET`、`ACCESS_LOCAL_NETWORK` | 设备发现与传输 |
| `READ_EXTERNAL_STORAGE`、`WRITE_EXTERNAL_STORAGE`、`READ_MEDIA_IMAGES`、`READ_MEDIA_VIDEO`、`ACCESS_MEDIA_LOCATION` | 选择要发送的文件、保存接收的文件 |
| `FOREGROUND_SERVICE_DATA_SYNC` | 应用退到后台时保持传输不中断 |
| `QUERY_ALL_PACKAGES`、`REQUEST_INSTALL_PACKAGES` | 继承自上游：列出你要分享的已安装应用，以及打开收到的 APK |
| 通知 | 本地生成的聊天与传输提醒 |

## 赞赏

应用内与本仓库中的微信赞赏码是一张静态图片。展示它不会发送或收集任何信息。支付行为发生在微信内，受腾讯自身的隐私政策约束；应用看不到你的支付信息。

## 儿童

LocalChat 不面向儿童，也不收集任何人的个人数据。

## 变更与联系方式

本政策随代码一起纳入版本管理，修改时会更新顶部的日期。疑问或指正请到 <https://github.com/CC-play/LocalChat/issues> 提 issue。
