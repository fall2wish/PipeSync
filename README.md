# PipeSync

> 基于 Flutter 与 librclone FFI 的高性能移动跨平台数据管道系统，采用 QuickJS 沙盒与强一致性两阶段提交（2PC Verify & Purge）保障数据零损清理。

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/License-PolyForm_Noncommercial_1.0.0-blue.svg)](https://polyformproject.org/licenses/noncommercial/1.0.0)
[![CI Build & Test](https://img.shields.io/badge/CI-Passing-brightgreen.svg)]()
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20Linux%20%7C%20macOS%20%7C%20Windows-blue.svg)]()

---

## 📖 项目简介

**PipeSync** 是一套专为移动端严苛安全与权限生命周期设计的数据归档与同步系统。在恪守“**零隐式破坏（绝对数据安全）**”核心原则的前提下，提供跨协议（SMB/WebDAV/SFTP）底层硬件级吞吐与安全脚本扩展能力。

### 核心技术决策

- **统一应用框架（Flutter / Dart 3.x）**：利用 `dart:ffi` 操作底层 C 指针与共享堆内存，规避传统 JNI/JSI 序列化损耗；独立的 Worker Isolate 保障长周期 I/O 不阻塞界面渲染。
- **底层传输与校验引擎（librclone C-Shared FFI）**：规避 Android 10+（API 29+）对私有目录 `exec()` 的 W^X 安全拦截以及 iOS 禁止衍生子进程的限制，将 Rclone 编译为原生共享库，实现进程内内存级 RPC 调度。
- **扩展解释沙盒（QuickJS via FFI）**：纯 C 嵌入式解释器，启动延迟低（<2MB 运行时），受控内存配额硬限制（16 MB）与执行超时熔断，天然免疫 JIT 审计限制。
- **双端系统生命周期深度适配**：
  - **Android**：声明 `MANAGE_EXTERNAL_STORAGE` 直连底层 POSIX 接口，实现 MediaStore 同步清除机制杜绝“幽灵缩略图”；设计 5.5 小时 WorkManager 分段接力架构规避 Android 14/15 的 6 小时前台服务硬性熔断。
  - **iOS**：集成 `BackgroundTasks` 夜间充电保活调度，并创新性支持“局域网桌面反向拉取拓扑（Desktop Pull）”，彻底化解移动端后台网络挂起难题。

---

## 🔄 强一致性两阶段提交（2PC Verify & Purge）

为确保源文件物理清理前的绝对安全，PipeSync 严格执行五个原子步骤：

```
[源文件目录]
      │
      ▼
【阶段 1: Pre-Execution】─── QuickJS 插件沙盒过滤 (.tmp/.crdownload) & 日期重命名 ──► 写入 SQLite WAL (PENDING)
      │
      ▼
【阶段 2: Transferring】 ─── 原生计算 Local SHA-256 & 投递 librclone 进程内分块传输 ──► 状态更新 (TRANSFERRING)
      │
      ▼
【阶段 3: Verifying】    ─── 远端 operations/hashsum & operations/stat 强对齐核验 ──► 状态更新 (VERIFYING)
      │
      ├───────────────────────────────┐
   [通过]                          [不一致]
      │                               │
      ▼                               ▼
【阶段 4: Purging】              【事务紧急中止 (ISOLATED_ERROR)】
   • POSIX unlink() 本地删除        • 严禁触碰本地原始文件
   • MediaStore 同步核销脏索引       • 记录冲突审计日志并警报
      │
      ▼
【阶段 5: Committed】   ─── 触发插件 postHook 回调 ──► 事务落盘 (COMMITTED)
```

---

## 📂 项目结构

```text
pipesync/
├── Makefile                          # 构建与测试自动化
├── cli.py                            # CLI 交互执行入口
├── LICENSE                           # PolyForm Noncommercial 1.0.0 许可协议
├── README.md                         # 核心架构与说明文档
├── native/                           # C-Shared librclone FFI 绑定及测试
│   ├── librclone.h
│   ├── librclone.c
│   └── test_librclone.c
├── dart/                             # Flutter / Dart 3.x 跨平台核心模块
│   ├── pubspec.yaml
│   ├── lib/core/ffi/                 # dart:ffi 绑定实现
│   ├── lib/core/scripting/           # QuickJS 沙盒与 PipeContext 注入
│   ├── lib/core/pipeline/            # 2PC 编排事务机
│   └── lib/platform/                 # Android 与 iOS 平台底层适配层
├── plugins/                          # 插件体系与标准 JSON Schema 目录
│   ├── registry.json
│   └── installed/org.pipesync.media-cleaner/
├── engine/                           # 核心调度运行时
├── tests/                            # 单元与端到端集成测试集
└── .github/workflows/                # CI/CD 与 Android APK 自动打包 Action
```

---

## 🚀 快速开始

### 1. 编译原生库与运行测试
```bash
# 编译底层动态库 (librclone.so + libpipesync_quickjs.so)、C 测试程序及 Dart 原生二进制
make compile

# 运行全量测试套件（Native C + Python 集成测试 + Dart 3.x 原生测试，共 27 项通过）
make test
```

### 2. 启动 Syncthing 体验的 Web 控制台与后台守护进程（推荐体验）
```bash
# 启动类似 Syncthing 的实时 Web 控制台与后台文件自动监听守护进程（默认端口 8384，占用时自适应 8385+）
./build/pipesync serve
# 或通过 Python CLI 启动：
./cli.py serve

# 启动后在浏览器打开控制台进行可视化管理：
# http://127.0.0.1:8384 （或提示端口）
```

### 3. 使用 CLI 命令行直接操作
```bash
# 查看版本及原生动态库运行状态
./build/pipesync version   # 或 ./cli.py version

# 执行目录两阶段同步任务 (2PC Verify & Purge)
./build/pipesync run --source /path/to/photos --dest /path/to/nas/backup --db /tmp/pipesync.db

# 检查 SQLite WAL 任务状态机持久化记录
./build/pipesync status --db /tmp/pipesync.db

# 列出插件及完整性校验状态
./build/pipesync plugins

# 使用内置 AI Copilot 规则助手生成并验证 JavaScript IIFE 规则
./build/pipesync copilot

# 查看 Android 原生 WebKit 宿主工程配置与 jniLibs 打包状态
./build/pipesync android   # 或 ./cli.py android
```

---

## 📱 Android 原生内嵌 WebKit 架构（无需外部浏览器）

PipeSync Android 端采用类似 Syncthing-Android 的架构，提供自包含的内嵌 WebKit UI 与底层硬件服务：

- **自包含 WebKit 宿主窗口（`MainActivity.kt`）**：内嵌 `android.webkit.WebView`，通过 127.0.0.1 端口直连进程内管道守护进程，具备离线优雅回退与自动重试机制。
- **底层硬件桥接（`PipeSyncNativeBridge.kt`）**：
  - 注入 `window.PipeSyncNative` 全局对象，支持 Web UI 一键申请并检测 `MANAGE_EXTERNAL_STORAGE`（所有文件管理权限）与系统电池优化白名单。
  - 网页控制台（`syncthing_gui.dart`）自动感知 Android 环境，提供相机 (`DCIM/Camera`)、图库 (`Pictures`)、文档 (`Documents`) 等公共存储目录快速选取预设。
  - 2PC 归档清理（PURGE）物理删除源文件后，Native 桥接自动触发 `MediaStoreSyncHelper` 驱动 `MediaScannerConnection` 彻底清除系统相册“幽灵缩略图”。
- **Android 14/15 保活与分段接力（`TransferForegroundService.kt`）**：
  - 声明 `FOREGROUND_SERVICE_TYPE_DATA_SYNC` 与独立前台通知。
  - 5.5 小时 WorkManager/Timer 周期接力，主动重置 Android 14/15 6小时数据同步超时计数器。
  - 持有高性能 `WakeLock` 与 `WifiLock` 避免亮屏休眠断流。

### Android APK 打包：
```bash
# 1. 确保已通过 make compile 生成底层 jniLibs (.so)
make compile

# 2. 编译生成 Android Release APK
cd android
./gradlew assembleRelease
# 生成 APK: android/app/build/outputs/apk/release/app-release.apk
```

---

## 🪟 Windows 桌面客户端（系统托盘常驻 & 开机自启）

PipeSync 为 Windows 桌面环境提供开箱即用的原生系统托盘宿主程序（`PipeSyncTray.exe`）：

- **右下角托盘静默运行**：无黑框 CMD 终端干扰，双击或单击托盘图标即刻在默认浏览器中调起 Web 控制台（`http://127.0.0.1:8384`）。
- **实时服务状态感知**：托盘悬浮提示或右键菜单顶部直观显示 `● PipeSync: 运行中 (端口 8384)`，具备服务健康探活与自动拉起能力。
- **开机自动启动一键切换**：
  - 右键菜单集成 **`[✓] 开机自动启动`** 选项。
  - 通过操作 Windows 用户注册表（`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`）安全生效，免去手动配置计划任务或放置快捷方式的繁琐操作。
- **快捷运维菜单**：
  - `🌐 打开 Web 管理控制台`
  - `⟳ 立即同步全部文件夹`
  - `🔄 重启后台服务`
  - `✕ 退出 PipeSync`（彻底终止后台服务并退出）

### Windows 编译与运行：
```powershell
# 使用 CMake 编译生成 PipeSyncTray.exe 与 C 动态库
cmake -B build-win -DCMAKE_BUILD_TYPE=Release
cmake --build build-win --config Release

# 编译生成 Windows 后台守护进程 pipesync.exe
dart compile exe dart/bin/pipesync.dart -o build-win/Release/pipesync.exe

# 运行托盘客户端
.\build-win\Release\PipeSyncTray.exe
```

---

## 📄 许可证说明（License）

本项目采用 **[PolyForm Noncommercial License 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0)** 协议。

### 允许的行为（Permitted）
- ✅ **个人免费使用**：允许任何个人出于非商业目的、学习、个人设备备份及学术研究免费使用、编译和运行本项目。
- ✅ **非商业修改与分发**：在保留原作者版权声明的前提下，允许出于非商业目的修改或分享代码。

### 严格禁止的行为（Prohibited）
- ❌ **严禁商业使用**：任何企业、营利性组织或个人不得将本项目源码、编译产物（包括但不限于 APK、`.so` 动态库、CLI 工具）用于任何直接或间接获取商业利益的场景。
- ❌ **严禁闭源集成与转售**：严禁作为付费产品或商业 SaaS/云服务的底层组件进行重新打包与售卖。

### 商业授权获取（Commercial Licensing）
本项目所有商业运营权、商业闭源授权与商业发行权均由原作者独家保留。若需将本项目用于商业场景、企业定制集成或付费应用发行，请联系原作者获取正式商业授权。
