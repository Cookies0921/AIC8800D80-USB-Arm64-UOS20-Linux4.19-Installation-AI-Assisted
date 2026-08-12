# AIC8800D80 USB Wi-Fi 在 ARM64 + UOS 20 + Linux 4.19 上的驱动安装记录

> 本文记录一次在 **ARM64 + UOS 20 + Linux 4.19** 环境下，为 **AIC8800D80 USB Wi-Fi 网卡**完成驱动安装、编译、加载与验证的实际过程。
>
> 核心路线：**USB 模式识别 → 下载驱动源码 → ARM64 / Linux 4.19 编译 → 安装 Firmware / Kernel Module → 加载驱动 → `dmesg` 检查 → WLAN 接口验证 → Wi-Fi 扫描**。

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
USB 工作模式 / 枚举状态
      ↓
下载驱动源码
      ↓
ARM64 编译
      ↓
Linux 4.19 Kernel API 兼容
      ↓
Firmware
      ↓
Kernel Module
      ↓
加载驱动
      ↓
创建 WLAN 接口
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

查看 USB 枚举日志：

```bash
sudo dmesg | tail -n 100
```

筛选 USB：

```bash
sudo dmesg | grep -i usb
```

筛选 AIC8800：

```bash
sudo dmesg | grep -Ei 'aic|8800'
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

正确判断流程：

```text
lsusb
  ↓
USB 设备存在
  ↓
驱动 / Firmware 初始化
  ↓
iw dev
  ↓
无线接口出现
```

---

## 5. 第二步：检查系统有没有自带 AIC8800 驱动

搜索当前 Kernel 的模块目录：

```bash
find /lib/modules/$(uname -r) -type f \
  \( -iname '*aic*' -o -iname '*8800*' \) \
  2>/dev/null
```

本次环境没有发现可以直接用于 AIC8800D80 Wi-Fi 的现成驱动模块，因此采用源码编译方式。

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

## 7. 第三步：下载 AIC8800D80 驱动源码

本次使用的开源驱动仓库：

```text
https://github.com/shenmintao/aic8800d80
```

下载：

```bash
git clone https://github.com/shenmintao/aic8800d80.git
```

进入源码目录：

```bash
cd ~/aic8800d80
```

查看目录：

```bash
ls -lah
```

本仓库包含：

```text
drivers/aic8800   # Wi-Fi Kernel Driver
fw/               # Firmware
usb_modeswitch/   # USB 模式切换配置
```

> **复现建议：** 本 README 记录的是一次成功的 UOS 20 / Linux 4.19 实际环境。由于驱动仓库会继续更新，后续复现时最好记录当时使用的 Git commit，并优先使用与成功环境相同的源码版本，而不是默认使用仓库最新版本。

---

## 8. 第四步：检查 USB 模式 / 模式切换

部分 AIC8800D80 USB 设备上电后会先以 USB 存储 / 虚拟光驱形式出现，然后再切换到无线设备工作模式。

首先观察：

```bash
lsusb
```

并查看：

```bash
sudo dmesg | grep -Ei 'usb|aic|8800|storage|scsi'
```

本仓库提供了 `usb_modeswitch` 相关配置，可用于持久化模式切换：

```bash
cd ~/aic8800d80

sudo cp usb_modeswitch/1111:1111 \
  /etc/usb_modeswitch.d/
