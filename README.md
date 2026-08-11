# AIC8800D80 USB Wi-Fi 在 ARM64 + UOS 20 + Linux 4.19 上的驱动安装与适配记录

> 本文记录一次在 **ARM64 + UOS 20 + Linux 4.19** 环境下，为 **AIC8800D80 USB Wi-Fi 网卡**安装 Linux 驱动的完整排障过程。
>
> 核心路线：**USB 设备识别 → 驱动源码 → Linux 4.19 兼容 → ARM64 编译 → 内核模块 → 固件 → WLAN 接口 → Wi-Fi 扫描**。

## 1. 测试环境

| 项目 | 环境 |
|---|---|
| OS | UOS 20 |
| CPU 架构 | ARM64 / AArch64 |
| Kernel | Linux 4.19.x |
| Kernel 版本 | `4.19.0-arm64-desktop` |
| 无线芯片 | AIC8800D80 |
| 接口 | USB |
| 驱动方式 | Linux Kernel Module |
| 编译方式 | 目标 ARM64 系统本机编译 |

确认架构：

```bash
uname -m
```

预期：

```text
aarch64
```

确认 Kernel：

```bash
uname -r
```

本次环境：

```text
4.19.0-arm64-desktop
```

---

## 2. 为什么这个驱动比较麻烦？

AIC8800D80 插入 USB 后，并不意味着系统已经具备完整的 Wi-Fi 驱动能力。

实际问题可以拆成：

```text
USB 设备识别
      ↓
设备进入正确工作状态
      ↓
Linux 驱动源码
      ↓
ARM64 编译
      ↓
Linux 4.19 Kernel API 兼容
      ↓
生成 .ko
      ↓
加载 Kernel Module
      ↓
Firmware
      ↓
创建 wlan 接口
      ↓
扫描 Wi-Fi
```

因此：

> `lsusb` 能看到设备，不等于 Wi-Fi 驱动已经成功。

同样：

> `make` 编译成功，也不等于 Wi-Fi 最终可用。

真正的成功标准应该是完整链路都正常。

---

## 3. 第一步：确认 USB 设备

插入 AIC8800D80 USB 网卡后，执行：

```bash
lsusb
```

确认 Linux USB 子系统能够发现设备。

查看内核日志：

```bash
dmesg | tail -n 100
```

或者：

```bash
dmesg | grep -i usb
```

进一步过滤 AIC8800：

```bash
dmesg | grep -Ei 'aic|8800'
```

这一阶段主要回答：

> **USB 设备有没有被 Linux 枚举出来？**

---

## 4. USB 识别 ≠ Wi-Fi 驱动成功

排障时很容易出现一个误区：

```bash
lsusb
```

能看到设备，就认为“驱动已经安装成功”。

实际上至少需要验证两个层次。

### USB 层

```bash
lsusb
```

表示 USB 总线能够发现设备。

### Wi-Fi 层

```bash
ip link
```

以及：

```bash
iw dev
```

最终应该看到无线接口，例如：

```text
wlan0
```

具体接口名可能不同。

正确的判断流程应为：

```text
lsusb
  ↓
USB 设备存在
  ↓
驱动加载
  ↓
iw dev
  ↓
无线接口出现
```

---

## 5. 第二步：检查系统有没有自带 AIC8800 驱动

搜索当前 Kernel 的模块目录：

```bash
find /lib/modules/$(uname -r) -type f \\
  \( -iname '*aic*' -o -iname '*8800*' \) \\
  2>/dev/null
```

这一步用于判断当前 UOS 内核是否已经包含可直接使用的 AIC8800/AIC8800D80 驱动。

本次环境没有发现可以直接使用的 AIC8800D80 Wi-Fi 驱动模块，因此没有继续走“直接加载系统已有驱动”的路线，而是采用源码编译。

---

## 6. 为什么不能直接拿网上的 `.ko`？

Linux Kernel Module 与目标 Kernel 存在较强关联。

