# 网络隔离与 GPU 探针准备结果

日期：2026-10-29。Windows 11 Pro build 26200、RTX 5070、驱动 32.0.16.2101。

| 检查 | 实测结果 |
| --- | --- |
| 本机 D3D11 硬件设备与 NVENC H.264 单帧编码 | 通过，256×256，86 字节输出 |
| 本机空闲 UDP 47998/47999 独占绑定 | 通过 |
| 本机同一端口被另一个独占 socket 占用 | 正确失败，Windows 10048 |
| 官方 Docker 29.9.2 便携包 | 下载并通过固定 SHA-256 检查；客户端版本命令可运行 |
| 启用 Containers 的 `-WhatIf` | 通过，仅预览，未改变系统功能 |
| 便携引擎 `--validate` | 在验证前失败：缺少 vmcompute.dll，要求安装 Containers 功能 |
| 容器内端口空间与 D3D11/NVENC | 尚未测试，不能推断可用 |
| 容器内 CloudXR 与双头显 | 尚未实现或测试 |

只读清单显示 Containers、Hyper-V、WSL 和 VirtualMachinePlatform 的 InstallState 均为 2（Disabled），没有 HNS/vmcompute/vmms 服务。当前工具进程没有管理员权限。未启用 Windows 功能、安装服务、重启电脑、创建虚拟机、启动容器或修改 GPU 驱动。

Microsoft 完整 Windows Server 2025 镜像的清单已可通过 MCR 读取，amd64 子镜像 OSVersion 为 `10.0.26100.33674`，压缩层合计约 6.23 GiB。尚未下载镜像层。主机 D 盘约有 6.98 TB 可用空间，本实验镜像存储将放在该盘的本实验目录内。

`GpuEncodeProbe` 使用 NVIDIA 公共 NVENC 12.0 API。它检查 NVENC 成功返回非空编码数据，不解码输出，也不代表 CloudXR 所需的 HEVC、多视图、共享纹理、输入或性能验证通过。

后续实际操作入口、作用范围和脚本见 [README.md](README.md)。在得到系统组件变更的明确授权后，才能尝试容器内探针。