```

如果仓库实际提供的文件名或目录结构与当前版本不同，应以对应版本仓库内容为准。

重新插拔设备后再次检查：

```bash
lsusb
```

如果设备从初始 USB 存储模式重新枚举为 AIC8800 的工作模式，说明模式切换环节已经完成。

---

## 9. 第五步：准备 Linux Kernel Build 环境

检查模块目录：

```bash
ls -ld /lib/modules/$(uname -r)
```

检查 Kernel Build：

```bash
ls -ld /lib/modules/$(uname -r)/build
```

检查编译工具：

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

## 10. 第六步：准备 Firmware 和 udev 规则

进入源码目录：

```bash
cd ~/aic8800d80
```

仓库提供 Firmware：

```bash
ls -lah fw
```

按照本次驱动仓库的手动安装方式，可以复制 AIC8800 Firmware：

```bash
sudo cp -r ./fw/aic8800* /lib/firmware/
```

复制 udev 规则：

```bash
sudo cp aic.rules /usr/lib/udev/rules.d/
```

然后可以重新加载 udev 规则：

```bash
sudo udevadm control --reload-rules
```

> **注意：** Firmware 必须与驱动源码版本和硬件版本匹配。仓库作者明确提醒，使用错误的 AIC8800 Firmware 版本可能导致设备初始化异常甚至系统冻结，因此不建议随意混用其他版本的 Firmware。

---

## 11. 第七步：进入驱动源码

```bash
cd ~/aic8800d80/drivers/aic8800
```

查看源码：

```bash
ls -lah
```

检查 Makefile：

```bash
ls -l Makefile
```

---

## 12. 第八步：开始编译

执行：

```bash
make
```

如果此前已经编译过，需要清理后重新编译：

```bash
make clean
make
```

如果编译过程中报错，不要立即得出“ARM64 不支持”的结论。

更常见的原因是：

```text
驱动源码版本
        ↓
Linux Kernel 版本
```

之间存在 API 差异。

尤其目标环境为 Linux 4.19，而当前开源仓库的公开测试信息主要集中在更高版本 Kernel，因此 Linux 4.19 需要特别关注源码兼容性。本次成功实践的价值就在于验证了目标环境下的实际编译路径，而不是假设所有 Kernel 都天然兼容。

---

## 13. Linux 4.19 是这次最大的兼容性难点

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

## 14. 第九步：检查生成的 `.ko`

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

以及：

```bash
uname -r
```

本次目标 Kernel：

```text
4.19.0-arm64-desktop
```

---

## 15. 第十步：安装驱动

本次源码仓库提供了直接安装方式：

```bash
sudo make install
```

如果需要完整重编译：

```bash
make clean
make
sudo make install
```

安装完成后更新模块依赖：

```bash
sudo depmod -a
```

查看安装后的 AIC8800 模块：

```bash
find /lib/modules/$(uname -r) -type f \
  | grep -Ei 'aic|8800'
```

---

## 16. 第十一步：加载 AIC8800 驱动

本仓库 Wi-Fi 驱动模块名为：

```text
aic8800_fdrv
```

加载：

```bash
sudo modprobe aic8800_fdrv
```

检查：

```bash
lsmod | grep aic
```

预期可以看到类似：

```text
aic8800_fdrv
cfg80211
 aic_load_fw
```

具体模块数量和依赖关系以当前 Kernel 为准。

---

## 17. 第十二步：检查 Firmware / 驱动初始化日志

检查 AIC8800：

```bash
sudo dmesg | grep -Ei 'aic|8800'
```

检查 Firmware：

```bash
sudo dmesg | grep -Ei 'firmware'
```

综合检查：

```bash
sudo dmesg | grep -Ei 'aic|8800|firmware|wlan|cfg80211'
```

检查系统中的 Firmware：

```bash
find /lib/firmware -type f | grep -Ei 'aic|8800'
```

如果出现类似：

```text
failed to load firmware
```

那么下一步应该优先检查 Firmware 版本、路径和权限，而不是继续修改 `.ko`。

---

## 18. 第十三步：确认 WLAN 接口

检查所有网络接口：

```bash
ip link
```

检查无线设备：

```bash
iw dev
```

如果出现：

```text
wlan0
```

或其他无线接口名，则说明驱动已经完成从 USB 到 WLAN 的关键初始化。

---

## 19. 第十四步：实际扫描 Wi-Fi

以 `wlan0` 为例：

```bash
sudo iw dev wlan0 scan | head -n 50
```

如果能够看到附近 AP 的：

```text
SSID
BSSID
signal
frequency
```

等信息，则可以基本确认：

> **AIC8800D80 已经真正进入 Wi-Fi 工作状态。**

---

## 20. 最终验证流程

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
sudo dmesg | grep -Ei 'aic|8800|firmware|wlan'

# 网络接口
ip link

# 无线设备
iw dev
```

最终判断逻辑：

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

## 21. 一套可复用的排障命令

以后遇到类似国产 USB Wi-Fi，可以直接按照下面流程检查：

