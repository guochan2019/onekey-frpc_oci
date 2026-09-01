# frpc OCI CT 一键重建脚本（PVE）

在 PVE 9.1+ 宿主机上一键重建 OCI frpc 容器（CT）：拉取镜像 → 创建特权容器 → 配置持久化 → 启动验证。frpc 内网穿透客户端，主动出站连接公网 frps，容器无需开放入站端口。

## 快速开始

在 PVE 宿主（root）上执行：

```bash
# 1. 先创建配置文件（脚本硬检查，缺失则拒绝执行）
mkdir -p /opt/frpc
# 编辑 /opt/frpc/frpc.toml（TOML 格式，最小示例见下）

# 2. 下载脚本（-O 强制覆盖，防止同名旧文件被 wget 存为 .N 后缀）
wget -O onekey-frpc_oci.sh https://raw.githubusercontent.com/guochan2019/onekey-frpc_oci/main/onekey-frpc_oci.sh
# 3. 运行（交互：版本号 + 容器 ID + root 密码 + IP/网关）
bash onekey-frpc_oci.sh
```

最小配置示例（/opt/frpc/frpc.toml）：

```toml
serverAddr = "x.x.x.x"   # frps 服务器地址
serverPort = 7000        # frps 端口
loginFailExit = false    # 推荐：frps 短暂不可达时重试保活（默认 true 首次失败即退出）

[[proxies]]
name = "web"
type = "tcp"
localIP = "127.0.0.1"
localPort = 80
remotePort = 8080
```

## 脚本流程

| 步骤 | 说明 |
|------|------|
| ① 拉取 OCI 镜像 | 版本号交互输入（默认 v0.71.0，**镜像无 latest 标签**）；删除旧模板 → skopeo 拉取 |
| ② 创建容器 | 交互选择容器 ID、root 密码（不回显）、IP/网关；已存在则确认销毁重建（显示实际 hostname）；以 unprivileged 创建 |
| ③ 配置容器 | 删除 unprivileged 转特权、cmode shell、onboot/startup、entrypoint 覆写（带 -c 配置路径）、挂载 /opt/frpc |
| ④ 启动验证 | 启动容器，验证存活、PID1=frpc、启动命令含 -c 配置路径、挂载点可见 |

## 参数说明（脚本顶部变量，按需修改）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CTID` | 103（运行时交互可改） | 容器 ID |
| `CT_NAME` | OCI-FrpClient | 容器名称 |
| `CT_PASS` | 运行时交互输入（不回显） | 容器 root 密码 |
| `CT_IP` | 运行时交互输入（默认值见脚本） | 容器 IPv4（CIDR） |
| `CT_GW` | 运行时交互输入（默认值见脚本） | 默认网关 |
| `VER` | v0.71.0（运行时交互可改，格式 vX.Y.Z） | frpc 版本号 |
| `ROOTFS` | `local:0.25` | 根磁盘（256 MB，镜像 amd64 仅 ~10MB） |
| `DATA_DIR` | `/opt/frpc` | 配置目录（宿主侧，挂载到容器 /opt/frpc） |

## 注意事项

1. **PVE 9.x OCI 特权创建已知 bug**：`--unprivileged 0` 创建必失败（`setgid(0): Invalid argument`，官方确认）。脚本先以 unprivileged 创建成功，再删除 conf 中的 `unprivileged: 1` 转为特权容器。
2. **`--cmode shell` 在 OCI 创建流程不写入 conf**，脚本用 `pct set` 显式设置。
3. **镜像无 CMD**：`ENTRYPOINT ["/usr/bin/frpc"]` 不带参数启动会因找不到配置立即退出。脚本用 `pct set --entrypoint "/usr/bin/frpc -c /opt/frpc/frpc.toml"` 覆写（pct create/set 均支持带参数 entrypoint）。
4. **配置文件必须启动前就位**：frpc 配置解析失败会立即退出（容器秒停）。`/opt/frpc` 存在即保留，重建不丢配置。
5. **`loginFailExit` 默认 true**（源码确认）：首次连接 frps 失败（含不可达）即退出且 CT 不自动恢复。建议配置里加 `loginFailExit = false`。
6. **webServer 管理面板绑定地址必须是容器自己的 IP**（或 127.0.0.1）——绑到非本机地址会 `bind: cannot assign requested address` 秒退（旧配置从别的机器拷来易踩）。
7. **镜像为 alpine 精简版（无 curl）**：验证走 /proc/1/comm + cmdline + 存活判定，连通性以 frps 仪表盘为准。
8. IPv6 不配置（net0 留空）、DNS 不设置、MAC 由 PVE 随机生成、firewall=0。

## 验证

```bash
pct exec 103 -- cat /proc/1/comm            # 应输出 frpc
pct exec 103 -- cat /proc/1/cmdline         # 应含 -c /opt/frpc/frpc.toml
pct status 103                              # running（不秒退）
# frps 仪表盘/日志确认客户端已上线（连通性以 frps 侧为准）
```

**重建升级**：重跑本脚本并输入新版本号（/opt/frpc 配置保留）。**修改配置**：编辑 /opt/frpc/frpc.toml 后 `pct restart 103`。
