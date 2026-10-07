# mt76-mt7662u

> MediaTek **MT7662U**（USB ID `0e8d:7662`）BT+WiFi combo USB 网卡的 Linux 驱动
> 基于 [openwrt/mt76](https://github.com/openwrt/mt76) 上游驱动适配（基线 commit `018f6031`，2026-03-21）

给一块"系统认不出的 USB 网卡"提供驱动支持，并修复其在新内核上的两类问题：
**USB ID 缺失 + 被蓝牙驱动抢占接口**（导致只加 ID 也没用）、**内核 6.19 API 变化导致的编译失败**。

---

## 支持的设备（VID:PID）

| USB ID | 设备 | 状态 |
|---|---|---|
| **`0e8d:7662`** | MediaTek MT7662 BT+WIFI combo（WiFi = MT7612，双频 802.11ac 2×2） | ✅ **本仓库新增**，实测通过 |
| `0e8d:2870` | 同一网卡的 Zero-CD 预切换状态（虚拟光驱，Windows 驱动盘） | 由 `usb_modeswitch` 负责切换到 7662，与本驱动无关 |
| 其余设备 | Asus / Netgear / TP-Link / Aukey / Edimax 等（详见 [`mt76x2/usb.c`](mt76x2/usb.c)） | 上游原样保留，不受影响 |

该设备为 combo 芯片，一个 USB 设备暴露 3 个接口：接口 0/1 是蓝牙（class e0，归 btusb），
接口 2（vendor-specific，2 bulk IN + 6 bulk OUT）是 WiFi —— **本驱动的绑定对象**。

## 适用内核范围

| 内核版本 | 状态 | 说明 |
|---|---|---|
| **6.19.x** | ✅ **实测通过** | 6.19.11-zen1，x86_64，含固件加载 / 双频扫描 / 接入验证 |
| 6.16 – 6.18 | ⚠️ 理论可用，未测试 | 补丁使用了 6.16 引入的 `hrtimer_setup()` |
| ≤ 6.15 | ❌ 不适用 | `hrtimer_setup` 尚不存在；请使用与内核匹配的上游 mt76 版本，仅应用 [`patches/0001`](patches/0001-mt76x2u-add-MT7662U-combo-USB-ID-interface-match.patch)（接口匹配补丁，内核无关），无需应用 0002 的 hrtimer 部分 |

内核 6.19 移除了 `asm/unaligned.h` 与 `hrtimer_init()`，上游基线代码在新内核上无法直接编译；
本仓库已包含全部适配（见 [`patches/0002`](patches/0002-kernel-6.19-API-compat.patch)）。

固件不随本仓库分发，来自 [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware)：
`mt7662.bin` + `mt7662_rom_patch.bin`（内核开启 `CONFIG_FW_LOADER_COMPRESS_ZSTD` 时可直接用 `.zst` 版本）。

## 背景：为什么"只加 USB ID"不够？

这块网卡的 WiFi 接口会被**蓝牙驱动 btusb 的 MTK 路径误当作 ISO 数据接口抢占**
（`usb_driver_claim_interface`，该逻辑为 MT79xx 设计，假定"2 号接口属于蓝牙"）。
USB 核心只对"当前无驱动"的接口触发 probe —— 所以 mt76x2u 即使加了设备 ID、
模块加载成功，也永远轮不到探测，表现为"设备识别不了"。

本仓库的核心补丁是改用**接口级匹配**：

```c
{ USB_DEVICE_AND_INTERFACE_INFO(0x0e8d, 0x7662, 0xff, 0xff, 0xff) }
```

好处：

1. 只命中 vendor-specific 的 WiFi 接口，不与 btusb 争抢蓝牙接口；
2. 生成接口级 modalias，**udev 在插入时自动加载模块**，无需手动配置；
3. 热插拔时毫秒级完成绑定，btusb 事后的抢占会因 `-EBUSY` 失败，蓝牙照常工作，互不干扰。

完整排查过程（btusb 源码分析、解绑路径安全分析、竞态分析等）见
[docs/troubleshooting-notes.md](docs/troubleshooting-notes.md)。

## 快速开始

依赖：当前内核头文件、`make`、`gcc`、`linux-firmware`。
（Arch 示例：`sudo pacman -S linux-zen-headers linux-firmware`）

```bash
git clone <本仓库>
cd mt76-mt7662u
bash mt7662u-setup.sh        # 自动编译(普通用户) → sudo 安装/绑定 → 部署 udev 规则
```

脚本幂等，可重复运行（内核升级后重跑即可重建）。之后：

```bash
nmcli device wifi list        # 扫描验证
nmcli device wifi connect "SSID" password "xxxx"
```

### 手动方式

```bash
# 编译（只构建 mt76x2u 所需的模块子集）
make -j$(nproc) -C /lib/modules/$(uname -r)/build M=$PWD \
    CONFIG_MT76_SDIO= CONFIG_MT76x0_COMMON= CONFIG_MT76x2E= \
    CONFIG_MT7603E= CONFIG_MT7615_COMMON= CONFIG_MT7915E= \
    CONFIG_MT7921_COMMON= CONFIG_MT7996E= CONFIG_MT7925_COMMON= \
    CONFIG_MT792x_LIB= CONFIG_MT792x_USB= CONFIG_MT76_CONNAC_LIB= \
    CONFIG_MT76_NPU= CONFIG_NL80211_TESTMODE=

# 安装到 updates/（优先级高于内核自带模块）
UPD=/usr/lib/modules/$(uname -r)/updates/mt7662u
sudo mkdir -p $UPD/mt76x2
sudo install -m644 mt76.ko mt76-usb.ko mt76x02-lib.ko mt76x02-usb.ko -t $UPD/
sudo install -m644 mt76x2/mt76x2-common.ko mt76x2/mt76x2u.ko -t $UPD/mt76x2/
sudo depmod $(uname -r)
sudo modprobe mt76x2u

# 若设备当前已被 btusb 占用（已插状态），安全释放并绑定：
DEV=""
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && [ "$(cat "$d/idVendor")" = 0e8d ] && \
    [ "$(cat "$d/idProduct")" = 7662 ] && DEV=$(basename "$d")
done
echo "$DEV:1.0" | sudo tee /sys/bus/usb/drivers/btusb/unbind   # 解绑主蓝牙接口，连带释放全部三个接口
echo "$DEV:1.2" | sudo tee /sys/bus/usb/drivers/mt76x2u/bind   # 绑定 WiFi 接口
```

> 一键脚本 `mt7662u-setup.sh` 额外部署了 udev 规则（`/etc/udev/rules.d/99-mt7662u.rules` +
> `/usr/local/sbin/mt7662u-bind`），保证插拔/开机自动绑定 —— 手动方式不含这一步，建议优先用脚本。

## 已知限制

- **蓝牙部分不可用**：btusb 对 MT7662 误用 MT79xx 的 WMT 握手协议（`Failed to get device id (-110)`），
  属内核 btusb 层问题，与 WiFi 无关；WiFi 完全不受影响
- 驱动初始化日志会出现 3 条 `error: MCU resp evt:9 seq:1-0` —— 良性告警，不影响功能
- **内核升级后**：`updates/` 下的模块因 vermagic 不匹配自动失效，udev 兜底规则会改用
  新内核自带的 mt76x2u + 动态 `new_id` 继续工作；重跑 `mt7662u-setup.sh` 可恢复修补版模块
- 本仓库的模块会以 `updates/` 优先级覆盖系统自带 mt76 模块（同源代码）；若系统内还有
  其他 mt76 芯片的设备，请自行评估

## 目录结构

```
├── mt7662u-setup.sh    # 一键编译/安装/绑定脚本
├── patches/            # 相对上游基线的补丁（可单独应用到其他 mt76 版本）
│   ├── 0001-...        #   新增 0e8d:7662 接口级匹配（内核无关）
│   └── 0002-...        #   6.19 API 适配（unaligned.h / hrtimer_setup / version.h）
├── docs/
│   └── troubleshooting-notes.md   # 完整排查笔记（根因分析、命令、方法论）
├── mt76x2/             # mt76 上游源码（含上述补丁）
└── (其余为 openwrt/mt76 完整源码树，基线 018f6031，剔除 firmware/ 二进制)
```

## 致谢与许可

- 上游驱动与全部核心代码：[openwrt/mt76](https://github.com/openwrt/mt76) 及其贡献者
  （Felix Fietkau、Lorenzo Bianconi 等）
- 许可证：BSD-3-Clause-Clear —— 见 [LICENSE](LICENSE)，上游版权声明原样保留
- 固件由 linux-firmware 项目提供，不在本仓库内分发

---

## English summary

Linux driver (mt76x2u) for the **MediaTek MT7662U BT+WiFi combo USB adapter (`0e8d:7662`)**,
based on upstream [openwrt/mt76](https://github.com/openwrt/mt76) @ `018f6031`.

- **Why a fork**: the adapter's WiFi interface (vendor-specific, intf #2) gets stolen by the
  Bluetooth driver `btusb` (its MediaTek ISO-interface claim), so merely adding the USB ID
  never works. This tree matches the WiFi interface specifically via
  `USB_DEVICE_AND_INTERFACE_INFO(0x0e8d, 0x7662, 0xff, 0xff, 0xff)` and includes
  Linux 6.19 API compatibility fixes (`linux/unaligned.h`, `hrtimer_setup`).
- **Kernel support**: verified on 6.19.11; theoretically ≥ 6.16 (uses `hrtimer_setup`);
  for ≤ 6.15 use a kernel-matching upstream tree + `patches/0001` only.
- **Firmware** comes from the `linux-firmware` package (`mt7662.bin`, `mt7662_rom_patch.bin`).
- **Usage**: `bash mt7662u-setup.sh` (builds, installs to `updates/`, binds the WiFi
  interface, installs a udev rule for hotplug persistence).
- **Known limitation**: the Bluetooth part of the combo doesn't work (btusb uses the
  MT79xx WMT protocol against this old chip) — a kernel btusb issue, unrelated to WiFi.

See [docs/troubleshooting-notes.md](docs/troubleshooting-notes.md) for the full analysis (in Chinese).
