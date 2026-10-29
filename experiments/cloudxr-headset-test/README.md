# 两台 Vision Pro 真机串流实验

这是 `cloudxr-multi-instance` 基础探针之后的真机接入实验。使用当前已安装的 `MyStreamingClient`，无需在 Windows 编译 visionOS 应用。

**2026-10-29 实测：两路可以分别连接，但同时串流失败。** 第二路占用原生媒体端口后，第一路重连在 UDP 47998 上报 Windows 10048，无法建立视频传输。配置不同的 `mediaPort` 没有隔离本次 Apple 原生传输的视频端口。详见 [真机结果](RESULTS.md)。

## 当前结构

- 每台设备对应一个独立 Windows 配对窗口、Stream Manager、CloudXR Runtime 和 OpenXR 方块应用。
- 每组进程继承自己的 TMP/TEMP。每路使用自己的管理端口、信令端口、RPC 管道、日志和配对 ServerID。
- A 的会话管理端口为 55001，B 为 55002。两者均使用当前客户端的 bundle ID `com.cloudxr.visionos`。
- 配对请求先登记设备的源 IPv4 地址。公共信令入口 TCP 48322 按该地址转发到 A 的 50110 或 B 的 50210，TLS 内容原样通过，不读取或改写认证信息。
- 未登记的设备，以及同时被两路登记的同一地址，会被拒绝，避免猜测目标实例。

这条路径要求客户端在当前局域网中具有不同且稳定的源 IP。NAT 汇聚、漫游换 IP 和运行时版本变化不在当前验证范围内。信令中继是否能与 CloudXR 的原生媒体路径正确配合，必须由真机画面和运行时状态共同验证。

## 构建与启动

在仓库根目录运行，HostAddress 替换为电脑当前的局域网 IPv4：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-headset-test\Start-HeadsetTest.ps1 -HostAddress 192.168.115.147
```

脚本会编译实验版 WPF 应用、信令中继、路由集成检查和方块示例。所有构建输出位于忽略的 `out/` 中，现有 `bin/Release` 不会被构建覆盖。SDK 运行文件复制到实验输出目录。

发现已有 CloudXR 管理器、运行时、信令中继或端口占用时，脚本会退出，不会关闭用户现有程序。请仅通过本脚本启动实验；原始单用户程序的进程清理逻辑不适用于同时运行多套服务。

脚本运行期间保留一个进程清理 Job。两个配对窗口需要显示在桌面上供用户扫码，其余辅助窗口隐藏运行。默认最长运行 60 分钟，然后自动清理本次启动的进程。

可使用 `-SkipBuild` 复用已经编译的程序，使用 `-PrepareOnly` 仅生成配置。不要在真机测试进行中重新构建同一输出目录。

## 设备连接

1. 第一台客户端输入电脑 IP、端口 **55001**，点击 Connect，扫描 **CloudXR experiment — Seat A** 的二维码。
2. 确认第一路画面、转头正常，保持设备佩戴和连接。
3. 第二台客户端输入相同电脑 IP、端口 **55002**，扫描 **Seat B** 的二维码。
4. 两台同时保持佩戴，检查画面、独立转头和手部输入。取下设备会触发正常的 PAUSED 状态，不能据此确认两路同时处于活动状态。

测试采用轻量方块示例，开启 runtime foveation，unwarped width 为 1920，保留 alpha，关闭音频和麦克风。这不是原 Unity 场景的性能或多人交互测试。

## 状态与停止

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-headset-test\Get-HeadsetTestStatus.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-headset-test\Measure-HeadsetTest.ps1 -Seconds 30
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-headset-test\Stop-HeadsetTest.ps1
```

日志与运行配置保存在 `state/<本次运行标识>/`；`state/latest-run.json` 记录当前进程和停止文件。状态脚本中的 `Headset=True` 来自 SDK 状态，不替代用户对实际画面和独立视角的确认。

`ObservedMediaBindConflicts` 列出本次运行日志中曾经出现 Windows 10048 的端口；它是历史冲突记录。测量脚本记录两路 SDK 连接状态重叠的时长，不能证明画面或交互正常。

仅设置了实验子进程环境，没有修改系统环境变量、机器级 OpenXR 注册表、网卡地址或防火墙。原目录、Unity 项目和 visionOS 客户端源码不受本实验构建影响。

原生媒体端口不能仅根据 YAML 中的 `mediaPort` 推断。本次实际观察到 SDK 使用 47998、47999、48005、48008、48012 等 UDP 端口；两路同时使用时已确认冲突。因此当前脚本用于复现实验和诊断，不能作为一带二成品使用。

## 自动检查

构建脚本运行了真实 TCP 集成检查：不同源地址进入各自后端、16384 字节二进制内容保持一致、TCP 半关闭后反向响应完整、未知地址被拒绝、重复地址被拒绝。它们验证中继本身，不验证 CloudXR 的视频传输。

双运行时、OpenXR 资源和进程临时目录隔离的独立验证见 [基础实验](../cloudxr-multi-instance/README.md)。
