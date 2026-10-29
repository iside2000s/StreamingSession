# 2026-10-29 双实例实测结果

## 结论

在当前 Windows 主机上，**无需虚拟机、无需改动 CloudXR DLL，已验证两套运行时和两套 D3D11 OpenXR 会话可以同时存在，并连接到各自的实例**。

关键是同时隔离进程临时目录、网络端口，以及使用 Stream Manager 时的 RPC 管道。仅仅多开应用或修改端口仍会失败。

这是一项有范围限制的实验结果，尚未实现或证明“两台 Vision Pro 同时接收画面并进行多人交互”。

## 环境

- 日期：2026-10-29，Asia/Shanghai。
- 主机：Intel Core i7-14700KF；NVIDIA GeForce RTX 5070，约 12 GB 显存。
- CloudXR Runtime：6.2.3；Stream Manager：6.1.0。
- 原项目基线：`dfe136645508aa67e8f616f6918c9702c67bf547`。
- 使用 SDK 的 `apple-vision-pro` profile；关闭音频、麦克风与 foveation。
- 使用仓库内的 OpenXR Loader，通过进程环境指定运行时清单；未改动系统 ActiveRuntime 注册表。
- 编译：Visual Studio 2022，MSVC v143，Windows SDK 10.0.26100.0；x64，C++17，警告视为错误。仅对厂商头文件中的匿名 union 局部关闭 C4201。

## 最终验证矩阵

三组均通过各自的预期检查。对照组的预期是第二路失败，其余两组的预期是两路隔离成功。

| 用例 | 本地结果目录（UTC 时间标识） | 实测结果 |
| --- | --- | --- |
| 共享 TMP/TEMP，直接调用 SDK | `results/20261029-041232-505/` | A 正常；B 返回 `NV_CXR_STARTUP_FAILED`（-2），日志确认 IPC 管道冲突；A 仍可连接 |
| 独立 TMP/TEMP，直接调用 SDK | `results/20261029-041237-423/` | A/B 均启动；连接路由、并发 D3D11 资源和关闭隔离均通过 |
| 独立 TMP/TEMP，分别通过 Stream Manager 启动 | `results/20261029-041253-008/` | A/B 均启动；连接路由、并发 D3D11 资源和关闭隔离均通过 |

每组目录中都有 `summary.json`、探针输出和 SDK 日志。原始日志仅保留在本地，未加入 Git；它们可以用同目录的 `Run-Experiment.ps1` 重现。

## 观察到的具体行为

1. 对照组的第二套运行时在创建管道时得到 Win32 错误 5。日志指出已有探针进程拥有该管道，随后返回 `XRT_ERROR_IPC_MAINLOOP_FAILED_TO_INIT`。发生冲突的名称为 `\\.\pipe\<TMP>/ipc_cloudxr`。
2. 给两路进程传入不同的 TMP/TEMP 后，两套运行时均完成启动。A、B 的 OpenXR 客户端分别继承对应目录。
3. B 的客户端创建 OpenXR 实例并成功查询系统时，B 的应用连接事件增加一次，A 的事件计数没有增加。
4. 两个客户端同时创建 D3D11 OpenXR 会话，每个会话各创建两个 256×256 swapchain；两套资源有实际存活时间重叠。
5. 停止 B 后，A 的客户端仍能创建实例并查询系统；B 的客户端创建实例失败，且未产生误连 A 的连接事件。
6. 两个信令端口均可观察到监听：`0.0.0.0:50110`、`0.0.0.0:50210`。配置的 `endpoint-ip` 为媒体公开地址，并未在本次测试中把监听范围收窄到 loopback。
7. 每次测试结束后，探针进程均退出，Stream Manager 子进程由其专属 Job 清理；原目录的 WPF 窗口仍在运行。

## 未验证的部分

- 尚未有两台真实头显同时连接，没有调用 `xrBeginSession` / `xrEndFrame` 提交图像，也没有验证两路 NVENC 编码、90 FPS、输入延迟或大场景显存占用。
- SDK 日志在当前 RTX 5070 上包含 `Unsupported GPU detected` 警告。基础图形资源创建成功不能替代实际编码和设备兼容性测试。
- 尚未验证动态注视点、音频、麦克风、断网恢复、长时间运行和更多用户数量。
- 已只读检查 `D:\GitClone\MyStreamingClient`。它使用 Apple FoveatedStreaming 的 `.systemDiscovered` / `.local(ipAddress:port:)` 本地发现与配对流程。公开的握手消息没有独立的媒体/信令端口字段；不同端口的双运行时还没有与该流程完成接通。不能把会话管理端口输入直接当作已验证的底层串流端口选择器。
- 两份 Unity 实例还没有加入多人状态同步、物体交互所有权或远端人物显示。

NVIDIA 官方对单操作系统实例的公开支持范围仍是一路会话。本实验只证明上述特定版本和主机上的基础机制；并不推翻其支持声明。

## 保留的项目状态

改动仅在独立开发仓库的 `codex/multi-vision-pro` 分支中增加实验工具和文档。原 `StreamingSession`、Unity 项目、Vision Pro 客户端源码均未修改；运行时 DLL 前后 SHA-256 相同。

| DLL | SHA-256 |
| --- | --- |
| cloudxr.dll | `6455337BDA3D9A60469D4F043A517445D3F636E888A50DF078C8B6962C320220` |
| openxr_cloudxr.dll | `8B46030B2F9B8C2DA6D50D95E7F5CCAB4994130221F8B37E7D08F25CAB6BFA68` |
| NvStreamServer.dll | `7DF7848824C2D2A28175DE9867D73130C17D0B2096AA97D984DFCF92F0D01A79` |

下一阶段应先打通一台真实 Vision Pro 到一个自定义端口实例的配对和媒体连接，再扩展为两台同时连接并测量编码负载；成功之后再接入 Unity 多人同步。