例如网上找到一个：

```text
aic8800.ko
```

并不能因为文件名一样，就直接放入本机使用。

内核模块至少涉及：

- CPU architecture
- Linux Kernel version
- Kernel configuration
- Kernel ABI
- Kernel API
- Compiler environment

例如针对：

```text
x86_64 + Linux 6.x
```

编译的模块，并不意味着可以直接用于：

```text
ARM64 + Linux 4.19
```

因此本次采用的核心方法是：

> **拿驱动源码，在目标 ARM64 + UOS + Linux 4.19 环境重新编译。**

---

## 7. 第三步：准备 AIC8800 驱动源码

假设驱动源码放在：

```text
~/aic8800d80/
```

进入驱动目录：

```bash
cd ~/aic8800d80/drivers/aic8800
```

查看源码：

```bash
ls
```

检查 Makefile：

```bash
ls -l Makefile
```

---

## 8. 第四步：检查 Linux Kernel Build 环境

首先：

```bash
ls -ld /lib/modules/$(uname -r)
```

然后：

```bash
ls -ld /lib/modules/$(uname -r)/build
```

对于 Linux Kernel Module 编译来说，需要有和当前运行 Kernel 对应的构建环境。

同时检查编译工具：

```bash
gcc --version
```

```bash
make --version
```

理想情况下应具备：

```text
ARM64 / aarch64
        +
UOS 20
        +
Linux 4.19
        +
GCC
        +
GNU Make
        +
对应 Kernel Build Tree
        +
AIC8800 Driver Source
```

---

## 9. 第五步：开始编译

进入源码目录：

```bash
cd ~/aic8800d80/drivers/aic8800
```

执行：

```bash
make
```

如果驱动源码的 Makefile 正确配置，它会调用 Linux Kernel 的构建系统编译内核模块。

### 第一次编译出错怎么办？

不要立即得出“ARM64 不支持”的结论。

更常见的原因是：

```text
驱动源码版本
        ↓
Linux Kernel 版本
```

之间存在 API 差异。

尤其目标环境为 Linux 4.19，而不少驱动源码是在更高版本 Kernel 环境下维护或验证的。

---

## 10. Linux 4.19 是这次最大的兼容性难点

ARM64 并不是这里最困难的因素。

真正麻烦的是：

```text
AIC8800D80
+
ARM64
+
UOS 20
+
Linux 4.19
```

这个组合。

驱动可能涉及：

- cfg80211
- net_device
- USB API
- DMA
- 工作队列
- 内核线程
- 电源管理
- wireless API
- Kernel header
- 不同版本的数据结构

典型报错可能是：

```text
某个结构体成员不存在
某个函数参数数量不同
某个宏没有定义
某个 API 在老版本 Kernel 中不存在
```

本质上属于：

> **驱动源码与目标 Linux Kernel 的 API/ABI 兼容问题。**

---

## 11. 编译完成后检查 `.ko`

不要只看 `make` 是否返回成功。

执行：

```bash
find . -name "*.ko"
```

如果出现 `.ko` 文件，说明内核模块已经生成。

进一步检查：

```bash
modinfo ./xxx.ko
```

重点查看：

```text
filename
license
description
vermagic
```

特别关注：

```text
vermagic
```

以及当前 Kernel：

```bash
uname -r
```

本次目标 Kernel：

```text
4.19.0-arm64-desktop
```

---

## 12. 第六步：安装 `.ko`

把编译出的模块放入当前 Kernel 的模块目录，例如：

```bash
sudo cp xxx.ko \\
  /lib/modules/$(uname -r)/kernel/drivers/net/wireless/
```

更新依赖：

```bash
sudo depmod -a
```

加载模块：

```bash
sudo modprobe <模块名>
```

### 不要盲猜模块名

不要默认：

```bash
modprobe aic8800
```

因为：

```text
源码目录名
≠
.ko 文件名
≠
modprobe 模块名
```

应该以实际生成的 `.ko` 和 `modinfo` 信息为准。

