# 把 App 装进 iPhone

> 前提：iPhone 系统 **iOS 16 或更高**，一个 Apple ID（免费账号就够）。
> 免费签名装出来的 App **7 天后过期**，到期重新签一次即可。

先在下面三种方式里选一种：

| 你的条件 | 用哪种 | 难度 |
| --- | --- | --- |
| 能借到一台 Mac（10 分钟） | [方案 A](#方案-a有-mac最稳) | ★ |
| 只有 Windows | [方案 B](#方案-b没有-macgithub-编译--windows-签名) | ★★ |
| 想长期调试 | 方案 C（云 Mac）或买开发者账号 | ★★★ |

---

## 方案 A：有 Mac（最稳）

1. Mac 上装 **Xcode 15**（App Store 免费）。
2. 按 [docs/ios.md](ios.md) 建工程、拖入 8 个 Swift 文件。
3. Target → Signing & Capabilities：
   - Team 选你的 Apple ID（Personal Team）
   - Bundle Identifier 改成唯一的，例如 `com.你的名字.NavDisplay`
4. iPhone 用数据线连 Mac，顶部设备选你的 iPhone → **Run**（⌘R）。
5. 手机上：设置 → 通用 → VPN与设备管理 → 开发者 App → 信任你的 Apple ID。
6. 打开 App，允许定位和蓝牙。

> 免费账号签的 App 7 天过期；过期后连上 Mac 再 Run 一次。

---

## 方案 B：没有 Mac（GitHub 编译 + Windows 签名）

思路：让 GitHub 的 macOS 机器帮你编译出**未签名 IPA**，你在 Windows 上用 Sideloadly 用自己的 Apple ID 签名装进手机。

```text
Windows 上传代码 → GitHub Actions(macOS) 编译 → 下载 unsigned.ipa
        → Sideloadly 用你的 Apple ID 签名 → iPhone
```

### B1. 准备

- 一个 GitHub 账号（免费）
- Windows 装 **iTunes 桌面版**（Apple 官网下载，不要 Microsoft Store 版）
- 装 **Sideloadly**：<https://sideloadly.io>
- iPhone 数据线

### B2. 上传代码

1. GitHub 新建仓库（Private 也可以），**仓库根目录就是本项目根目录**（能看到 `firmware/`、`ios/`、`.github/`）。
2. 用 GitHub Desktop 或网页上传整个 `esp32-nav-display` 文件夹。

关键：`.github/workflows/build-ios-ipa.yml` 必须在仓库根目录的 `.github/workflows/` 下，否则 Actions 里看不到这个工作流。

### B3. 触发编译

1. 仓库页面 → **Actions** → 左侧 **Build iOS IPA (unsigned)** → 右侧 **Run workflow**。
2. 等 3~8 分钟。
3. 点进这次运行，页面底部 **Artifacts** → 下载 `NavDisplaySender-unsigned-ipa`。
4. 解压得到 `NavDisplaySender-unsigned.ipa`。

> 编译失败时把红色日志发我。常见原因是 XcodeGen 没装上（重跑一次），或者 Swift 代码报错。

### B4. 签名安装（Windows）

1. 打开 iTunes，确认它能识别你的 iPhone（手机上点「信任」）。
2. 打开 Sideloadly，iPhone 连着电脑。
3. 把 `NavDisplaySender-unsigned.ipa` 拖进 Sideloadly 的 IPA 框。
4. **Apple ID** 填你自己的（会用来申请免费签名证书）。
5. 点 **Start**，按提示输入 Apple ID 密码和双重认证验证码。
6. 装完在手机上：设置 → 通用 → VPN与设备管理 → 开发者 App → 信任。

### B5. 使用与续签

- 7 天后 App 打不开：重新用 Sideloadly 装一次同一个 IPA（Bundle ID 不变，数据一般保留）。
- 免费账号同时最多 3 个自签 App，装第 4 个会顶掉旧的。
- 想自动续签：装 **AltStore**（需要电脑上常驻 AltServer，且和手机同一 Wi-Fi）。

### 常见报错

| 现象 | 原因 / 处理 |
| --- | --- |
| Actions 里没有这个工作流 | 文件不在仓库根 `.github/workflows/` 下 |
| `xcodegen: command not found` | brew 安装失败，重跑 workflow |
| 编译报 `cannot find 'X' in scope` | 有 Swift 文件漏传，检查 `ios/NavDisplaySender/` 是否 8 个文件都在 |
| Sideloadly `Unable to install` | Bundle ID 冲突，改 `ios/project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 后重新编译 |
| 手机提示「不受信任的开发者」 | 去 设置 → 通用 → VPN与设备管理 里信任 |
| 打开就闪退 | 多半是权限弹窗被拒；删掉 App 重装，首次打开时允许定位和蓝牙 |
| 提示系统版本太低 | 工程最低 iOS 16.0，系统低于 16 装不上 |

---

## 方案 C：云 Mac

MacinCloud、Scaleway、AWS EC2 Mac 都能租到 macOS。

- 适合：编译、调试、长期开发。
- 不适合：直接把 App 装到你手上的 iPhone——云机器碰不到你的手机（除非做 USB 转发/同局域网无线调试，配置很折腾）。
- 如果只是想装一次，方案 A/B 更省事。

---

## 为什么不能由我直接装

编译 iOS App 必须用 Apple 的 iOS SDK（只有 macOS 上有），签名必须用 **你自己的 Apple ID**（涉及双重认证，不能代填）；安装还要你的手机连上那台电脑。这三件事都不在我这台 Windows 机器上，所以我只能把工程、自动编译和安装步骤准备好。
