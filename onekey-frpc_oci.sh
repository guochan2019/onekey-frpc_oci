#!/bin/bash
# ============================================================
# onekey-frpc_oci — PVE 一键重建 OCI frpc CT（OCI-FrpClient）
# 适用环境: PVE 9.1+（OCI 支持），宿主 root 运行
# 功能: 拉 OCI 镜像 → 建特权 CT → 配置持久化 → 启动验证
#       frpc 内网穿透客户端（frps 在公网，frpc 主动出站连接，无需入站端口）
# 注意: fatedier/frpc 镜像无 latest 标签，版本号交互输入（默认 v0.71.0）
# ============================================================
set -e

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 检测 PVE 环境 ----------
command -v pct &>/dev/null || err "未找到 pct，请确认在 PVE 宿主上运行"
command -v pveam &>/dev/null || err "未找到 pveam"
command -v skopeo &>/dev/null || err "未找到 skopeo（PVE 9.1+ OCI 支持依赖）"

# ---------- 配置 ----------
CTID=103
CT_NAME="OCI-FrpClient"
CT_IP="192.168.50.4/24"
CT_GW="192.168.50.1"
VER="v0.71.0"
VZTPL_DIR="/var/lib/vz/template/cache"
ROOTFS="local:0.25"
DATA_DIR="/opt/frpc"

# ---------- 启动提示（配置预检前） ----------
warn "请确保 ${DATA_DIR}/frpc.toml 已配置就位且正确，否则容器启动会失败"
read -p "确认配置已就位？按回车继续，Ctrl-C 取消... " DUMMY </dev/tty

# ---------- 配置文件预检（frpc 无有效配置会立即退出，必须先就位） ----------
mkdir -p "${DATA_DIR}"
if [ ! -f "${DATA_DIR}/frpc.toml" ]; then
  err "未找到配置文件 ${DATA_DIR}/frpc.toml，请先创建再运行（TOML 格式）：
  示例:
    serverAddr = \"x.x.x.x\"   # frps 服务器地址
    serverPort = 7000          # frps 端口

    [[proxies]]
    name = \"web\"
    type = \"tcp\"
    localIP = \"127.0.0.1\"
    localPort = 80
    remotePort = 8080
  完整参数见 https://gofrp.org"
fi

# ---------- 检测 local 存储模板目录 ----------
if [ ! -d "${VZTPL_DIR}" ]; then
  VZTPL_DIR=$(pveam list local 2>/dev/null | awk 'NR==2{print $2}' | sed 's|local:vztmpl/.*||')
  [ -n "${VZTPL_DIR}" ] || err "无法定位 vztmpl 目录，请检查 local 存储配置"
  VZTPL_DIR="${VZTPL_DIR}/vztmpl"
fi

# =================== ① 拉镜像 ===================
info "=== 1/4 拉取 OCI 镜像 ==="
# 镜像无 latest 标签，版本号交互输入（Docker Hub 62 个 tag 全为版本号）
read -p "请输入 frpc 版本号 (默认 ${VER}): " VER_INPUT </dev/tty
VER=${VER_INPUT:-${VER}}
echo "${VER}" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || err "版本号格式应为 vX.Y.Z（如 v0.71.0）"
TPL_REF="docker://fatedier/frpc:${VER}"
TPL_NAME="fatedier_frpc_${VER}.tar"
# 重建目的为获取最新版本：模板存在则删除后重新拉取
if [ -f "${VZTPL_DIR}/${TPL_NAME}" ]; then
  info "  删除旧模板 ${TPL_NAME}（重建=拉取最新）"
  pveam remove "local:vztmpl/${TPL_NAME}"
fi
info "  拉取 ${TPL_REF} → ${VZTPL_DIR}/${TPL_NAME}"
skopeo copy "${TPL_REF}" "oci-archive:${VZTPL_DIR}/${TPL_NAME}"
info "  ✓ 模板拉取完成"

# =================== ② 建 CT ===================
info "=== 2/4 创建容器 ==="

# 选择容器 ID
read -p "请输入容器 ID (默认 ${CTID}): " CTID_INPUT </dev/tty
CTID=${CTID_INPUT:-${CTID}}
CONF="/etc/pve/lxc/${CTID}.conf"
info "  容器 ID: ${CTID}"

# 输入 root 密码（不回显）
read -s -p "请输入容器 root 密码: " CT_PASS </dev/tty
echo ""
[ -n "${CT_PASS}" ] || err "密码不能为空"
info "  ✓ root 密码已设置（不回显）"

# 容器 IP / 网关
read -p "请输入容器 IP (默认 ${CT_IP}): " CT_IP_INPUT </dev/tty
CT_IP=${CT_IP_INPUT:-${CT_IP}}
read -p "请输入网关 IP (默认 ${CT_GW}): " CT_GW_INPUT </dev/tty
CT_GW=${CT_GW_INPUT:-${CT_GW}}
info "  容器 IP: ${CT_IP}（网关 ${CT_GW}）"

