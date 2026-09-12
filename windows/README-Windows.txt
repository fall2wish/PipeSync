======================================================================
                     PipeSync Windows 客户端快速指南                   
======================================================================

欢迎使用 PipeSync Windows 客户端！
PipeSync 是一款采用 2PC Verify & Purge 强一致性事务保障数据零隐式损毁的高性能数据同步归档工具。

【组件说明】
1. PipeSyncTray.exe  - 托盘常驻宿主程序 (推荐从此处启动)
2. pipesync.exe      - 核心守护进程与 CLI 命令行工具
3. librclone.dll     - C-Shared FFI 进程内网络与存储传输引擎
4. libpipesync_quickjs.dll - 16MB 隔离沙盒 JavaScript 规则执行引擎

【使用方法】
1. 双击运行 `PipeSyncTray.exe`：
   - 系统将在屏幕右下角任务栏通知区域显示 PipeSync 图标。
   - 自动在后台静默启动守护进程，无黑框干扰。
   - 单击或双击托盘图标，即可在默认浏览器中打开类似 Syncthing 的 Web 管理控制台 (默认地址: http://127.0.0.1:8384)。

2. 右下角托盘功能 (右键单击图标)：
   - 顶部状态栏：实时查看服务运行状态 (如 "● PipeSync: 运行中 (端口 8384)")
   - 打开 Web 管理控制台
   - [✓] 开机自动启动：一键开启或取消 Windows 开机自启 (通过注册表 HKCU\...\Run)
   - 立即同步全部文件夹 (Rescan)
   - 重启后台服务
   - 退出 PipeSync (安全退出并终止后台服务)

3. 命令行调用 (适用于脚本与高级用户)：
   - 查看版本:      pipesync.exe version
   - 手动运行任务:  pipesync.exe run --source D:\Photos --dest \\nas\backup
   - 启动控制台:    pipesync.exe serve --port 8384
   - 查看插件:      pipesync.exe plugins
   - AI Copilot:   pipesync.exe copilot

项目官网与源码: https://github.com/fall2wish/PipeSync
许可证: PolyForm Noncommercial License 1.0.0
======================================================================
