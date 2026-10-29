# 独立网络环境可行性实验

目标：先验证一个 Windows 进程容器是否能同时拥有独立的 UDP 端口空间、访问 RTX 5070 并完成 NVENC 编码。通过后才值得接入 CloudXR；当前不包含容器版配对服务或多人场景。

**当前结果（2026-10-29）：实验已结束，未实现现有 App 一带二。** Containers 已启用并由用户完成重启。单容器端口隔离和 NVENC、双容器编码会话共存均通过；但 CloudXR 6.2.3 所需的 Vulkan compositor 无法在容器中识别有效 GPU，服务启动失败。显式驱动清单复核仍失败，同一 SDK 在主机启动成功。完整证据见 [RESULTS.md](RESULTS.md)。

本实验引擎和容器已停止，镜像与日志保留。Containers 功能保持启用；未安装 Hyper-V、WSL、Docker Desktop 或新 GPU 驱动。以下为归档的准备、复现入口；单帧编码探针通过不代表 CloudXR 或双头显串流通过。

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

引擎仅使用专用本地命名管道 `streamingsession-cloudxr-lab` 和本目录下的镜像存储，不注册系统服务，不暴露远程 Docker TCP 接口。配置 `bridge=none`，首次测试容器使用 `--network=none`，不创建面向局域网的串流入口。引擎和 GPU 探针已经实际执行，结果见 RESULTS.md。

如果主机已配置 HTTP(S) 下载代理，可给 `Start-ContainerEngine.ps1` 显式传入 `-DownloadProxy`；该参数只写实验引擎自己的配置，不改变 Windows 代理。`-EngineDebug` 可记录引擎诊断日志。停止脚本等待自己的引擎退出，启动脚本只会删除已确认对应进程不再运行的本实验 PID 文件。

如果 Docker 拉取镜像数据层停滞，可在普通 PowerShell 运行 `Prepare-OfflineImage.ps1`（同样可选 `-DownloadProxy`），再以管理员权限运行 `Test-ContainerGpu.ps1 -UseOfflineImage`。准备脚本使用 Windows 自带的 curl 下载同一个固定微软镜像，核对清单、配置和每个数据层的 SHA-256，并组装 Docker 加载归档；不会在主机上展开镜像文件系统。加载后以固定配置摘要对应的 image ID 运行，Docker 还会核对解压数据层的 diffID。离线方式会额外保留约 6.23 GiB 的归档和已下载数据层。

镜像为 Microsoft Windows Server 2025 **完整**镜像，固定到清单摘要 `sha256:c241b18ec3d59e82992722b473fa19e290fd27cb7819fe69a0f4ad31130a245a`。对应 amd64 镜像的压缩层合计约 **6.23 GiB**，解包后还需更多空间，保存在本实验 `state/engine-data/` 所在磁盘。它用于 GPU 可行性验证；不使用 Server Core 或 Nano Server。一次测试容器结束后由 `--rm` 清理，镜像保留以避免重复下载。

## 能证明什么

`PASS UDP_NAMESPACE_BOUND` 与 `PASS D3D11_NVENC_H264` 同时出现，并且主机端口始终独占，才说明这一个容器完成了端口隔离与单帧编码。它不能证明双路 HEVC/foveation、CloudXR 服务、共享纹理、输入、画面或性能可用。

[Microsoft 的 GPU 容器说明](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/gpu-acceleration)只明确支持 DirectX 及其上层框架，不能据此推断 NVIDIA NVENC/CUDA 一定可用；这正是实际探针的目的。其文档也未支持 Hyper-V 隔离容器的 GPU，因此本实验限定 `--isolation=process`。

参考：[Windows 容器版本兼容性](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/version-compatibility)、[Docker 官方便携二进制](https://docs.docker.com/engine/install/binaries/)、[NVENC 公共头文件](https://github.com/NVIDIA/VideoProcessingFramework/blob/master/src/TC/third_party/nvEncodeAPI.h)。
