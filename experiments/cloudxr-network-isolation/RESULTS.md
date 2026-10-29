# Windows 进程容器实测结果

日期：2026-10-29，Windows 11 Pro build 26200、RTX 5070、NVIDIA 驱动 32.0.16.2101（621.01）、CloudXR 6.2.3、Docker 29.9.2。

## 结论

当前这台电脑的进程容器能隔离原生串流使用的 UDP 端口，也能共享 RTX 5070 完成 D3D11/NVENC 编码。但 CloudXR 必需的 Vulkan 合成器无法在容器内枚举到有效 GPU，运行时启动失败。因此本次未达到现有 visionOS App 同时连接两路串流的目标；没有进行新的双头显画面测试，也没有验证共享场景或独立交互。按用户“最后再试一次”和此前不通则停止的要求，到此停止此部署路线。

## 已验证的结果

| 检查 | 结果 |
| --- | --- |
| 用户手动重启后的 Containers / HNS / vmcompute | Enabled / Running / Running |
| 独立便携引擎及专用命名管道 | 正常启动，Windows windowsfilter 存储；未注册服务 |
| 固定微软完整 Server 2025 镜像 | 下载、校验、导入成功 |
| 主机占用 UDP 47998/47999 时，单容器独占绑定同名端口 | 通过 |
| 单容器识别 RTX 5070 并编码 H.264 | 通过，256×256，86 字节 |
| 两容器同时绑定同名端口，各编码一帧后保留编码会话 | 通过，实测同时存活 10.33 秒，两个容器退出码均为 0 |
| 重启后主机编码对照 | 通过，86 字节 |
| CloudXR SDK 原文件直接映射进容器 | 首次加载失败，Win32 126（依赖缺失） |
| 补齐副本内的 C++、Vulkan loader、NVAPI 后加载 | CUDA、NVAPI、Vulkan loader、C++ 与 cloudxr.dll 均可加载 |
| 容器内 CloudXR 创建服务 | 成功，版本 6.2.3，所有已设置属性返回成功 |
| 容器内 CloudXR 启动 | 失败，start=-2，Vulkan 资源创建失败 |
| 显式映射当前 NVIDIA Vulkan 驱动并在容器内注册 ICD | 仍失败；loader 找到正确 ICD，却没有有效 GPU |
| 同一 SDK 副本与相同 profile 在主机运行 | START=0、READY、STOP=0、JOIN=0，退出码 0 |

双容器探针只编码单帧并保持端口、D3D11 设备和 NVENC 会话，不代表双路持续串流的吞吐、HEVC、foveation、OpenXR 共享纹理或画质已经验证。

## 具体阻塞

CloudXR 日志显示 profile 为 `apple-vision-pro`、backend 为 `nvst-native`，即使关闭 runtime foveation，也必须初始化 Vulkan compositor。失败链为：

```text
Failed to detect any valid GPUs in the current config
vkEnumeratePhysicalDevices failed: VK_ERROR_INITIALIZATION_FAILED
VulkanManager::init failed: Result::ERROR_VULKAN_RESOURCE_CREATION
nv_cxr_service_start ... Result::ERROR_VULKAN_RESOURCE_CREATION
PROBE START result=-2
```

最终检查实际找到了以下两处当前 621.01 驱动的 ICD，排除了仅因清单路径未发现而失败的解释：

```text
C:\nvidia-driver\nv-vk64.json
C:\Windows\System32\HostDriverStore\filerepository\nv_dispi.inf_amd64_20f49c6eb5c9b39b\nv-vk64.json
```

`VK_DRIVER_FILES` 的尝试后又使用容器内 `HKLM\SOFTWARE\Khronos\Vulkan\Drivers` 注册进行了复核。注册只发生在随测试移除的容器内，主机注册表、驱动安装和 SDK DLL 没有改写。主机的同一 SDK 副本能启动，是本次容器结果的对照。

[微软的 GPU 容器文档](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/gpu-acceleration)明确支持 DirectX 及其上层框架，未保证第三方 API；本次实测也不能将 NVENC 成功推广成 Vulkan/CloudXR 可用。这只说明当前硬件、驱动、系统和 SDK 组合下此路线失败，不是对所有未来版本或其他硬件的结论。

## 原始记录

以下均位于忽略的 `state/`，没有提交二进制或设备资料：

- `gpu-20261029-081720-841/result.json`：单容器 UDP/NVENC 通过。
- `dual-gpu-20261029-082254-245/result.json`：双容器通过，编码会话重叠 10.3308207 秒。
- `dual-gpu-20261029-082105-194/`：首次双容器两个探针均成功，但 Windows PowerShell 的 Process.ExitCode 采集误判；后来改用 Docker inspect 读取容器退出码并复核通过。首轮失败记录未改写。
- `sdk-smoke-result.json`：未补依赖时的加载失败。
- `sdk-inspect-20261029-082848-367/probe.log`：依赖加载与 SDK 内部失败日志。
- `sdk-inspect-20261029-083140-304/probe.log`：显式驱动清单注册后的最终失败日志。
- `host-sdk-control-20261029-083140-365/probe.log`：同一 SDK 在主机启动成功。
- `cleanup-result.json`：2026-10-29 16:32:56（中国时间）仅停止本实验引擎，Docker 列表无残留容器。

## 镜像与复现材料

镜像索引固定为 `sha256:c241b18ec3d59e82992722b473fa19e290fd27cb7819fe69a0f4ad31130a245a`，amd64 清单为 `sha256:9eb393ccb1817ae850b2d3be8fc4917b043dc2d5be293cc602664a4733ef89cb`，Docker image ID 为 `sha256:7fb65857422af705198cd96f6a4481cde176dddf4cb1b8bc869d74ec51b0f06d`。

原生 Docker 拉取数据层停滞后，改用 curl 下载并逐项检查 SHA-256，组装 Docker load 归档。第二层末尾用 suffix range 补齐，再检查整个 2,212,190,306 字节文件的摘要；并非只校验片段。镜像最终导入成功，Docker 也校验了展开后的 diffID。

`Test-CloudXrContainer.ps1` 保留最终机器上的 SDK 复核入口，其中驱动目录固定为此次 621.01 的实际目录，需要先准备 `out/sdk-runtime`：原 SDK 6.2.3 顶层文件、Visual Studio 的 `VC\Redist\MSVC\14.44.35112\x64\Microsoft.VC143.CRT` 中 DLL，以及主机 System32 的 `vulkan-1.dll` 和 `nvapi64.dll`。`out/payload` 内需有已构建的 `CloudXrProbe.exe`。这些都是实验目录内的独立副本；该入口不提供完整 App 的配对或串流服务。

## 系统和项目收尾

Containers 仍 Enabled；Hyper-V、WSL、VirtualMachinePlatform 仍 Disabled。HNS/vmcompute 为 Windows 功能提供的服务。没有安装完整虚拟机、Docker Desktop、系统 Docker 服务或新显卡驱动，没有改主机网络代理，也没有创建 NAT/透明网络或改物理网卡。便携引擎已停止，实验容器已移除；镜像、下载文件和日志保留，避免以后重复下载。

原始 StreamingSession 与 MyStreamingClient 源码保持未修改；代码改动只在独立的 StreamingSession-MultiUser 实验分支。