```bash
# 1. CPU 架构
uname -m

# 2. Kernel
uname -r

# 3. USB 设备
lsusb

# 4. 内核日志
sudo dmesg | tail -n 100
sudo dmesg | grep -Ei 'usb|aic|8800|wlan|firmware'

# 5. 搜索系统已有驱动
find /lib/modules/$(uname -r) -type f \
  \( -iname '*aic*' -o -iname '*8800*' \) \
  2>/dev/null

# 6. 检查 Kernel Build
ls -ld /lib/modules/$(uname -r)/build

# 7. 下载源码（首次安装）
git clone https://github.com/shenmintao/aic8800d80.git ~/aic8800d80

# 8. 进入源码
cd ~/aic8800d80

# 9. Firmware / udev
sudo cp -r ./fw/aic8800* /lib/firmware/
sudo cp aic.rules /usr/lib/udev/rules.d/
sudo udevadm control --reload-rules

# 10. 进入驱动目录
cd ~/aic8800d80/drivers/aic8800

# 11. 编译
make

# 12. 查找内核模块
find . -name "*.ko"

# 13. 查看模块信息
modinfo ./xxx.ko

# 14. 安装
sudo make install

# 15. 更新模块依赖
sudo depmod -a

# 16. 加载驱动
sudo modprobe aic8800_fdrv

# 17. 查看模块
lsmod | grep aic

# 18. 检查 Firmware / 驱动日志
sudo dmesg | grep -Ei 'aic|8800|firmware|wlan|cfg80211'

# 19. 检查 WLAN
ip link
iw dev

# 20. 扫描 Wi-Fi
sudo iw dev wlan0 scan
```

---

## 22. 这次最值得记录的经验

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

如果存在 Linux 驱动源码，可以尝试：

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

## 23. 本次成功的核心方法

```text
确认硬件
   ↓
确认 USB
   ↓
确认 USB 模式 / 枚举状态
   ↓
确认 ARM64
   ↓
确认 Linux 4.19
   ↓
确认没有现成驱动
   ↓
下载 AIC8800 驱动源码
   ↓
准备 Firmware / udev
   ↓
准备 Kernel Build 环境
   ↓
本机编译
   ↓
生成 .ko
   ↓
安装模块
   ↓
depmod
   ↓
modprobe
   ↓
检查 dmesg
   ↓
iw dev
   ↓
扫描 Wi-Fi
```

---

## 24. 总结

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
安装 Firmware
        ↓
安装 Kernel Module
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

## 25. 结论

**AIC8800D80 + ARM64 + UOS 20 + Linux 4.19 并不是一个无法解决的组合。**

这次实践说明，对于国产 ARM64 Linux 平台上的第三方硬件，真正重要的是：

```text
硬件识别
+
USB 模式
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

## 26. 环境信息

```text
OS:       UOS 20
ARCH:     aarch64
Kernel:   4.19.0-arm64-desktop
Device:   AIC8800D80
Bus:      USB
```

---

## 27. 参考 / 致谢

本次终端安装流程中实际使用到的核心开源驱动仓库：

### [shenmintao/aic8800d80](https://github.com/shenmintao/aic8800d80)

感谢 **shenmintao** 以及相关开源贡献者提供 AIC8800D80 Linux 驱动源码及配套安装资源。

本次实际安装过程中涉及的仓库内容包括：

- `drivers/aic8800/`：AIC8800 Wi-Fi Kernel Driver 源码
- `fw/`：AIC8800 Firmware
- `aic.rules`：udev 规则
- `usb_modeswitch/`：USB 模式切换配置

本 README 中的下载、编译、安装、Firmware 部署、USB 模式处理以及驱动验证命令，均围绕上述仓库源码整理，并结合本次 **ARM64 + UOS 20 + Linux 4.19** 实际环境进行记录。

> 说明：上游仓库会持续更新，当前仓库的公开测试环境与本次 Linux 4.19 环境并不相同。因此，本 README 不宣称“仓库当前最新版必然兼容 Linux 4.19”，而是记录本次实际成功安装过程。为了复现本次结果，建议同时保留当时使用的 Git commit / 源码版本。

---

## License

本文主要用于记录个人实际驱动安装与排障过程。

AIC8800 驱动源码、Firmware、udev 规则及其他第三方代码的版权和许可证以其原始仓库为准，请遵循对应项目的 License 和版权声明。
