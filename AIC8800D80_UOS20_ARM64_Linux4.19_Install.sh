#!/bin/bash
# ======================================================================
# AIC8800D80 USB Wi-Fi + Bluetooth 驱动安装脚本
# 目标环境：
#   UOS V20 / ARM64(aarch64) / Linux 4.19.x
#
# 实测成功路径：
#   1111:1111
#       ↓ usb_modeswitch
#   a69c:8d80
#       ↓ 固件加载
#   a69c:8d81
#       ↓
#   aic8800_fdrv → wlan0
#   btusb        → hci0
#
# 本脚本针对本次实际验证成功的 Linux 4.19 ARM64 方案整理：
#   - 不依赖完整 DKMS 成功
#   - 跳过 aic_zlp_quirk.ko
#   - 手动编译并安装：
#       aic_load_fw.ko
#       aic8800_fdrv.ko
#
# ======================================================================
# 参考 / 致谢
# ----------------------------------------------------------------------
# 1. 直接使用的代码仓库
#    shenmintao/aic8800d80
#    https://github.com/shenmintao/aic8800d80
#
#    本脚本直接使用该仓库中的：
#      - AIC8800D80 驱动源码
#      - 固件
#      - install.sh
#      - udev 规则
#      - usb_modeswitch 配置
#
# 2. 技术参考
#    olamellberg/AIC8800D80
#    https://github.com/olamellberg/AIC8800D80
#
#    主要参考 AIC8800D80 USB 枚举 / 模式切换过程：
#      1111:1111 → a69c:8d80 → a69c:8d81 / a69c:8d83
#
# 感谢上述开源项目作者及贡献者对 AIC8800D80 Linux 支持、
# USB 枚举分析、固件加载和问题排查所做的工作。
#
# ======================================================================
# 使用方法：
#   chmod +x AIC8800D80_UOS20_ARM64_Linux4.19_install_final.sh
#   ./AIC8800D80_UOS20_ARM64_Linux4.19_install_final.sh
#
# 注意：
#   - 请先插入 AIC8800D80 USB 网卡。
#   - 脚本内部会自行调用 sudo，不需要使用 sudo 启动脚本。
#   - 本脚本不会自动 git pull，避免未经验证的新代码替换已验证版本。
#   - Linux 4.19 上 aic_zlp_quirk 可能因 regs_get_kernel_argument()
#     API 不存在而编译失败，因此本脚本故意跳过该模块。
# ======================================================================

set -u
umask 022

REPO_URL="https://github.com/shenmintao/aic8800d80.git"
WORKDIR="${HOME}/aic8800d80"
KVER="$(uname -r)"
KBUILD="/lib/modules/${KVER}/build"
MODDIR="/lib/modules/${KVER}/extra/aic8800"
LOGFILE="/tmp/aic8800d80_install.log"

log() {
    echo
    echo "======================================================================"
    echo "$1"
    echo "======================================================================"
}

warn() {
    echo "[WARN] $*" >&2
}

die() {
    echo "[ERROR] $*" >&2
    echo "[ERROR] 详细日志：$LOGFILE" >&2
    exit 1
}

run_logged() {
    "$@" 2>&1 | tee -a "$LOGFILE"
    return "${PIPESTATUS[0]}"
}

# ----------------------------------------------------------------------
# 0. 权限与系统检查
# ----------------------------------------------------------------------

: > "$LOGFILE"

log "[0/12] 系统环境检查"

if [ "$(id -u)" -eq 0 ]; then
    die "请使用普通用户运行本脚本，不要以 sudo ./脚本.sh 启动。"
fi

echo "Kernel : $(uname -r)"
echo "Arch   : $(uname -m)"
echo "System : $(uname -a)"

if [ "$(uname -m)" != "aarch64" ]; then
    warn "当前架构不是 aarch64，本脚本主要针对 ARM64。"
fi

if [[ "$KVER" != 4.19.* ]]; then
    warn "当前内核不是 4.19.x：$KVER"
    warn "本脚本按 UOS V20 Linux 4.19 ARM64 实测方案整理。"
fi

[ -e "$KBUILD" ] || die "找不到内核构建目录：$KBUILD"

echo "[OK] Kernel build tree:"
readlink -f "$KBUILD"

# ----------------------------------------------------------------------
# 1. 执行时显示参考 / 致谢
# ----------------------------------------------------------------------

log "[1/12] 参考 / 致谢"

cat <<'EOF'
本安装脚本涉及的代码仓库：

