<p align="center">
  <img src="native/Resources/MacScopeIcon.png" width="128" alt="MacScope 图标">
</p>

<h1 align="center">MacScope</h1>

<p align="center">
  <strong>为 macOS 独占打造的轻量系统监控与维护工具</strong>
</p>

<p align="center">
  看清资源占用，管理活跃进程，释放磁盘空间，干净卸载应用。
</p>

<p align="center">
  <a href="https://github.com/shenmuoso/mac-scope/releases"><strong>下载最新版</strong></a>
  ·
  <a href="#核心功能">功能介绍</a>
  ·
  <a href="https://github.com/shenmuoso/mac-scope/issues">反馈问题</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-0.4.9-1677ff" alt="Version 0.4.9">
  <img src="https://img.shields.io/badge/macOS-13%2B-111111?logo=apple" alt="macOS 13+">
  <img src="https://img.shields.io/badge/SwiftUI%20%2B%20AppKit-Native-f05138?logo=swift" alt="SwiftUI and AppKit">
  <img src="https://img.shields.io/badge/language-English%20%7C%20简体中文-34c759" alt="English and Simplified Chinese">
</p>

> [!TIP]
> **0.4.9 新增进程来源识别和软件分类视图。** 区分系统软件或服务、已安装软件、插件或工具，并聚合查看同一软件的关联进程与资源占用。

MacScope 把一台 Mac 最值得关注的状态集中在一个清爽的原生界面中。它由 SwiftUI 与 AppKit 构建，不包含 Electron、内置浏览器或额外运行时；无需终端、Python 和 Homebrew，安装后即可使用。0.4.9 的 DMG 约 `3.9 MB`，轻巧，但该有的监控与维护能力都在。

![MacScope 系统概览、资源状态与进程排行](docs/images/macscope-overview-0.4.9.png)

## 为什么选择 MacScope

| | 你得到的体验 |
| --- | --- |
| **真正原生** | 标准 macOS 窗口、菜单、表格、设置、授权对话框与深浅色外观 |
| **轻量直接** | 小体积、无额外运行时，不用为了看资源占用再运行一个沉重的网页容器 |
| **信息集中** | CPU、温度、内存、磁盘、网络、进程和清理工具都在同一个应用里 |
| **操作透明** | 扫描结果、文件路径、处理进度和失败原因都清晰可见，删除前由你决定 |
| **本地优先** | 监控与文件分析均在本机完成，不上传系统状态和扫描结果 |

## 核心功能

### 原生菜单栏监控

不必一直把窗口放在桌面上。MacScope 可以常驻菜单栏，用最短的视线距离告诉你 Mac 当前是否繁忙。

- 只显示黑白剪影图标，或紧凑显示最多三个实时指标。
- 自由选择 CPU、内存、磁盘、网络和温度，并调整显示顺序。
- 点击图标展开看板，查看各项指标最近 1 分钟的变化。
- 查看按 CPU、内存、磁盘或网络排序的 Top 进程。
- 自定义看板模块与进程数量；关闭主窗口后仍可继续监控。

### 实时资源监控

当风扇突然加速、机器发热或网络变慢时，不再靠猜。

- **CPU：** 总占用、用户占用、系统占用与 SoC 温度。
- **内存：** 已用、总量、可用量与实时占用比例。
- **磁盘：** 数据卷容量、读取速率和写入速率。
- **网络：** 实时下载与上传速率。
- **动态状态色：** 根据占用率、网速和温度区间快速识别当前状态。
- **灵活刷新：** 支持暂停、立即刷新，以及 `0.5`、`1`、`2`、`5` 秒刷新频率。

### 进程监控与管理

一个表格看清是谁正在消耗你的 Mac，并直接采取行动。

- 集中查看进程名称、PID、CPU、内存、磁盘读写、网络上下行、线程数和运行时间。
- 点击任意表头升序或降序排序，快速找到资源占用最高的进程。
- 区分系统软件或服务、已安装软件、插件或工具及其他来源，并支持来源筛选。
- 按软件分类关联进程，汇总 CPU、内存、磁盘与网络占用，展开后可继续按表头排序子进程。
- 按进程、软件名称、Bundle ID 或 PID 搜索，Top 行数可设置为 5、10、20 或 50。
- 双击进程打开详情，查看最近 1 分钟的 CPU、内存与 I/O 趋势。
- 支持正常退出与强制退出，并在执行前进行确认。

### 垃圾扫描与清理

清理不是一个模糊的“立即加速”按钮。MacScope 会先告诉你找到了什么，再由你决定删除什么。

- 扫描用户缓存、日志、诊断报告和开发者文件。
- 按类别查看大小、路径和具体项目，并支持逐项选择。
- 清理时显示当前文件、总体进度和每一项处理结果。
- 缓存可设置为移到废纸篓或永久删除，默认采用更稳妥的废纸篓模式。
- 无法处理的项目保留明确原因，解决权限问题后可以重试。

![MacScope 垃圾扫描、项目选择与清理结果](docs/images/macscope-junk-cleanup.png)

### 应用卸载与残留清除

卸载应用不应只把一个图标拖走。MacScope 将应用本体与相关数据放在同一个确认流程中处理。

- 扫描标准应用目录并显示应用状态、位置和大小。
- 识别 Bundle ID、相关数据以及系统中已注册的其他应用副本。
- 在独立确认界面中检查应用本体和每一项残留文件。
- 显示卸载路径、实时进度、成功结果和失败原因。
- 先确认应用本体能够移除，再处理相关数据，避免留下一个被清空数据但仍存在的应用。