---

## 13. 第七步：检查驱动是否成功加载

```bash
lsmod | grep -Ei 'aic|8800'
```

查看初始化日志：

```bash
dmesg | grep -Ei 'aic|8800'
```

同时检查 Firmware：

```bash
dmesg | grep -Ei 'firmware|wlan'
```

这一阶段主要判断：

```text
Kernel Module
        ↓
是否真的被 Kernel 接受
        ↓
驱动初始化
        ↓
Firmware 加载
```

---

## 14. Firmware 是另一个关键点

即使：

```bash
make
```

成功，且：

```bash
modprobe <模块名>
```

没有明显报错，也不代表 Wi-Fi 一定能工作。

检查固件：

```bash
find /lib/firmware -type f | grep -Ei 'aic|8800'
```

再看日志：

```bash
dmesg | grep -Ei 'firmware|aic|8800'
```

如果出现类似：

```text
failed to load firmware
```

此时重点应该转向 Firmware，而不是继续修改 `.ko`。

---

## 15. 第八步：确认 WLAN 接口

检查网络接口：

```bash
ip link
```

检查无线设备：

```bash
iw dev
```

如果出现无线接口，例如：

```text
wlan0
```

说明驱动已经完成从 USB 到 WLAN 的关键初始化。

---

## 16. 第九步：实际扫描 Wi-Fi

以 `wlan0` 为例：

```bash
sudo iw dev wlan0 scan | head -n 50
```

如果能够扫描到附近 AP，并看到：

```text
SSID
BSSID
signal
frequency
```

等信息，则可以基本确认：

> **AIC8800D80 已经真正进入 Wi-Fi 工作状态。**

---

## 17. 最终验证流程

推荐完整执行：

```bash
# CPU 架构
uname -m

# Kernel
uname -r

# USB
lsusb

# 已加载模块
lsmod | grep -Ei 'aic|8800'

# 驱动 / Firmware 日志
dmesg | grep -Ei 'aic|8800|firmware|wlan'

# 网络接口
ip link

# 无线设备
iw dev
```

最终的判断逻辑：

```text
┌──────────────────────┐
│     lsusb            │
│ USB 设备是否存在？    │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│      lsmod           │
│ 驱动模块是否加载？    │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│       dmesg          │
│ 驱动/Firmware正常？   │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│      iw dev          │
│ WLAN接口是否出现？    │
└──────────┬───────────┘
           │
           ▼
┌──────────────────────┐
│      iw scan         │
│ 是否能扫描AP？        │
└──────────────────────┘
```

---

## 18. 一套可复用的排障命令

以后遇到类似国产 USB Wi-Fi，可以直接按照下面流程检查：

```bash
# 1. CPU 架构
uname -m

# 2. Kernel
uname -r

# 3. USB 设备
lsusb

# 4. 内核日志
dmesg | tail -n 100
dmesg | grep -Ei 'usb|aic|8800|wlan|firmware'

# 5. 搜索系统已有驱动
find /lib/modules/$(uname -r) -type f \\
  \( -iname '*aic*' -o -iname '*8800*' \) \\
  2>/dev/null

# 6. 检查 Kernel Build
ls -ld /lib/modules/$(uname -r)/build

# 7. 进入源码
cd ~/aic8800d80/drivers/aic8800

# 8. 编译
make

# 9. 查找内核模块
find . -name "*.ko"

# 10. 查看模块信息
modinfo ./xxx.ko

# 11. 安装模块
sudo cp xxx.ko \\
  /lib/modules/$(uname -r)/kernel/drivers/net/wireless/

# 12. 更新模块依赖
sudo depmod -a

# 13. 加载驱动
sudo modprobe <模块名>

# 14. 查看模块
lsmod | grep -Ei 'aic|8800'

# 15. 检查 Firmware
find /lib/firmware -type f | grep -Ei 'aic|8800'

# 16. 检查 WLAN
ip link
iw dev

# 17. 扫描 Wi-Fi
sudo iw dev wlan0 scan
```