[直接使用]
shenmintao/aic8800d80
https://github.com/shenmintao/aic8800d80

本脚本直接使用该仓库提供的：
  - AIC8800D80 驱动源码
  - 固件
  - install.sh
  - udev 规则
  - usb_modeswitch 配置

[技术参考]
olamellberg/AIC8800D80
https://github.com/olamellberg/AIC8800D80

主要用于参考：
  1111:1111 → a69c:8d80 → a69c:8d81 / a69c:8d83
  AIC8800D80 USB 模式切换及工作状态

感谢上述开源项目作者及贡献者。
EOF

# ----------------------------------------------------------------------
# 2. 安装依赖
# ----------------------------------------------------------------------

log "[2/12] 安装编译 / USB模式切换 / Wi-Fi / 蓝牙依赖"

sudo -v || die "sudo 权限验证失败"

sudo apt update 2>&1 | tee -a "$LOGFILE" || die "apt update 失败"

sudo apt install -y \
    git \
    make \
    gcc \
    bc \
    build-essential \
    dkms \
    mokutil \
    eject \
    usb-modeswitch \
    sg3-utils \
    iw \
    ethtool \
    rfkill \
    bluez \
    2>&1 | tee -a "$LOGFILE" || die "依赖安装失败"

# ----------------------------------------------------------------------
# 3. 下载 / 准备源码
# ----------------------------------------------------------------------

log "[3/12] 下载 / 准备 AIC8800D80 驱动源码"

if [ -d "$WORKDIR/.git" ]; then
    echo "[INFO] 检测到已有源码仓库：$WORKDIR"
    cd "$WORKDIR" || die "无法进入 $WORKDIR"

    echo "[INFO] 不自动 git pull，保持当前已验证工作树。"
    echo "[INFO] 当前 commit："
    git rev-parse --short HEAD 2>/dev/null || true
else
    git clone "$REPO_URL" "$WORKDIR" 2>&1 | tee -a "$LOGFILE" \
        || die "git clone 失败"
    cd "$WORKDIR" || die "无法进入 $WORKDIR"
fi

echo "[INFO] Git remote："
git remote -v 2>/dev/null || true

# ----------------------------------------------------------------------
# 4. 安装官方固件 / udev / usb_modeswitch 配置
# ----------------------------------------------------------------------

log "[4/12] 安装官方固件 / udev / USB模式切换配置"

chmod +x "$WORKDIR/install.sh" 2>/dev/null \
    || die "无法设置 install.sh 可执行权限"

echo "[INFO] 执行上游 install.sh。"
echo "[INFO] Linux 4.19 上可能在 aic_zlp_quirk 阶段出现 DKMS build failed。"
echo "[INFO] 即使 DKMS 失败，也会继续执行后面的核心模块手动编译。"

sudo "$WORKDIR/install.sh" 2>&1 | tee -a "$LOGFILE"
INSTALL_RC="${PIPESTATUS[0]}"

if [ "$INSTALL_RC" -ne 0 ]; then
    warn "上游 install.sh 返回码：$INSTALL_RC"
    warn "如果失败原因为 aic_zlp_quirk / regs_get_kernel_argument，属于本次"
    warn "Linux 4.19 ARM64 兼容问题，脚本将继续。"
else
    echo "[OK] 上游 install.sh 完成"
fi

# ----------------------------------------------------------------------
# 5. 检查固件与模式切换配置
# ----------------------------------------------------------------------

log "[5/12] 检查固件 / udev / USB模式切换配置"

echo "---------- AIC firmware ----------"
find /lib/firmware -maxdepth 2 -type f \
    \( -path '/lib/firmware/aic8800*' -o -path '/lib/firmware/aic8800D80*' \) \
    -printf '%p %s bytes\n' 2>/dev/null | sort || true

echo
echo "---------- usb_modeswitch ----------"
if [ -f /etc/usb_modeswitch.d/1111:1111 ]; then
    echo "[OK] /etc/usb_modeswitch.d/1111:1111"
else
    warn "未找到 /etc/usb_modeswitch.d/1111:1111"
fi

echo
echo "---------- udev ----------"
if [ -f /usr/lib/udev/rules.d/aic.rules ]; then
    echo "[OK] /usr/lib/udev/rules.d/aic.rules"
else
    warn "未找到 /usr/lib/udev/rules.d/aic.rules"
fi

# ----------------------------------------------------------------------
# 6. USB模式切换
# ----------------------------------------------------------------------

log "[6/12] AIC8800D80 USB 模式切换"

echo "当前 USB："
lsusb | grep -iE '1111|a69c|aic' || true

