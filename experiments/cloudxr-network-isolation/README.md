# 独立网络环境可行性实验

目标：先验证一个 Windows 进程容器是否能同时拥有独立的 UDP 端口空间、访问 RTX 5070 并完成 NVENC 编码。通过后才值得接入 CloudXR；当前不包含容器版配对服务或多人场景。

**当前状态（2026-10-29 07:19 UTC）：用户已授权最后一次 Windows 进程容器尝试。** 已通过管理员进程执行 Containers 功能启用，返回 `Succeeded=True`、`Changed=True`、`RestartNeeded=True`。等待用户保存工作并手动重启；尚未启动容器引擎或下载镜像层。重启后从 `Get-IsolationReadiness.ps1` 复查，再运行引擎和 GPU/端口探针。

## 当前已经做到什么

2026-10-29，Windows 11 Pro build 26200：主机上已成功用 D3D11 纹理编码一帧 256×256 H.264，获得 86 字节输出。Docker 29.9.2 的官方便携二进制已下载到忽略的 `out/`，没有安装服务或启动引擎。

准备阶段的只读检查显示 `Containers`、Hyper-V、WSL 和 VirtualMachinePlatform 均为 Disabled。最新检查显示 Containers 已 Enabled，其他三项仍为 Disabled；功能启用报告要求重启。容器内的 UDP 隔离、GPU、NVENC、CloudXR 和双头显均未验证。CPU 虚拟化属性在已有 hypervisor 的环境中可能被屏蔽，本实验不据此判断 BIOS 一定关闭了虚拟化。

便携引擎的 `--validate` 命令也已实际尝试，在配置验证前即提示缺少 `vmcompute.dll`，要求安装 Containers 功能。这是目前必须先启用系统组件的直接依据；没有引擎或容器启动成功。完整记录见 [RESULTS.md](RESULTS.md)。

## 先准备，再批准系统变更

普通 PowerShell 可执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-network-isolation\Build-LabTools.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-network-isolation\Get-IsolationReadiness.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-network-isolation\Enable-ContainerLab.ps1 -WhatIf
```

构建只写本实验目录。NVENC 12.0 公共头文件来自 NVIDIA 的 MIT 授权源码，头文件和 Docker 压缩包均校验固定 SHA-256。二进制、下载内容、镜像和测试日志不会提交 Git。

`Enable-ContainerLab.ps1` 的实际操作只有 `Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart`。它需要管理员权限，可能要求用户重启；脚本不自动重启，也不启用 Hyper-V、安装 Docker Desktop 或改 GPU 驱动。用户批准前仅运行 `-WhatIf`。

## 批准后进行的测试

以下步骤需要管理员 PowerShell，并且必须先完成功能启用和所需重启：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-network-isolation\Enable-ContainerLab.ps1
# 如果输出 RestartNeeded=True，保存工作并由用户自行重启。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-network-isolation\Start-ContainerEngine.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-network-isolation\Test-ContainerGpu.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File experiments\cloudxr-network-isolation\Stop-ContainerEngine.ps1
```

测试前应结束占用 UDP 47998/47999 的串流实验。探针在主机独占绑定这两个端口的同时，让容器绑定同样端口并实际编码一帧。任一环节失败都不能宣称已具备 CloudXR 隔离运行能力。

引擎仅使用专用本地命名管道 `streamingsession-cloudxr-lab` 和本目录下的镜像存储，不注册系统服务，不暴露远程 Docker TCP 接口。配置 `bridge=none`，首次测试容器使用 `--network=none`，不创建面向局域网的串流入口。引擎启动/容器测试脚本在当前系统功能启用前尚未实际运行。

镜像为 Microsoft Windows Server 2025 **完整**镜像，固定到清单摘要 `sha256:c241b18ec3d59e82992722b473fa19e290fd27cb7819fe69a0f4ad31130a245a`。对应 amd64 镜像的压缩层合计约 **6.23 GiB**，解包后还需更多空间，保存在本实验 `state/engine-data/` 所在磁盘。它用于 GPU 可行性验证；不使用 Server Core 或 Nano Server。一次测试容器结束后由 `--rm` 清理，镜像保留以避免重复下载。

## 能证明什么

`PASS UDP_NAMESPACE_BOUND` 与 `PASS D3D11_NVENC_H264` 同时出现，并且主机端口始终独占，才说明这一个容器完成了端口隔离与单帧编码。它不能证明双路 HEVC/foveation、CloudXR 服务、共享纹理、输入、画面或性能可用。

[Microsoft 的 GPU 容器说明](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/gpu-acceleration)只明确支持 DirectX 及其上层框架，不能据此推断 NVIDIA NVENC/CUDA 一定可用；这正是实际探针的目的。其文档也未支持 Hyper-V 隔离容器的 GPU，因此本实验限定 `--isolation=process`。

参考：[Windows 容器版本兼容性](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/version-compatibility)、[Docker 官方便携二进制](https://docs.docker.com/engine/install/binaries/)、[NVENC 公共头文件](https://github.com/NVIDIA/VideoProcessingFramework/blob/master/src/TC/third_party/nvEncodeAPI.h)。
