#!/bin/bash
# ============================================================
# AIC8800D80 USB Wi-Fi/蓝牙驱动一键安装脚本
#
# 目标环境：
#   UOS V20
#   ARM64 / aarch64
#   Linux 4.19.0-arm64-desktop
#   AIC8800D80 USB 网卡
#
# 本脚本根据本次实际成功过程整理：
#   1. 安装编译/USB模式切换依赖
#   2. 下载 AIC8800D80 驱动源码
#   3. 运行官方 install.sh 安装固件、udev、usb_modeswitch
#   4. 处理 USB 模式：
#        1111:1111 -> a69c:8d80 -> a69c:8d81
#   5. 绕过 Linux 4.19 不兼容的 aic_zlp_quirk
#   6. 单独编译：
#        aic_load_fw.ko
#        aic8800_fdrv.ko
#   7. 安装内核模块并 depmod
#   8. 加载 Wi-Fi/固件模块
#   9. 设置开机自动加载
#  10. 检查 Wi-Fi / 蓝牙 / 网络
#
# 注意：
#   - 请先插入 AIC8800D80 USB 网卡。
#   - 本脚本不会修复 aic_zlp_quirk；Linux 4.19 上实际成功方案
#     是跳过该模块。
#   - 运行官方 install.sh 时 DKMS 可能报错，这是预期现象；
#     脚本会继续手动编译核心模块。
# ============================================================

set -u

REPO_URL="https://github.com/shenmintao/aic8800d80.git"
WORKDIR="$HOME/aic8800d80"
KVER="$(uname -r)"
KBUILD="/lib/modules/${KVER}/build"
MODDIR="/lib/modules/${KVER}/extra/aic8800"

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

run_or_warn() {
    "$@" || {
        echo "[WARN] 命令执行失败，但继续： $*"
        return 0
    }
}

# ------------------------------------------------------------
# 0. 检查系统架构 / 内核
# ------------------------------------------------------------
log "[0/10] 检查系统环境"

echo "Kernel : $(uname -r)"
echo "Arch   : $(uname -m)"
echo "System : $(uname -a)"

if [ "$(uname -m)" != "aarch64" ]; then
    echo "[WARN] 当前架构不是 aarch64，请确认是否为目标环境。"
fi

if [ ! -e "$KBUILD" ]; then
    echo "[ERROR] 找不到内核编译目录：$KBUILD"
    exit 1
fi

echo "[OK] 内核编译目录：$(readlink -f "$KBUILD")"

# ------------------------------------------------------------
# 1. 安装依赖
# ------------------------------------------------------------
log "[1/10] 安装编译 / USB 模式切换依赖"

sudo apt update

sudo apt install -y \
    git \
    make \
    gcc \
    bc \
    dkms \
    build-essential \
    mokutil \
    eject \
    usb-modeswitch \
    sg3-utils \
    iw \
    ethtool \
    rfkill \
    bluez

# ------------------------------------------------------------
# 2. 下载源码
# ------------------------------------------------------------
log "[2/10] 下载 AIC8800D80 驱动源码"

if [ -d "$WORKDIR/.git" ]; then
    echo "[INFO] 已存在源码目录：$WORKDIR"
    cd "$WORKDIR"
    git pull --ff-only || true
else
    git clone "$REPO_URL" "$WORKDIR"
    cd "$WORKDIR"
fi

git status --short || true

# ------------------------------------------------------------
# 3. 运行官方安装脚本
#
# 作用：
#   - 安装固件
#   - 安装 udev 规则
#   - 安装 usb_modeswitch 配置
#   - 安装 DKMS / 依赖
#
# Linux 4.19 上 DKMS 预计会因 aic_zlp_quirk 报错。
# 即使失败，也继续后面的手动编译。
# ------------------------------------------------------------
log "[3/10] 安装官方固件 / udev / USB模式切换配置"

sudo chmod +x install.sh

if sudo ./install.sh; then
    echo "[OK] 官方 install.sh 执行完成"
else
    echo "[WARN] 官方 install.sh 返回失败。"
    echo "[INFO] 如果失败点是 aic_zlp_quirk / regs_get_kernel_argument，"
    echo "       这是 Linux 4.19 ARM64 的已知兼容性问题，继续执行即可。"
fi

# ------------------------------------------------------------
# 4. 查看 / 执行 USB 模式切换
#
# AIC8800D80 常见流程：
#   1111:1111 -> a69c:8d80 -> a69c:8d81
# ------------------------------------------------------------
log "[4/10] USB 模式切换"

echo "[INFO] 当前 AIC USB 设备："
lsusb | grep -iE '1111|a69c|aic' || true

if lsusb | grep -q '1111:1111'; then
    echo "[INFO] 检测到 1111:1111，执行 usb_modeswitch..."

    if [ -f /etc/usb_modeswitch.d/1111:1111 ]; then
        sudo usb_modeswitch -c /etc/usb_modeswitch.d/1111:1111 || true
    else
        echo "[WARN] 找不到 /etc/usb_modeswitch.d/1111:1111"
    fi

    sleep 3
else
    echo "[INFO] 当前未检测到 1111:1111，跳过显式 mode-switch。"
fi