if lsusb | grep -q '1111:1111'; then
    echo
    echo "[INFO] 检测到 1111:1111，执行 usb_modeswitch。"

    if [ -f /etc/usb_modeswitch.d/1111:1111 ]; then
        sudo usb_modeswitch \
            -c /etc/usb_modeswitch.d/1111:1111 \
            2>&1 | tee -a "$LOGFILE" || \
            warn "usb_modeswitch 返回非零。"
    else
        warn "缺少 /etc/usb_modeswitch.d/1111:1111。"
    fi

    sleep 3
fi

echo
echo "模式切换后 USB："
lsusb | grep -iE '1111|a69c|aic' || true

if lsusb | grep -q 'a69c:8d80'; then
    echo "[OK] 已进入 AIC8800D80 Boot ROM：a69c:8d80"
elif lsusb | grep -q 'a69c:8d81'; then
    echo "[OK] 已进入 AIC8800D80 工作状态：a69c:8d81"
elif lsusb | grep -q 'a69c:8d83'; then
    echo "[OK] 已进入 Wi-Fi-only 工作状态：a69c:8d83"
else
    warn "当前未检测到 a69c:8d80 / a69c:8d81 / a69c:8d83。"
    warn "请确认 AIC8800D80 USB 网卡已插入。"
fi

# ----------------------------------------------------------------------
# 7. 编译两个实际成功的核心模块
# ----------------------------------------------------------------------

log "[7/12] 编译核心模块（跳过 aic_zlp_quirk）"

cd "$WORKDIR/drivers/aic8800" \
    || die "无法进入 $WORKDIR/drivers/aic8800"

echo "[INFO] 清理旧构建产物..."
make clean 2>&1 | tee -a "$LOGFILE" || true

echo
echo "---------- 编译 aic8800_fdrv ----------"

make -C "$KBUILD" \
    M="$PWD/aic8800_fdrv" \
    ARCH=arm64 \
    modules \
    2>&1 | tee -a "$LOGFILE"

RC="${PIPESTATUS[0]}"
[ "$RC" -eq 0 ] || die "aic8800_fdrv.ko 编译失败"

[ -f "$PWD/aic8800_fdrv/aic8800_fdrv.ko" ] \
    || die "没有生成 aic8800_fdrv.ko"

echo
echo "---------- 编译 aic_load_fw ----------"

make -C "$KBUILD" \
    M="$PWD/aic_load_fw" \
    ARCH=arm64 \
    modules \
    2>&1 | tee -a "$LOGFILE"

RC="${PIPESTATUS[0]}"
[ "$RC" -eq 0 ] || die "aic_load_fw.ko 编译失败"

[ -f "$PWD/aic_load_fw/aic_load_fw.ko" ] \
    || die "没有生成 aic_load_fw.ko"

echo
echo "[OK] 核心模块编译成功："
ls -lh \
    "$PWD/aic8800_fdrv/aic8800_fdrv.ko" \
    "$PWD/aic_load_fw/aic_load_fw.ko"

# ----------------------------------------------------------------------
# 8. 安装模块
# ----------------------------------------------------------------------

log "[8/12] 安装内核模块"

sudo mkdir -p "$MODDIR" || die "无法创建 $MODDIR"

sudo install -m 0644 \
    "$PWD/aic_load_fw/aic_load_fw.ko" \
    "$MODDIR/aic_load_fw.ko" \
    || die "安装 aic_load_fw.ko 失败"

sudo install -m 0644 \
    "$PWD/aic8800_fdrv/aic8800_fdrv.ko" \
    "$MODDIR/aic8800_fdrv.ko" \
    || die "安装 aic8800_fdrv.ko 失败"

sudo depmod -a || die "depmod 失败"

echo "[OK] 安装位置："
ls -lh "$MODDIR"

# ----------------------------------------------------------------------
# 9. 加载模块
# ----------------------------------------------------------------------

log "[9/12] 加载 AIC8800D80 模块"

sudo modprobe aic_load_fw 2>&1 | tee -a "$LOGFILE" \
    || die "modprobe aic_load_fw 失败"

sudo modprobe aic8800_fdrv 2>&1 | tee -a "$LOGFILE" \
    || die "modprobe aic8800_fdrv 失败"

echo
echo "[INFO] 当前 AIC 模块："
lsmod | grep -iE 'aic|cfg80211' || true

# ----------------------------------------------------------------------
# 10. 设置开机自动加载
# ----------------------------------------------------------------------

