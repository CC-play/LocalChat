# 模块卡：设备发现（上游架构，fork 只加了「重发通告」）

## 职责

让两台设备在**没有任何服务器**的前提下互相看见：子网内多播（首选）+ 收藏地址直连 + `/24` 子网扫描（兜底）。
本卡只讲「谁在什么时候发通告、结果怎么进到 UI」，不涉及传输协议。

## 数据流

```
Rust core/multicast::start       绑定 UDP 53317（每网卡一个 socket）
        │  MulticastEvent::Discovered（收到别人的通告）
        ▼
core/discovery::answer_announcement   ← 回一发 HTTP POST /register 给对方
        │  成功才算确认
        ▼
core/discovery::DeviceStore.upsert    → DiscoveryEvent::{Discovered,Updated}
        │  （桥接层 § 见下）
        ▼
Dart: DiscoveryService.startListener  → Stream<Device>
        ▼
nearbyDevicesProvider.RegisterDeviceAction  → NearbyDevicesState.devices
        ▼
SendTab 的设备列表
```

反向那条同样重要：**收到通告的一方负责回 register**，所以一次通告同时让两端互相进库，不需要双方约定同时发包。

## 时序（要改之前的必读）

| 阶段 | 谁做 | 注意 |
|---|---|---|
| App 启动 | `postInit`：先 `startServerFromSettings()`，再 `dispatchAsync(StartDiscoveryListener())` | 监听流是 fire-and-forget |
| 绑 socket | `DiscoveryService._runListener`：`startDiscovery()` → `_discovery = …` | **在此之前所有发现操作都无效**，见下 |
| 首次通告 | 绑定成功后 `unawaited(discovery.announce())` | 3 个报文（+0.1 / +0.6 / +2.6 s） |
| 发送页可见 | `_NearbyRefresh`（`send_tab.dart`）每 8 s 重发通告；退后台/离开页面即停 | fork 新增 |
| 回到前台 | `main.dart` 的 `resumed` 分支补一发 | fork 新增 |
| 手动刷新 | `_ScanButton` → `ClearFoundDevicesAction` + `StartSmartScan` | 先清空再扫，网络差时会短暂空列表 |

## 三个已修的坑（2026-11-05）

1. **静默丢弃**：`scanSubnet / discoverStaged / sendAnnouncement / addDevice` 以前读 `_discovery` 为 `null` 就直接
   `return`。启动那几百毫秒里正好是 `null`，而发送页偏偏在这时请求首次扫描 → 什么都没发生、也不重试。
   现在统一走 `_awaitDiscovery()`（按“代”切换的 `Completer`，5 秒上限）。
2. **接口没就绪**：`StartSmartScan` 读过 `localIpProvider.localIps` 就直接用，异步没拉完时是空列表，
   扫描退化成“只发通告”。现在 `initialized == false` 时先 `await FetchLocalIpAction`。
3. **只广播一次**：多播本来只在启动时发一轮，对端比我晚启动就永远发现不了。现在只要发送页可见就每 8 s 重发。

## 不变量

- **重发通告 ≠ 重扫子网**：子网扫描是每网卡 256 个 HTTP 探测，绝不能进定时器。
- 设备列表是 **RAM-only**，没有过期淘汰：对端下线后条目仍留着（点了发送才会失败）。清空只发生在手动刷新。
- 多播循环会收到自己的报文，靠 `fingerprint == 自己` 过滤（`core/multicast/mod.rs`）。
- 收到通告要不要回 register，取决于 `set_answer_announcements`，它跟随「HTTP 服务器是否在跑」。
- `RegisterDeviceAction` 对**内容没变**的重复确认直接返回旧 state；收藏别名只在真的变了才落盘。

## 验证手法

```powershell
# 听多播（Python，本机网卡改成你的）
python $env:TEMP\lspeer\watch_mc.py 30
```

期望：发送页可见时每 ~8 s 出现 3 个来自手机的报文；切走页面 0 个；回到前台立刻 3 个。
电脑端日志里应能看到每轮通告后 `connecting to <手机IP>:53317` 的 register。