![MacScope 应用扫描、卸载与残留清除](docs/images/macscope-applications.png)

### 磁盘与资源管理

空间去了哪里，MacScope 帮你把答案列出来。

| 工具 | 用途 |
| --- | --- |
| **大文件** | 在指定文件夹中查找超过阈值的文件，按大小快速定位空间占用 |
| **重复文件** | 通过文件大小和内容哈希确认重复项，并确保每组至少保留一份 |
| **快速内存释放** | 请求 macOS 回收符合条件的非活跃文件缓存，不关闭正在运行的应用 |

大文件和重复文件默认扫描当前用户的 `Downloads`、`Desktop`、`Documents` 和 `Movies`，也可以在设置中添加或移除扫描目录。

## 常见使用场景

- **Mac 突然发热：** 按 CPU 排序，找出持续高占用的进程，再查看它最近 1 分钟的活动。
- **内存压力升高：** 按内存排序确认主要占用者，必要时使用快速内存释放。
- **磁盘空间不足：** 依次检查垃圾、大文件和重复文件，把可回收空间变成清晰列表。
- **应用卸载不干净：** 选择应用，同时检查相关数据和其他副本，再统一确认处理。
- **只想快速看一眼：** 在菜单栏显示 CPU、内存或网速，不必打开主窗口。

## 下载与安装

1. 前往 [GitHub Releases](https://github.com/shenmuoso/mac-scope/releases) 下载最新的 `MacScope-*.dmg`。
2. 打开 DMG，将 `MacScope.app` 拖入 `Applications` 文件夹。
3. 从“应用程序”启动 MacScope。

> [!IMPORTANT]
> 当前 Release 使用 ad-hoc 开发签名，尚未完成 Apple Developer ID 公证。如果 Gatekeeper 阻止首次启动，请先确认文件来自本仓库，然后在 Finder 中右键 `MacScope.app` 并选择“打开”。MacScope 不会要求你在应用自己的界面中输入管理员密码。

## 个性化设置

所有设置使用 macOS `UserDefaults` 持久化，重启应用后仍会保留。

| 类别 | 可配置内容 |
| --- | --- |
| **监控** | 0.5/1/2/5 秒刷新频率、Top 5/10/20/50、摄氏度或华氏度 |
| **菜单栏** | 开关、仅图标或紧凑数据、最多三个指标、模块顺序、进程排序与数量 |
| **外观** | 跟随系统、浅色、深色、主题、侧栏透明度和两套 Dock 图标 |
| **清理** | 缓存处理方式、清理前确认、大文件阈值、重复文件阈值和扫描目录 |
| **语言** | English 或简体中文；默认使用 English |

设置文件由系统保存在：

```text
~/Library/Preferences/com.shenmuoso.macscope.plist
```

## 隐私、权限与安全

- 系统指标、进程信息和扫描结果只在本机处理，MacScope 不上传这些数据。
- 文件默认移到废纸篓，MacScope 不会自动清空废纸篓。
- 应用、应用残留、大文件和重复文件始终移到废纸篓，不会直接永久删除。
- 只有可重建缓存和开发者文件可以在设置允许时永久删除。
- 某些用户资源库路径需要“完全磁盘访问权限”，可从“设置 > 清理 > 权限”打开对应系统设置。
- 移除受保护应用或释放文件缓存时，MacScope 使用 macOS 标准管理员授权对话框。
- MacScope 不读取、不接收也不保存管理员密码。
- 扫描会跳过符号链接和应用包内部，避免越过用户选择的目录边界。

## 系统要求

- macOS 13 Ventura 或更高版本。
- 当前 GitHub Release DMG 面向 Apple Silicon Mac；Intel Mac 可以使用匹配的 Swift 工具链从源码构建。
- 原生应用无需 Python、Textual、Homebrew 或其他运行时。
- 温度读取依赖当前机型和 macOS 暴露的 IOHID 传感器。温度显示“不可用”时，其他监控功能仍可正常工作。

## 常见问题

### 为什么首次采样的 CPU、磁盘或网络速率是 0？

速率需要比较前后两次系统计数才能计算。等待一个刷新周期后即可显示实时值。

### 为什么有些文件显示需要完全磁盘访问权限？

macOS 会保护部分用户资源库目录。MacScope 只会明确提示权限问题，不会绕过系统保护；授权后重新扫描即可。

### 管理员授权时，MacScope 会看到我的密码吗？

不会。密码输入框由 macOS 提供，认证过程由系统处理，MacScope 只接收操作是否获准的结果。

### 为什么温度显示“不可用”？

不同 Mac 和 macOS 版本暴露的传感器不同。这不影响 CPU、内存、磁盘、网络和进程监控。

## 从源码构建

需要 macOS 13+、Xcode Command Line Tools，以及推荐的 Swift 6 工具链。

```bash
git clone git@github.com:shenmuoso/mac-scope.git
cd mac-scope
native/scripts/run_app.sh debug
```

只构建原生 App：

```bash
native/scripts/build_app.sh release
```

构建可发布的 DMG：

```bash
native/scripts/build_dmg.sh release
```

默认输出：

```text
native/build/MacScope-0.4.9.dmg
```

仓库仍保留早期 Python/Textual 终端版本用于兼容与历史参考，但它不是当前原生应用的运行依赖。

## 项目与反馈

- [下载与历史版本](https://github.com/shenmuoso/mac-scope/releases)
- [提交问题或功能建议](https://github.com/shenmuoso/mac-scope/issues)
- [项目主页](https://github.com/shenmuoso/mac-scope)
- [作者主页](https://github.com/shenmuoso)