log "[10/12] 设置开机自动加载"

sudo tee /etc/modules-load.d/aic8800.conf >/dev/null <<'EOF'
aic_load_fw
aic8800_fdrv
EOF

echo "[OK] /etc/modules-load.d/aic8800.conf"
cat /etc/modules-load.d/aic8800.conf

# ----------------------------------------------------------------------
# 11. Wi-Fi / 蓝牙检查
# ----------------------------------------------------------------------

log "[11/12] 检查 Wi-Fi / Bluetooth"

echo "---------- USB ----------"
lsusb | grep -iE 'a69c|aic' || true

echo
echo "---------- USB topology ----------"
lsusb -t

echo
echo "---------- AIC modules ----------"
lsmod | grep -iE 'aic|cfg80211' || true

echo
echo "---------- Wi-Fi ----------"
iw dev

echo
echo "---------- wlan0 ----------"
ip -br link show wlan0 2>/dev/null || true
ip -4 -br addr show wlan0 2>/dev/null || true
ip -6 -br addr show wlan0 2>/dev/null || true

echo
echo "---------- Wi-Fi link ----------"
iw dev wlan0 link 2>/dev/null || true

echo
echo "---------- Route ----------"
ip route

echo
echo "---------- Bluetooth ----------"
lsmod | grep -E 'btusb|bluetooth' || true
hciconfig -a 2>/dev/null || true
bluetoothctl list 2>/dev/null || true

# ----------------------------------------------------------------------
# 12. 网络验证 / dmesg / 最终摘要
# ----------------------------------------------------------------------

log "[12/12] 网络验证 / 内核日志 / 最终摘要"

echo "---------- IPv4 Internet via wlan0 ----------"
ping -I wlan0 -c 4 -W 2 223.5.5.5 2>&1 | tee -a "$LOGFILE" || \
    warn "IPv4 ping 失败或 wlan0 当前尚未连接。"

echo
echo "---------- DNS / IPv6 via wlan0 ----------"
ping -I wlan0 -c 4 -W 2 www.baidu.com 2>&1 | tee -a "$LOGFILE" || \
    warn "DNS/IPv6 ping 失败或当前网络不可用。"

echo
echo "---------- AIC / Wi-Fi dmesg ----------"
sudo dmesg | grep -iE 'aic|8800|firmware|wlan|rwnx|AICWFDBG' | tail -150

echo
echo "---------- Bluetooth dmesg ----------"
sudo dmesg | grep -iE 'btusb|bluetooth|hci' | tail -80

echo
echo "======================================================================"
echo "                         最终安装摘要"
echo "======================================================================"

if lsmod | grep -q 'aic8800_fdrv'; then
    echo "[PASS] aic8800_fdrv 已加载"
else
    echo "[CHECK] aic8800_fdrv 未检测到"
fi

if lsmod | grep -q 'aic_load_fw'; then
    echo "[PASS] aic_load_fw 已加载"
else
    echo "[CHECK] aic_load_fw 未检测到"
fi

if lsusb | grep -q 'a69c:8d81'; then
    echo "[PASS] USB 已进入 a69c:8d81 工作状态"
elif lsusb | grep -q 'a69c:8d83'; then
    echo "[PASS] USB 已进入 a69c:8d83 Wi-Fi-only 工作状态"
else
    echo "[CHECK] 当前未检测到 a69c:8d81 / a69c:8d83"
fi

if iw dev wlan0 link 2>/dev/null | grep -q 'Connected to'; then
    echo "[PASS] wlan0 已连接 Wi-Fi"
else
    echo "[CHECK] wlan0 当前没有检测到已连接状态"
fi

if hciconfig hci0 >/dev/null 2>&1; then
    echo "[PASS] Bluetooth hci0 已检测到"
else
    echo "[CHECK] Bluetooth hci0 未检测到"
fi

echo
echo "内核模块目录：$MODDIR"
echo "安装日志：$LOGFILE"
echo
echo "参考 / 致谢："
echo "  直接使用： https://github.com/shenmintao/aic8800d80"
echo "  技术参考： https://github.com/olamellberg/AIC8800D80"
echo
echo "说明："
echo "  - 本脚本故意跳过 aic_zlp_quirk.ko。"
echo "  - 当前方案已经在 UOS V20 / ARM64 / Linux 4.19.0-arm64-desktop"
echo "    环境中实际验证过 Wi-Fi 和 Bluetooth。"
echo "  - 开机自动加载配置已经写入 /etc/modules-load.d/aic8800.conf。"
echo "======================================================================"