echo "[INFO] USB 模式切换后："
lsusb | grep -iE '1111|a69c|aic' || true

# ------------------------------------------------------------
# 5. 编译核心模块
#
# 不编译：
#   aic_zlp_quirk
#
# 原因：
#   Linux 4.19 ARM64 没有：
#       regs_get_kernel_argument()
#
# 实际成功的核心模块：
#   aic_load_fw.ko
#   aic8800_fdrv.ko
# ------------------------------------------------------------
log "[5/10] 编译 AIC8800D80 核心模块"

cd "$WORKDIR/drivers/aic8800"

echo "[INFO] 清理旧编译产物..."
make clean || true

echo
echo "[INFO] 编译 aic8800_fdrv..."
make -C "$KBUILD" \
    M="$PWD/aic8800_fdrv" \
    ARCH=arm64 \
    modules

if [ ! -f "$PWD/aic8800_fdrv/aic8800_fdrv.ko" ]; then
    echo "[ERROR] aic8800_fdrv.ko 编译失败"
    exit 1
fi

echo
echo "[INFO] 编译 aic_load_fw..."
make -C "$KBUILD" \
    M="$PWD/aic_load_fw" \
    ARCH=arm64 \
    modules

if [ ! -f "$PWD/aic_load_fw/aic_load_fw.ko" ]; then
    echo "[ERROR] aic_load_fw.ko 编译失败"
    exit 1
fi

echo
echo "[OK] 核心模块编译成功："
find . -name "*.ko" -ls

# ------------------------------------------------------------
# 6. 安装内核模块
# ------------------------------------------------------------
log "[6/10] 安装内核模块"

sudo mkdir -p "$MODDIR"

sudo cp -f \
    "$PWD/aic_load_fw/aic_load_fw.ko" \
    "$MODDIR/"

sudo cp -f \
    "$PWD/aic8800_fdrv/aic8800_fdrv.ko" \
    "$MODDIR/"

sudo depmod -a

echo "[OK] 模块安装位置："
ls -lh "$MODDIR"

# ------------------------------------------------------------
# 7. 加载模块
# ------------------------------------------------------------
log "[7/10] 加载 AIC8800D80 模块"

# 如果之前已经加载，先尝试直接 modprobe。
sudo modprobe aic_load_fw
sudo modprobe aic8800_fdrv

echo
echo "[INFO] 当前 AIC 模块："
lsmod | grep -iE 'aic|cfg80211' || true

# ------------------------------------------------------------
# 8. 设置开机自动加载
# ------------------------------------------------------------
log "[8/10] 设置开机自动加载"

sudo tee /etc/modules-load.d/aic8800.conf >/dev/null <<'EOF'
aic_load_fw
aic8800_fdrv
EOF

echo "[OK] /etc/modules-load.d/aic8800.conf："
cat /etc/modules-load.d/aic8800.conf

# ------------------------------------------------------------
# 9. 检查 USB / Wi-Fi / 蓝牙
# ------------------------------------------------------------
log "[9/10] 检查 AIC8800D80 运行状态"

echo
echo "---------- USB ----------"
lsusb | grep -iE 'a69c|aic' || true

echo
echo "---------- USB 拓扑 ----------"
lsusb -t

echo
echo "---------- Wi-Fi ----------"
iw dev

echo
echo "---------- wlan0 ----------"
ip -br link show wlan0 2>/dev/null || true
ip -4 -br addr show wlan0 2>/dev/null || true

echo
echo "---------- Wi-Fi 链路 ----------"
iw dev wlan0 link 2>/dev/null || true

echo
echo "---------- 路由 ----------"
ip route

echo
echo "---------- Bluetooth ----------"
lsmod | grep -E 'btusb|bluetooth' || true
hciconfig -a 2>/dev/null || true
bluetoothctl list 2>/dev/null || true

# ------------------------------------------------------------
# 10. 网络测试 + 内核日志
# ------------------------------------------------------------
log "[10/10] 网络测试 / dmesg"

echo "---------- IPv4公网 ----------"
ping -I wlan0 -c 4 -W 2 223.5.5.5 2>/dev/null || true

echo
echo "---------- DNS / IPv6 ----------"
ping -I wlan0 -c 4 -W 2 www.baidu.com 2>/dev/null || true

echo
echo "---------- AIC / Wi-Fi dmesg ----------"
sudo dmesg | grep -iE 'aic|8800|firmware|wlan|rwnx|AICWFDBG' | tail -150

echo
echo "---------- Bluetooth dmesg ----------"
sudo dmesg | grep -iE 'btusb|bluetooth|hci' | tail -50

# ------------------------------------------------------------
# 最终提示
# ------------------------------------------------------------
log "安装 / 编译 / USB切换 / Wi-Fi / 蓝牙检查完成"

echo "目标系统：UOS V20 ARM64 Linux 4.19"
echo "AIC 核心模块："
echo "  $MODDIR/aic_load_fw.ko"
echo "  $MODDIR/aic8800_fdrv.ko"
echo
echo "如果看到："
echo "  a69c:8d81"
echo "  wlan0"
echo "  aic8800_fdrv"
echo "  Connected to ..."
echo "  蓝牙 hci0"
echo
echo "则说明 AIC8800D80 已基本完成驱动安装和运行验证。"