if pct status ${CTID} &>/dev/null; then
  EXIST_NAME=$(pct config ${CTID} 2>/dev/null | awk '/^hostname:/{print $2}')
  warn "CT ${CTID} 已存在 (hostname: ${EXIST_NAME:-未知})！"
  read -p "确认销毁并重建？(y/n，默认 n): " REBUILD </dev/tty
  if [ "${REBUILD:-n}" != "y" ] && [ "${REBUILD:-n}" != "Y" ]; then
    err "已取消，请手动处理 CT ${CTID}"
  fi
  pct stop ${CTID} 2>/dev/null || true
  pct destroy ${CTID} --purge
  info "  ✓ 旧 CT ${CTID} 已销毁"
fi

# 以 unprivileged 创建（PVE 9.x OCI 特权创建是已知 bug，③ 再删行转特权）
pct create ${CTID} "local:vztmpl/${TPL_NAME}" \
  --hostname "${CT_NAME}" --password "${CT_PASS}" \
  --rootfs "${ROOTFS}" --cores 1 --memory 256 --swap 0 \
  --net0 name=eth0,bridge=lan0,ip=${CT_IP},gw=${CT_GW},firewall=0 \
  --unprivileged 1 --cmode shell --start 0
info "  ✓ CT ${CTID} 已创建"

# =================== ③ 配置 ===================
info "=== 3/4 配置容器 ==="

# 3.1 删除 unprivileged: 1（新建完成后转特权——PVE 9.x OCI 特权创建是已知 bug，
#     必须先以 unprivileged 建成，再删除该行转为特权容器）
sed -i '/^unprivileged: 1$/d' "${CONF}"
info "  ✓ 已删除 unprivileged: 1（转为特权容器）"

# 控制台模式 shell（OCI 创建流程未写入，需显式设置）
pct set ${CTID} --cmode shell
info "  ✓ 控制台模式已设为 shell"

# 开机自启 + 启动顺序（依赖链：RouterOS order=1 → Tailscale order=2 → frpc order=3 → Jellyfin order=5，mosdns 已删腾出 3）
pct set ${CTID} --onboot 1 --startup order=3,up=10
info "  ✓ 已设置 onboot=1、startup order=3,up=10"

# entrypoint 覆写：镜像 ENTRYPOINT=/usr/bin/frpc 无参数会因找不到配置立即退出
# （默认找工作目录 ./frpc.ini），必须带 -c 指定配置文件
pct set ${CTID} --entrypoint "/usr/bin/frpc -c ${DATA_DIR}/frpc.toml"
info "  ✓ entrypoint 已设为 /usr/bin/frpc -c ${DATA_DIR}/frpc.toml"

# 挂载点：配置文件持久化在宿主（重建不丢）
pct set ${CTID} --mp0 "${DATA_DIR},mp=/opt/frpc"
info "  ✓ 挂载点已配置: ${DATA_DIR} → /opt/frpc"

# =================== ④ 启动 + 验证 ===================
info "=== 4/4 启动并验证 ==="

pct start ${CTID}
info "  ✓ CT ${CTID} 已启动"

# 等容器就绪
for i in $(seq 1 30); do
  pct exec ${CTID} -- true 2>/dev/null && break
  sleep 1
done

# 存活确认：frpc 配置解析失败会立即退出（CT 停止）。loginFailExit 默认 true——
# 首次连接 frps 失败（不可达/拒绝）也会退出，但发生在 dialServerTimeout(10s) 内，
# sleep 2 只覆盖配置解析失败场景；连接失败由下方"下一步"容错建议处理
sleep 2
pct status ${CTID} | grep -q running || err "CT ${CTID} 启动后已停止——frpc 配置解析失败，请检查 ${DATA_DIR}/frpc.toml"

# PID1 应为 frpc（镜像 ENTRYPOINT 自动生效）
PROC1=$(pct exec ${CTID} -- cat /proc/1/comm 2>/dev/null || echo "?")
info "  容器 PID1 进程: ${PROC1}"

# entrypoint 参数确认（必须带 -c 配置文件路径）
CMDLINE=$(pct exec ${CTID} -- cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' || echo "?")
echo "${CMDLINE}" | grep -q "${DATA_DIR}/frpc.toml" || err "entrypoint 未生效（缺少 -c ${DATA_DIR}/frpc.toml）"
info "  启动命令: ${CMDLINE}"

# 挂载点容器内可见
pct exec ${CTID} -- ls /opt/frpc/frpc.toml >/dev/null
info "  ✓ 挂载点容器内可见"

# =================== 完成 ===================
echo ""
info "========== 配置信息汇总 =========="
info "  CT ID        : ${CTID}"
info "  容器名称     : ${CT_NAME}"
info "  容器 IP      : ${CT_IP}（网关 ${CT_GW}）"
info "  frpc 版本    : ${VER}"
info "  配置目录     : ${DATA_DIR} → /opt/frpc"
info "  配置文件     : ${DATA_DIR}/frpc.toml（宿主直接编辑，pct restart ${CTID} 生效）"
echo ""
info "=== 下一步 ==="
info "  在 frps 仪表盘/日志确认客户端已上线（连通性以 frps 侧为准）"
info "  修改配置  : 编辑 ${DATA_DIR}/frpc.toml 后 pct restart ${CTID}"
info "  容错建议  : frpc.toml 加 loginFailExit = false（frps 短暂不可达时重试保活；默认 true 首次连接失败即退出，CT 不自动恢复）"
info "  重建升级  : 重跑本脚本并输入新版本号（配置保留）"
