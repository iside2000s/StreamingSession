# CloudXR 单 Windows 双实例实验

这是服务端可行性探针，不是已经完成的双人串流产品。实验使用当前仓库附带的 **CloudXR Runtime 6.2.3 / Stream Manager 6.1.0**，没有改动 NVIDIA DLL，没有 Hook 或二进制补丁。

## 已验证的机制

运行时的 OpenXR IPC 管道名称包含进程临时目录：

```text
\\.\pipe\<进程临时目录>/ipc_cloudxr
```

只改网络端口时，两个进程仍争用同一 IPC 管道。为每一路运行时与其 OpenXR 应用设置相同的、彼此独立的进程级 `TMP` / `TEMP`，可以在本次机器和 SDK 版本上隔离 IPC。日志目录 `NV_CXR_OUTPUT_DIR` 本身不能替代这一步。

环境变量应在创建子进程时传入；部分原生依赖会在进入应用入口函数之前缓存 C 运行库环境。仅在入口函数里调用 `SetEnvironmentVariableW` 并不保证所有 SDK 设置生效。

每一路还需要独立的网络端口；使用 Stream Manager 时，需要额外分开它的 RPC 管道名和 YAML 配置。

| 资源 | A | B |
| --- | --- | --- |
| TMP / TEMP | 本次实验的 `temp-a` | 本次实验的 `temp-b` |
| 信令 TCP 端口 | 50110 | 50210 |
| 媒体 UDP 配置端口 | 50120 | 50220 |
| Stream Manager RPC 管道 | 本次实验唯一的 A 名称 | 本次实验唯一的 B 名称 |

探针使用 `apple-vision-pro` profile。实验关闭音频、麦克风和 foveation，以验证基础隔离。媒体公开地址配置为 `127.0.0.1`；实测信令监听地址仍为 `0.0.0.0`，不能把 `endpoint-ip` 当成经过验证的监听范围限制。

## 运行

前提：Windows x64、Visual Studio 2022 C++ 工具及 Windows SDK，仓库附带的运行时和 OpenXR Loader 文件完整。脚本自动定位 MSBuild，生成文件存放在忽略的 `out/`、`results/` 中。

从仓库根目录运行：

```powershell
# 对照组：预期 A 成功、B 因 IPC 冲突失败。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-multi-instance\Run-Experiment.ps1 -IsolationMode SharedTemp

# 直接调用运行时公开 C API，隔离两套 TMP / TEMP。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-multi-instance\Run-Experiment.ps1 -IsolationMode SeparateTemp

# 通过当前 Windows 程序所用的 Stream Manager 验证。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-multi-instance\Run-Experiment.ps1 -IsolationMode SeparateTemp -Backend StreamManager
```

脚本发现已存在 CloudXR 管理器、运行时或相关管道时会退出，不会关闭用户的进程。仅有空闲的 WPF 窗口不阻止运行。实验不修改机器级环境变量、OpenXR 注册表、IP 地址或防火墙。

所有进程有时间上限；脚本用自己的进程对象和停止文件清理探针。Stream Manager 及其子进程属于探针创建的 Windows Job，宿主退出时自动清理。不要在探针运行期间启动其他串流会话。

## 检查内容

1. A 启动成功，OpenXR 探针能创建实例并查询系统。
2. B 使用不同端口启动；对照组应出现 IPC 管道冲突，隔离组应启动成功。
3. B 的 OpenXR 连接只增加 B 的连接事件，A 的连接计数不变。
4. 隔离组在两套运行时中同时创建 D3D11 会话，各自创建两个 256×256 的眼部 swapchain，并同时保留至少一个重叠时间段。
5. 停止 B 后，A 仍可连接；B 的探针连接失败，不会回退到 A。
6. 核心 DLL 的 SHA-256 在实验前后相同，探针进程全部停止。

每次运行输出 `summary.json` 和完整日志。符合预期的对照组失败也会令 `ExpectedChecksPassed` 为 `true`；其他未达预期的结果返回非零退出码。

## 结果的适用范围

这证明了本次环境中的**运行时启动、OpenXR 连接路由、D3D11 会话与纹理资源隔离**。探针不调用 `xrBeginSession` / `xrEndFrame`，没有向头显提交图像，不能据此推断两路 NVENC 编码、实际分辨率和帧率、输入延迟或显存余量。

NVIDIA 公开 FAQ 仍只支持一个操作系统实例的一路串流。本实验不是厂商对多会话部署的支持承诺。

原生 Vision Pro 客户端 `D:\GitClone\MyStreamingClient` 已作只读检查，目前通过 `.systemDiscovered` 或 `.local(ipAddress:port:)` 进入 Apple 本地配对流程。其端口输入是会话管理入口；公开的 `MediaStreamIsReady` 消息没有独立的媒体端口字段。尚未验证如何把这两路自定义信令端口接入该流程，不能假设新增一个 JSON 字段就能生效。

后续完整体验仍需：验证配对与媒体端口路由；两台真实 Vision Pro 同时验证视频、注视点和输入；为两份 Unity 进程加入共享人物、物体状态、交互所有权和共同空间校准。客户端与 Unity 原项目均未修改。

详细实测结论见 [RESULTS.md](RESULTS.md)。

`CloudXrProbe.exe --mode network-properties --runtime <SDK目录> --enable-ice true --media-port 0` 仅通过公开 C API 设置并读回网络属性，不启动运行时或绑定端口。属性被接受不代表原生媒体传输会采用该端口；后续真机结果见 [头显测试记录](../cloudxr-headset-test/RESULTS.md)。

## 参考

- [CloudXR FAQ](https://docs.nvidia.com/cloudxr-sdk/latest/support/faq.html)
- [运行时管理 API](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/cloudxr_runtime/runtime_mgmt_api.html)
- [Stream Manager](https://docs.nvidia.com/cloudxr-sdk/latest/usr_guide/stream_manager/index.html)
- [Apple 本地会话协议](https://developer.apple.com/documentation/foveatedstreaming/establishing-foveated-streaming-sessions-with-apple-vision-pro)
