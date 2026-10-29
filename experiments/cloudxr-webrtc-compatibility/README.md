# 同一 Windows 下双路 WebRTC 桌面验证

**这不是现有 Vision Pro App 的一带二实现。** 两个桌面模拟客户端已同时接收真实 CloudXR 视频；Vision Pro Safari 没有测试，现有原生 App 也没有改动。用户选择只使用现有 App，并在当前条件不可行时结束尝试，本轮实验已结束。

## 结果

2026-10-29，CloudXR Runtime 6.2.3、CloudXR.js 6.4.0、IWER 2.7.0、RTX 5070，在同一 Windows 11 Pro build 26200 中运行两套服务、两份 OpenXR 方块应用、两个浏览器页。

| 检查 | 实测结果 |
| --- | --- |
| 两个客户端进入 streaming 且收到真实视频帧 | 通过，截图中可见各自方块画面 |
| 连续状态采样 | 30/30 次两路均为新鲜的 streaming 状态 |
| 采样首末间隔 | 29.3 秒 |
| 该段 A/B 新增视频帧 | 1397 / 1408 |
| 该段 A/B 新增跟踪数据发送次数 | 1739 / 1740 |
| B 模拟头部右移 0.5 米 | B 画面位置改变，A 未施加同样位移 |
| Vision Pro 原生 App 同时串流 | 未通过，见 [原生真机实验](../cloudxr-headset-test/RESULTS.md) |
| Vision Pro Safari、注视点、手势、共享场景 | 未测试或实现 |

本次运行标识为 `20261029-065642-420`，采样报告为忽略目录中的 `measurement-20261029-070350.json`。两个桌面页的最终截图保存在 `out/seat-a.png` 与 `out/seat-b-moved.png`；原始运行数据与截图不提交 Git。

## 观察到的端口行为

两路均设置 `device-profile=auto-webrtc`、`enable-ice=true`，信令分别为 50110/50210，媒体配置分别为 50120/50220。实测视频传输没有绑定到这两个配置媒体端口；SDK A 进程占用 UDP 47998，SDK B 进程占用 UDP 57383，并能同时传输视频。

因此这次成功应归因于 WebRTC 连接路径下的独立协商/端口回退，不能表述为原生视频固定端口已经被修改。原生路径启用 ICE 后仍然因 RTP 视频端口冲突失败。两种传输路径的结果不能混用。

## 复现桌面检查

先按基础实验构建 `CloudXrProbe.exe`，并按头显实验的构建脚本准备方块程序与包含清理 Job 类的 WPF 程序。然后在仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-webrtc-compatibility\Build-WebRtcTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-webrtc-compatibility\Start-WebRtcTest.ps1
```

分别在电脑浏览器打开 `http://127.0.0.1:55300/?seat=a` 与 `?seat=b`，点击连接。运行中可执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-webrtc-compatibility\Measure-WebRtcTest.ps1 -Seconds 30
```

默认 10 分钟后，协调脚本通过自己的 Windows Job 关闭服务、方块程序和本机网页服务器；也可以在协调脚本终端按 Ctrl+C，或写入本次运行的 `stop` 文件触发同样清理。

此页面始终强制安装 IWER，用于电脑模拟，不能放到 Vision Pro 上当作真实头部跟踪客户端。页面与遥测服务器仅监听 loopback，SDK 信令仍可能监听所有接口；实验使用无认证的本地开发 WebSocket，不作为部署配置提供。

NGC tarball 经官方元数据中的 SHA-256 校验后使用，SDK 本身未修改。依赖按锁文件安装，构建时不执行 npm 安装脚本。CloudXR.js 6.4 的 `connect()` 返回 void，通过回调报告连接状态；旧示例中对返回值的布尔检查不适用这一版本。

## 适用范围

这说明同一主机的两套运行时在 WebRTC 路径中可同时传输该轻量示例；它不构成厂商多会话支持声明，也不证明真实头显、4K、90 Hz、动态 foveation 或 Unity 多人场景可用。

[NVIDIA 当前 CloudXR.js 头显要求](https://docs.nvidia.com/cloudxr-sdk/latest/requirement/cloudxrjs_req.html)列出 Quest 和 Pico，未列出 Vision Pro Safari。[Apple 的 visionOS WebXR 说明](https://developer.apple.com/videos/play/wwdc2026/8004/?time=2013)说明 Safari 的 WebXR 支持，但这不能替代 CloudXR.js 在 Vision Pro 上的兼容性验证。

本轮收尾时已关闭测试进程。原单用户程序、Unity 项目、visionOS 客户端源码与 Windows 组件保持实验前状态。
