# 排错手册

## 屏幕

**全黑，背光也不亮**

- 量 VCC-GND 有没有 3.3V。
- BLK 必须接高电平/接 GPIO 并输出 PWM；有的模块 BLK 悬空就是灭的。
- 有些模块 BLK 是低电平点亮，把 `display.cpp` 里 `cfg.invert = true`（背光反相）试试。

**全白，背光亮但没图像**

- 背光正常说明供电 OK，问题在 SPI 或复位：
  - DC / CS / RST 是否和 `config.h` 一致
  - 模块没有 CS 脚时，把 `TFT_CS` 设成 `-1` 并把 CS 接地
  - RST 没接的话把 `TFT_RST` 设为 `-1`（用软复位），但建议接
- 串口应该有 `[ui] 屏幕 320x240 旋转 1`，没有就是初始化就挂了。

**花屏、雪花、闪**

- 杜邦线太长/接触不良，换短线，GND 多接一根。
- 把 `freq_write` 从 40000000 降到 27000000 或 20000000。
- 电源不够：换 USB 口/线，别用充电宝的低电流口。

**颜色反了（像底片）**

- `config.h` → `TFT_INVERT_COLOR` 0/1 对调。

**红蓝互换**

- `config.h` → `TFT_RGB_ORDER_BGR` 0/1 对调。

**图像整体偏移/有黑边**

- 某些 240x320 面板有 80 像素的 RAM 偏移，改 `display.cpp`：

  ```cpp
  cfg.offset_x = 0;
  cfg.offset_y = 0;
  ```

  试 `offset_x = 0/80`、`offset_y = 0/80` 的组合。

**字是方块/乱码**

- 中文用的是 LovyanGFX 自带 efont 点阵字库，只有常用汉字。生僻字会显示空白或方块，属于正常。
- 如果整屏中文都是方块，说明字库没编进去，确认 `lib_deps` 里的 LovyanGFX 是 1.2.x，并且编译时没有把 `efont` 目录排除。

**屏幕方向不对**

- `config.h` → `TFT_ROTATION`：0/2 是竖屏 240x320，1/3 是横屏 320x240。
- 界面布局是按 **1（横屏 320x240）** 设计的，改成竖屏需要自己调 `ui.cpp` 里的坐标。

## 蓝牙

**手机搜不到设备**

- 串口看有没有 `[ble] 广播中，名称 "ESP32-Navi"`。
- App 是按 **服务 UUID** 过滤扫描的，不是按名字，所以设备名改了也能搜到。
- 如果之前配对过又改了固件，去手机 设置→蓝牙 里「忽略此设备」，重启 App。
- ESP32 只支持 BLE，不支持经典蓝牙；iPhone 的「蓝牙」设置页里本来就不会显示它。

**连上几秒就断**

- 供电不稳（尤其背光全亮时），换个 USB 电源。
- 距离太远/有金属遮挡。
- 固件重启了：看串口有没有 panic 或 brownout。

**包数在涨但屏幕不动**

- 屏幕在「演示模式」：长按 BOOT 键退出，或串口发任意数据后固件会自动退出演示。
- `[nav] JSON 解析失败`：协议字段对不上，对照 `docs/protocol.md`。
- 屏幕「数据超时」：手机 App 被系统挂起了，回到前台即可。

## 地图模式

**画面停住一两秒不动**

正常。手机正在通过 BLE 传新地图（约 10~20 KB），固件在收完并校验 CRC 前会冻结画面，避免画出半包数据，传完自动恢复。

**只看到一条绿色路线，没有周边灰色道路**

手机端没拿到 OSM 数据：

- 检查手机能否访问 `overpass-api.de`（国内可能慢或被限流）。
- 把 `MapPayload.swift` 里的 URL 换成镜像，例如 `https://overpass.kumi.systems/api/interpreter`。
- 拉不到时会退化成「只有路线」的地图，转向提示不受影响。

**地图位置/方向不对**

- **整体偏移几百米**：中国坐标系的坑。iOS 定位和 Apple 地图路线是 GCJ-02，OSM 是 WGS-84。App 默认会把 OSM 道路转到 GCJ-02（`MapPayload.swift` → `GCJ.enabled`）；如果你那边实测方向相反，把它改成 `false`。
- 参考点和坐标单位必须两边一致：`MAP_BEGIN` 里 `unit=2`（米），blob 里是相对参考点的 int16。
- 航向来自手机罗盘/轨迹；静止时可能乱转，开动后就正常。

**地图一直加载不出来**

串口看有没有 `[map] 开始接收` 和 `[map] 地图就绪`：

- 只有「开始接收」没有「就绪」→ 传输中断，查 BLE 距离/干扰；或地图超过 24 KB 被拒绝（日志 `包非法`）。
- App 端 `mapStatus` 会显示「周边道路不可用 / 地图为空 / 地图 xx KB」。

## 编译

**`platformio.ini` 里的平台下载很慢**

国内网络可以把 `platform = espressif32@6.9.0` 换成已安装的本地版本，或者挂代理。首次编译要下几百 MB 工具链，只能等一次。

**`xtensa-esp32s3-elf-gcc: error: CreateProcess: No such file or directory`**

Windows 上编译命令超过 32767 字符（EXE 命令行上限）时会这样。ESP32 的 include 路径有 200 多条，项目路径一长就会超。

- 把工程放到短路径，例如 `C:\nav\`，或
- 临时做个短盘符映射再从短路径编译：

  ```bat
  subst X: C:\你的\很长\的\路径
  cd /d X:\esp32-nav-display\firmware
  pio run
  ```

**`esptool: ModuleNotFoundError: No module named 'esptool'`**

用的是嵌入式 Python（没有 site-packages）时，`esptool.py` 找不到自己的包。把 `tool-esptoolpy` 目录加进 Python 的搜索路径，或者换成标准 Python 装 PlatformIO。

**`region 'iram0_0_seg' overflowed`**

屏幕帧缓冲 + BLE 占满了内部 RAM。本项目在没有 PSRAM 时会自动退回「直画」模式；如果还溢出：

- 把 `ui.cpp` 里 `s_canvas.setColorDepth(16)` 改成 `8`（颜色会少很多，不推荐）
- 或者确认开发板真的是 N16R8 并解开 `platformio.ini` 里 PSRAM 的两行注释

**`undefined reference to efontCN_16`**

LovyanGFX 版本太老，升级到 `^1.2.0`。

**NimBLE 编译报一堆 `CONFIG_BT_NIMBLE_*` 未定义**

平台和库版本不匹配。本项目锁定 `espressif32@6.9.0`（Arduino core 2.0.17）+ `NimBLE-Arduino@1.4.3`，不要单独升级其中一个。

## 其他

**开机就进下载模式 / 一直重启**

- 别把屏幕的 BLK、CS 接到 GPIO0/3/45/46。
- 用 USB 供电时，某些板子的 BOOT 键被外壳卡住。

**怎么恢复出厂**

没有存储任何配置，重新烧录即可。

**没有手机想验证屏幕**

长按 BOOT 键 2 秒进入演示模式，会循环播放直行/左转/右转/掉头/环岛/到达的界面，再长按退出。