---

## 19. 这次最值得记录的经验

### 经验 1：不要把“USB 识别”当成“驱动成功”

```text
lsusb
```

只能证明 USB 设备进入了 USB 总线。

真正还需要验证：

```text
驱动
+
Firmware
+
WLAN Interface
+
Wi-Fi Scan
```

---

### 经验 2：ARM64 不是天然障碍

这次实践说明：

> **AIC8800D80 并不是因为 ARM64 就无法使用。**

如果存在 Linux 驱动源码，通常可以尝试：

```text
Source Code
+
Kernel Build System
```

在目标 ARM64 环境重新编译。

更加准确的判断方式应该是：

```text
有没有 Linux 驱动源码？
        ↓
能否适配目标 Kernel？
        ↓
能否在目标 ARM64 环境编译？
        ↓
Firmware 是否齐全？
```

---

### 经验 3：Linux 4.19 是关键限制条件

从驱动开发角度来看，这次真正困难的地方并不是 ARM64，而是：

```text
Linux 4.19
```

因此遇到：

```text
国产 ARM64
+
UOS 20
+
Linux 4.19
```

这样的环境时，不建议直接套用 Ubuntu 22.04/24.04 或 Kernel 5.x/6.x 的驱动教程。

尤其不要直接认为网上找到的预编译 `.ko` 可以复制使用。

---

## 20. 本次成功的核心方法

```text
确认硬件
   ↓
确认 USB
   ↓
确认 ARM64
   ↓
确认 Linux 4.19
   ↓
确认没有现成驱动
   ↓
获取 AIC8800 驱动源码
   ↓
准备 Kernel Build 环境
   ↓
本机编译
   ↓
解决 Kernel 兼容问题
   ↓
生成 .ko
   ↓
安装模块
   ↓
depmod
   ↓
modprobe
   ↓
准备 Firmware
   ↓
检查 dmesg
   ↓
iw dev
   ↓
扫描 Wi-Fi
```

---

## 21. 总结

本次 AIC8800D80 USB Wi-Fi 驱动安装，验证了一条比较通用的国产 ARM Linux 外设驱动路线：

> **没有现成驱动包 ≠ 没有办法驱动。**

对于 UOS、Deepin、麒麟、OpenEuler 等国产 Linux，尤其是 ARM64 + 老版本 Kernel 环境，如果官方没有提供现成安装包，可以优先考虑：

```text
找到 Linux Driver Source
        ↓
匹配目标 Kernel
        ↓
在目标平台重新编译
        ↓
安装 Kernel Module
        ↓
安装 Firmware
        ↓
逐级验证 USB / Kernel / WLAN
```

判断驱动“真正成功”的标准，不应该只是：

```text
make 没报错
```

而应该至少达到：

```text
✅ USB 能识别
✅ .ko 能加载
✅ Firmware 正常
✅ WLAN 接口出现
✅ 能扫描 Wi-Fi
```

---

## 22. 结论

**AIC8800D80 + ARM64 + UOS 20 + Linux 4.19 并不是一个无法解决的组合。**

这次实践说明，对于国产 ARM64 Linux 平台上的第三方硬件，真正重要的是：

```text
硬件识别
+
驱动源码
+
Kernel 兼容性
+
ARM64 编译
+
Firmware
+
逐层验证
```

而不是简单地寻找一个“一键安装驱动包”。

这套思路同样可以用于后续排查其他 USB Wi-Fi、蓝牙、网卡等 Linux 外设。

---

## 23. 环境信息

```text
OS:       UOS 20
ARCH:     aarch64
Kernel:   4.19.0-arm64-desktop
Device:   AIC8800D80
Bus:      USB
```

> **注意：** 本文中的命令以本次排障过程为基础整理。具体 `.ko` 文件名、Firmware 文件名、模块名以及部分编译参数，应以你实际使用的 AIC8800 驱动源码版本为准。
