# iOS App 编译与真机运行

> 需要一台 Mac（Intel / Apple Silicon 都行）+ Xcode 15 以上。Windows 上无法直接编译这个 App。
> **没有 Mac** 就看 [install-iphone.md](install-iphone.md)：用 GitHub Actions 编译出 IPA，再在 Windows 上用 Sideloadly 装进手机。

## 方式 A：手动建工程（最稳）

1. Xcode → **File → New → Project… → iOS → App**
   - Product Name：`NavDisplaySender`
   - Interface：**SwiftUI**
   - Language：**Swift**
2. 删掉自动生成的 `ContentView.swift` 和 `NavDisplaySenderApp.swift`（保留 Assets 和 Info）。
3. 把本目录 `NavDisplaySender/` 下的 8 个 `.swift` 拖进工程，勾选 **Copy items if needed**：
   - `NavDisplaySenderApp.swift`
   - `ContentView.swift`
   - `NavLink.swift`
   - `NavigationEngine.swift`
   - `Routing.swift`
   - `MapPayload.swift`
   - `NavPacket.swift`
   - `Maneuver.swift`
4. 选中 Target → **Signing & Capabilities**：
   - Team 选你的 Apple ID（个人免费账号即可）
   - Bundle Identifier 改成唯一的，例如 `com.你的名字.NavDisplay`
5. **Info** 标签页加两条权限说明（少了会闪退）：

   | Key | Value |
   | --- | --- |
   | `Privacy - Location When In Use Usage Description` | 需要定位权限来规划路线并计算实时转向指引。 |
   | `Privacy - Bluetooth Always Usage Description` | 需要蓝牙权限把导航信息发送到 ESP32 副屏。 |

   如果是 Xcode 15 的 Info 表单，直接点 + 搜 "Location" 和 "Bluetooth"。
6. 手机连上 Mac，选真机 → Run。
7. 首次运行：
   - 允许「使用 App 期间」定位
   - 允许蓝牙
   - 如果提示「不受信任的开发者」，去 设置 → 通用 → VPN与设备管理 里信任

> 免费账号签的 App **7 天过期**，过期后重新 Run 一次即可。想长期用就买个 99 美元的开发者账号，或者每 7 天重签。

## 方式 B：XcodeGen（一条命令生成工程）

```bash
brew install xcodegen
cd ios
xcodegen generate
open NavDisplaySender.xcodeproj
```

工程里已经配好了权限文案和 Bundle ID（`com.example.NavDisplaySender`，记得改成你自己的）。

## 用高德数据源（可选，推荐国内用）

App 里可以随时在 **Apple 地图 / 高德** 之间切换，高德模式下 POI 搜索和转向指令都走高德 Web 服务 API。

1. 打开 [高德开放平台控制台](https://console.amap.com/dev/key/app) → 应用管理 → 创建应用。
2. 添加 Key，**服务平台选「Web服务」**（不是 iOS 平台，不需要绑定 Bundle ID）。
3. 复制 Key，打开 App → 「路线与搜索」→ 选「高德」→ 粘贴 Key。
4. 搜索目的地，规划路线，屏幕上的转向会直接来自高德的 `action` 字段（左转/右转/靠左/环岛/掉头…），比 Apple 的几何判断准。

注意：

- Web 服务 Key 有免费日配额，个人用足够；超了会返回 `DAILY_QUERY_OVER_LIMIT`。
- 报 `INVALID_USER_KEY` 通常是 Key 类型选错（选成了 iOS/Android Key）或没生效，等 1~2 分钟再试。
- 高德返回的坐标是 GCJ-02，和 iOS 定位一致；周边道路的 OSM 数据仍按 GCJ-02 转换，两者对得上。
- 想换成高德 iOS 导航 SDK（带语音、后台导航、路口放大图）也可以，但那是另一套集成，需要绑定 Bundle ID 并加 Pod。

## 使用流程

1. ESP32 上电，屏幕显示「等待手机连接」。
2. 打开 App，顶部状态变成 **已连接**（会自动扫描，不用去系统蓝牙里配对）。
3. 输入目的地 → 搜索 → 点选结果，自动规划路线。
4. 勾选「模拟导航」可以在家测试：不用开车，App 会按 50km/h 沿路线模拟前进，屏幕同步显示。
5. 上车后取消模拟，点「开始导航」，把手机固定好。App 会禁止息屏。

> 地图模式需要手机联网：App 启动/刷新时用 Overpass API 拉当前位置周围约 1.5km 的道路，
> 裁剪抽稀后通过 BLE 分块发给屏幕。拉不到时屏幕只画导航路线（不显示周边道路），
> 不影响转向提示；国内访问 `overpass-api.de` 较慢时可以把 `MapPayload.swift` 里的
> URL 换成镜像（如 `https://overpass.kumi.systems/api/interpreter`）。

## 常见问题

**搜不到 ESP32**

- 确认固件已经跑起来（串口打印 `[ble] 广播中`）。
- iOS 的蓝牙列表里**不会**出现这个设备，它是自定义服务，只在 App 里可见，这是正常的。
- 系统蓝牙里如果残留了旧的配对记录，去 设置 → 蓝牙 → 忽略此设备，再重试。

**连上但屏幕没反应**

- 检查 App 顶部是否显示「已连接」且包数在涨。
- 串口看有没有 `[nav] JSON 解析失败`。
- 如果包数不涨，说明特征值写属性没找到，确认固件和 App 的 UUID 一致。

**规划路线失败**

- 需要联网（Apple 的路线服务）。
- 模拟器没有真实定位，请用真机；或在模拟器里设置 Debug → Location → Custom Location。

**后台会断**

iOS 会在 App 进入后台一段时间后挂起定位和蓝牙。本项目按「手机常亮放车上」设计，已经设置了 `isIdleTimerDisabled`。要真后台跑，需要申请 `location` 后台模式并拿到「始终允许」定位权限，超出本教程范围。

## 代码结构

| 文件 | 作用 |
| --- | --- |
| `NavLink.swift` | CoreBluetooth：扫描、连接、写特征值、断线重连、地图分帧节流 |
| `NavigationEngine.swift` | 路线规划、GPS 投影、转向判断、位置包、触发地图重发 |
| `Routing.swift` | 数据源抽象：Apple MapKit / 高德 Web 服务（POI + 驾车路径） |
| `MapPayload.swift` | 路线/道路 → 二进制 blob、分帧、CRC32、OSM Overpass 拉取、GCJ-02 转换 |
| `NavPacket.swift` | JSON 协议结构体 + 按 MTU 自动裁剪 |
| `Maneuver.swift` | 转向枚举（字符串 + 固件用的数字编码） |
| `ContentView.swift` | SwiftUI 界面 |
