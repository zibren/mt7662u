# MT7662U USB 网卡（0e8d:7662）驱动排查笔记

> 环境：Arch Linux / kernel 6.19.11-zen1-1-zen / x86_64
> 日期：2026-09-23
> 结果：✅ 驱动成功工作，双频扫描正常（2.4G + 5G 各 20+ AP）

---

## 目录

1. [硬件背景](#一硬件背景)
2. [mt76 驱动架构](#二mt76-驱动架构)
3. [完整排查时间线](#三完整排查时间线)
4. [根因分析](#四根因分析为什么只加-usb-id解决不了问题)
5. [解决方案设计](#五解决方案设计)
6. [可复用命令清单](#六可复用命令清单)
7. [排查工具箱](#七排查工具箱以后遇到类似问题的套路)
8. [附录：系统改动清单与维护说明](#八附录系统改动清单与维护说明)

---

## 一、硬件背景

### 1.1 这块卡是什么

主控是联发科 **MT7662** —— 一颗 BT + WiFi **combo（组合）芯片**：

- WiFi 部分 = MT7612：双频 802.11ac（2.4GHz + 5GHz）
- BT 部分 = 蓝牙 4.x

插入后呈现为 `0e8d:7662`，一个 USB 物理设备下挂 **3 个接口（interface）**：

| 接口 | bInterfaceClass | 端点布局 | 实际归属 |
|---|---|---|---|
| `X:1.0` | e0/01/01（蓝牙类） | 2 IN + 1 OUT | 蓝牙 HCI（→ btusb） |
| `X:1.1` | e0/01/01 | 1 IN + 1 OUT | 蓝牙 SCO 音频 |
| `X:1.2` | **ff/ff/ff（厂商自定义）** | **2 IN + 6 OUT** | **WiFi 数据（→ mt76x2u）** |

**关键认知**：Linux USB 驱动模型中，驱动绑定的对象是"接口"而不是物理设备。一个 USB 设备的多个接口可以由多个互不干扰的驱动分别接管。这块网卡的正确分工应该是：btusb 管接口 0/1（蓝牙），mt76x2u 管接口 2（WiFi）。

### 1.2 Zero-CD 机制（插上先当 U 盘）

从内核日志还原出的设备"一生"：

```
19:57:18  新设备 0e8d:2870 出现 → usb-storage 接管（虚拟光驱，给 Windows 装驱动用的）
19:57:19  断开
19:57:20  重新枚举为 0e8d:7662 "BT+WIFI"（真身）
19:57:25  hci1: Failed to get device id (-110)   ← 蓝牙部分的问题，见 §3.4
```

这种"先伪装成 U 盘"的设计叫 **Zero-CD**。从 2870 切换到 7662 是 `usb_modeswitch` 完成的
（配置文件 `/usr/share/usb_modeswitch/0e8d:2870` + udev 规则 `40-usb_modeswitch.rules`），
这一环系统已经配好，无需干预。

### 1.3 端点指纹：无文档判断接口用途

没有芯片手册时，**端点（endpoint）布局就是接口的"指纹"**。mt76 USB 核心的硬性要求
（`usb.c: mt76u_set_endpoints()`）：探测的接口必须**恰好有 2 个 bulk IN + 6 个 bulk OUT**，
否则直接返回 `-EINVAL`。端点编号的用途在 `mt76.h` 中定义：

```c
enum mt76u_out_ep {
    MT_EP_OUT_INBAND_CMD,                      /* ep 8:  控制命令 */
    MT_EP_OUT_AC_BE, AC_BK, AC_VI, AC_VO,      /* ep 4-7: 四个流量队列 */
    MT_EP_OUT_HCCA,                            /* ep 9 */
    __MT_EP_OUT_MAX,                           /* = 6 */
};
```

对照接口 1.2 的实际端点（lsusb -v）：IN = 0x84, 0x85；OUT = 0x08, 0x04~0x07, 0x09
—— 数量与编号和驱动枚举**严丝合缝**，铁证接口 1.2 就是 WiFi。

顺带的一个推论：mt76x2u 若误探蓝牙接口（2 IN + 1 OUT / 1 IN + 1 OUT），会在端点
检查处无害失败（`-EINVAL`），不会向芯片发送任何东西。

---

## 二、mt76 驱动架构

三份源码树中选用了 **openwrt/mt76 上游 master**（本目录 `mt76/`），理由：
内核自带的 mt76x2u 就来自这个项目（同源、行为一致），且是唯一还在维护、
能跟上新内核 API 的树。`mt76_2`（akabul0us fork，面向 kernel 4.14）和
`mt76x2u_driver_linux`（shiqishao，更老的分立驱动）都太老 —— **即使编译通过，
也无法解决真正的问题**（见 §4）。

mt76 是分层模块栈，`lsmod` 的依赖关系可以直接印证：

```
mt76x2u.ko           ← 芯片级 USB 驱动（USB 设备 ID 表在 mt76x2/usb.c）
 ├─ mt76x2-common.ko ← MT7612 芯片公共逻辑（EEPROM、初始化、MCU）
 ├─ mt76x02-usb.ko   ← x02 系列 USB 传输（MCU over USB）
 ├─ mt76x02-lib.ko   ← MAC / PHY / EEPROM / DFS / beacon 公共层
 ├─ mt76-usb.ko      ← USB 传输层（URB、端点管理）
 └─ mt76.ko          ← 核心库（队列、DMA、mac80211 对接）
```

下方还有内核的 `mac80211`（WiFi 框架层）和 `cfg80211`（配置层/用户态接口），
这是所有 Linux WiFi 驱动共同的地基。

固件加载顺序（`journalctl -k` 可见）：

```
ASIC revision: 76620044          ← 芯片应答，控制通道通了
ROM patch build: 20141115060606a ← ROM 补丁固件加载成功
Firmware Version: 0.0.00 Build: 1, Build Time: 201507311614____ ← 主固件加载成功
wlan0 → wlp10s0f3u1u2i2（被 udev 按位置改名）
```

---

## 三、完整排查时间线

### 3.1 第一步：盘"静态环境"，别急着编译

先把"系统已经有什么"查清楚，**内核其实自带了 99% 的东西**：

```bash
lsusb                                    # 设备在总线上：0e8d:7662（Bus 003）
modinfo mt76x2u                          # 内核自带模块存在！
                                         #   但 alias 列表里没有 7662（有 7612、7632）
                                         #   firmware: mt7662.bin + mt7662_rom_patch.bin
ls /usr/lib/firmware/mediatek/           # 固件文件在（.zst 压缩版）
ls -d /lib/modules/$(uname -r)/build     # 编译头文件在
zgrep FW_LOADER_COMPRESS /proc/config.gz # CONFIG_FW_LOADER_COMPRESS_ZSTD=y（能解压 .zst）
zgrep MODULE_SIG_FORCE /proc/config.gz   # 未开启 → 自编译未签名模块可以加载
```

**结论**：设备 ID 确实缺失（猜测对了 1/3），但模块、固件、头文件、加载条件全都具备。

### 3.2 第二步：journalctl 还原设备历史

```bash
journalctl -k -b --no-pager | grep -E '3-1\.2|btusb|hci'
```

收获两个关键信息：
- Zero-CD 两段式枚举（§1.2）；
- `hci1: Failed to get device id (-110)`：蓝牙部分被 btusb 当 MT79xx 处理，
  WMT 握手协议老芯片不认识，必然超时。**此蓝牙在当前内核注定不工作，与 WiFi 无关。**

（注：普通用户读不了 `dmesg` 时用 `journalctl -k` 是平替。）

### 3.3 第三步：查接口归属 → 发现异常

```bash
ls -l /sys/bus/usb/devices/3-1.2:1.*/driver
# 3-1.2:1.0 -> btusb ✓ 合理（蓝牙 HCI）
# 3-1.2:1.1 -> btusb ✓ 合理（SCO 音频，btusb probe 主动 claim 的 isoc 接口）
# 3-1.2:1.2 -> btusb ✗✗✗ WiFi 接口被蓝牙驱动占了！
```

**疑点**：btusb 的 id_table 根本匹配不上 ff/ff/ff 接口（下一步验证），
那它是怎么占上的？

### 3.4 第四步：modinfo 逆推匹配规则

```bash
modinfo btusb | grep alias        # btusb 的匹配别名
# usb:v*p*d*dc*dsc*dp*icE0isc01ip01in*   ← 任意厂商的蓝牙类(e0/01/01)接口
# usb:v0E8Dp763F...                        ← 只有 763F 一个 0e8d 专用项
```

再验证"内核认为接口 1.2 该归谁"：

```bash
cat /sys/bus/usb/devices/3-1.2:1.2/modalias
# usb:v0E8Dp7662d0100dcEFdsc02dp01icFFiscFFipFFin02
modinfo usb:v0E8Dp7662d0100dcEFdsc02dp01icFFiscFFipFFin02   # 查无任何驱动！
```

**实锤**：没有任何驱动的 id_table 能匹配接口 1.2 —— btusb 是通过**别的机制**强占的。

### 3.5 第五步：读 btusb.c 源码找到元凶

本地 `/usr/src/linux-zen` 的源码被裁剪（只剩 Kconfig），从 GitHub 拉了 v6.19 的
`drivers/bluetooth/btusb.c` 分析：

```c
/* 设备表：厂商 0e8d + 蓝牙类接口 → BTUSB_MEDIATEK */
{ USB_VENDOR_AND_INTERFACE_INFO(0x0e8d, 0xe0, 0x01, 0x01),
  .driver_info = BTUSB_MEDIATEK | BTUSB_WIDEBAND_SPEECH },

/* probe：主蓝牙接口之外，主动 claim 相邻接口 */
data->isoc = usb_ifnum_to_if(data->udev, ifnum_base + 1);   /* 接口 1 当 SCO */
...
usb_driver_claim_interface(&btusb_driver, data->isoc, data);

/* MTK 专用路径（蓝牙 hci 上电时，bluetoothd 触发）*/
btmtk_data->isopkt_intf = usb_ifnum_to_if(data->udev, MTK_ISO_IFNUM);  /* 2 号接口！ */
usb_driver_claim_interface(&btusb_driver, isopkt_intf, data);          /* 强占！ */
```

**根因浮出水面**：`usb_driver_claim_interface()` 是一个**绕过 id_table 的强制认领**
接口，本是给 MT79xx 系列蓝牙的 ISO 数据通道设计的（假设"2 号接口是蓝牙的"）。
但这块 MT7662 是老 combo，**2 号接口是 WiFi** —— 蓝牙驱动把 WiFi 接口当成自己的抢走了。

时序：设备插入 → btusb 绑接口 0 → probe 时顺带 claim 接口 1 → bluetoothd 上电 hci
（插上数秒后）→ MTK 路径 claim 接口 2。

### 3.6 第六步：固件名考古

驱动声明加载 `mt7662.bin` / `mt7662_rom_patch.bin` —— 名字像 PCIe 固件
（USB 版按惯例应为 `mt7662u.bin`）。git 考古：

```bash
git log --all -p -- mt76x2/usb_mcu.c | grep -B2 -A2 'mt7662'
# → cf859ad3 (2018-10-15) "mt76x2: align mt76x2 and mt76x2u firmware"
#    USB 与 PCIe 统一固件名，非 bug；内核 6.19 自带模块同样如此声明
```

文件只有 `.zst` 压缩版？没关系：`CONFIG_FW_LOADER_COMPRESS_ZSTD=y` 下，
内核按 `<固件名> → <固件名>.zst` 的顺序自动查找解压。**固件环节排除。**

### 3.7 第七步：编译错误 = 内核 API 演化史

| 编译错误 | 原因 | 修复 |
|---|---|---|
| `asm/unaligned.h: No such file` | 6.19 已整树移除该头文件 | `#include <linux/unaligned.h>` |
| `implicit declaration of 'hrtimer_init'` | 6.16 引入 `hrtimer_setup` 替代，6.19 彻底删除旧 API | `hrtimer_setup(&t, 回调函数, CLOCK_MONOTONIC, HRTIMER_MODE_REL)`，回调直接作参数，原 `.function = ...` 赋值行删除 |

> 教训：编译器提示 "did you mean hrtimers_init" 是误导（完全不相干的函数）。
> 另外 mt76 的 Makefile 开了 `-Werror`，警告也是致命的。

---

## 四、根因分析：为什么"只加 USB ID"解决不了问题

三层原因叠加：

1. **缺设备 ID**（表层）：上游 `mt76x2u` 设备表没有 `0e8d:7662` —— 加上即可，但这不够。
2. **btusb 强占 WiFi 接口**（核心层）：USB 核心的规则是 **probe 回调只对"当前没有驱动"
   的接口触发**。三个接口全被 btusb 捏着，mt76x2u 就算加载成功、ID 也加了，
   连 probe 的机会都没有 —— 这就是"加了 ID 还是识别不了"的直接原因。
3. **源码与 6.19 的 API 差异**（编译层）：`asm/unaligned.h`、`hrtimer_init` 已删除。

也解释了三份源码树的命运：
- `mt76_2`（面向 kernel 4.14）：API 太老，6.19 编不过；
- `mt76x2u_driver_linux`：部分能编（用户已修 `dma_set_mask` 等），但就算加载成功，
  同样卡在 btusb 占接口；
- `mt76`（上游 master）：修两个 API 后可编译，但**只加普通 `USB_DEVICE` 仍不解决核心问题**。

> **最重要的经验**：症状像"驱动不认识设备"，根因却在"另一个驱动占了资源"。
> 换任何版本的源码树都解决不了 —— 必须先解决接口归属。

---

## 五、解决方案设计

### 5.1 一行宏的学问：USB_DEVICE vs USB_DEVICE_AND_INTERFACE_INFO

```c
/* 原来（设备级匹配）：设备上任何接口都命中 → 会去抢蓝牙接口 0/1 */
{ USB_DEVICE(0x0e8d, 0x7662) },

/* 改为（接口级匹配）：只命中 vendor-specific 的 WiFi 接口 */
{ USB_DEVICE_AND_INTERFACE_INFO(0x0e8d, 0x7662, 0xff, 0xff, 0xff) },
```

三个好处：
1. 不与 btusb 争抢蓝牙接口 0/1；
2. 生成**接口级 modalias 别名** → udev 在设备插入时自动 modprobe，无需任何手动配置；
3. 重新插拔时，mt76x2u 在**热插拔瞬间（毫秒级）**绑走接口 2；而蓝牙的 MTK claim 要等
   bluetoothd 上电 hci（秒级）才发生。即便 btusb 后到想强占，
   `usb_driver_claim_interface` 返回 `-EBUSY` 失败，蓝牙照常工作，互不干扰。

### 5.2 解绑策略：为什么解主接口 1.0，而不是直接解接口 1.2

读 `btusb_disconnect()` 源码发现它只认三种身份：`data->intf`（主）/ `isoc` / `diag`。

- **直接 unbind 接口 1.2**（MTK ISO）：走进不匹配任何分支的错误路径 ——
  hci 注销、`kfree(data)`，但接口 0/1 仍挂着指向已释放内存的 intfdata，
  **留下 use-after-free 隐患**；
- **unbind 接口 1.0**（主蓝牙接口）是驱动自己设计的正规出口：
  `btusb_disconnect` → `data->disconnect` = `btusb_mtk_disconnect`
  → `btusb_mtk_release_iso_intf` 释放接口 2 → 再释放接口 1（isoc）
  → hci1 干净注销 —— **三个接口全部干净归还**。
  （前置校验：`CONFIG_BT_HCIBTUSB_MTK=y`，否则释放钩子不存在。）

### 5.3 持久化：三层保险

| 层 | 机制 | 覆盖场景 |
|---|---|---|
| 1 | 修补版模块装进 `/usr/lib/modules/$(uname -r)/updates/`（depmod 优先级高于 kernel/ 自带） | 插上即自动加载并绑定 |
| 2 | udev 规则 + 辅助脚本（检测到被 btusb 占用则自动释放再绑定） | 极端竞态、btusb 先占 |
| 3 | 内核升级后 `updates/` 模块因 vermagic 不匹配自动失效 → modprobe 回退到新内核自带 mt76x2u → 辅助脚本用动态 `new_id` 完成绑定 | 内核升级，功能不断 |

动态 `new_id` 的一个细节：它匹配设备所有接口，但探测接口 0/1 时会因端点数不符
（需要 2 IN + 6 OUT）在早期无害失败，最终只有接口 2 绑定成功。绑定后用 `remove_id`
清掉动态 ID，避免将来它把蓝牙接口也匹配进来。

---

## 六、可复用命令清单

### 6.1 编译（只编需要的子集）

```bash
cd /home/zibiren/mt76/mt76
make -j$(nproc) -C /lib/modules/$(uname -r)/build M=$PWD \
     CONFIG_MT76_SDIO= CONFIG_MT76x0_COMMON= CONFIG_MT76x2E= \
     CONFIG_MT7603E= CONFIG_MT7615_COMMON= CONFIG_MT7915E= \
     CONFIG_MT7921_COMMON= CONFIG_MT7996E= CONFIG_MT7925_COMMON= \
     CONFIG_MT792x_LIB= CONFIG_MT792x_USB= CONFIG_MT76_CONNAC_LIB= \
     CONFIG_MT76_NPU= CONFIG_NL80211_TESTMODE=
# （命令行置空 CONFIG_XXX= 即"禁用"，省时间、避开无关芯片的编译错误）
# 产物：mt76.ko mt76-usb.ko mt76x02-lib.ko mt76x02-usb.ko mt76x2/mt76x2-common.ko mt76x2/mt76x2u.ko
```

### 6.2 安装与加载

```bash
UPD=/usr/lib/modules/$(uname -r)/updates/mt7662u
mkdir -p $UPD/mt76x2
install -m644 mt76.ko mt76-usb.ko mt76x02-lib.ko mt76x02-usb.ko $UPD/
install -m644 mt76x2/mt76x2-common.ko mt76x2/mt76x2u.ko $UPD/mt76x2/
depmod $(uname -r)

modprobe mt76x2u
modinfo -n mt76x2u     # 验证加载的确实是 updates/ 里的修补版
```

### 6.3 手动绑定（当前会话立即使能）

```bash
# 1. 找到设备（假设是 3-1.2）
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] && [ "$(cat $d/idVendor)" = 0e8d ] && \
    [ "$(cat $d/idProduct)" = 7662 ] && basename "$d"
done

# 2. 解绑主蓝牙接口 → 连带安全释放全部三个接口
echo 3-1.2:1.0 > /sys/bus/usb/drivers/btusb/unbind

# 3. 绑定 WiFi 接口（优先静态表直接 bind；失败则动态 new_id 触发重新匹配）
echo 3-1.2:1.2 > /sys/bus/usb/drivers/mt76x2u/bind \
  || echo "0e8d 7662" > /sys/bus/usb/drivers/mt76x2u/new_id

# 4. 清理动态 ID（防止将来误抢蓝牙接口）
echo "0e8d 7662" > /sys/bus/usb/drivers/mt76x2u/remove_id
```

以上已封装为一键脚本：`/home/zibiren/mt76/mt7662u-setup.sh`（sudo 运行，
会自动完成安装、加载、解绑、绑定、部署 udev 规则）。

### 6.4 分层验证（每层证明不同的事）

```bash
# 层 1：控制通道 + 固件（journalctl -k）
#   ASIC revision: 76620044 → ROM patch build → Firmware Build Time
# 层 2：接口层
ip -br link                                   # 应出现 wlp10s0f3u1u2i2
nmcli device status                           # NetworkManager 识别为 wifi
# 层 3：功能层（真扫描）—— 让 NetworkManager 以 root 身份代扫，自己无需 sudo
nmcli device wifi list ifname wlp10s0f3u1u2i2
# 连接测试：
nmcli device wifi connect "SSID" password "密码" ifname wlp10s0f3u1u2i2
```

---

## 七、排查工具箱（以后遇到类似问题的套路）

```bash
# ① 设备在不在、长什么样
lsusb                              # VID:PID
lsusb -v -d 0e8d:7662               # 接口/端点详情（端点指纹）

# ② 接口被谁占着
ls -l /sys/bus/usb/devices/3-1.2:1.*/driver

# ③ 问内核"这个接口该归谁管"（灵魂拷问三连）
cat /sys/bus/usb/devices/3-1.2:1.2/modalias
modinfo <上面这串>                  # 内核模块别名匹配查询
modinfo mt76x2u | grep alias        # 逆向理解某驱动的匹配规则

# ④ 看内核日志（普通用户 dmesg 被禁时）
journalctl -k -b --no-pager

# ⑤ 手动管理驱动（不重启、不重插的瑞士军刀）
echo <接口名> > /sys/bus/usb/drivers/<驱动>/bind
echo <接口名> > /sys/bus/usb/drivers/<驱动>/unbind
echo "vid pid"  > /sys/bus/usb/drivers/<驱动>/new_id     # 动态加 ID 并触发重新匹配
echo "vid pid"  > /sys/bus/usb/drivers/<驱动>/remove_id

# ⑥ 查内核配置
zgrep <CONFIG_项> /proc/config.gz

# ⑦ 内核模块信息四件套
modinfo <模块>       # filename/alias/firmware/depends/vermagic
lsmod                # 已加载模块与依赖
modinfo -n <模块>    # depmod 实际会加载哪个文件（updates/ 优先级更高）
depmod $(uname -r)   # 安装模块后必须刷新索引

# ⑧ 源码考古
git log --all -p -- <文件>          # "这个行为是哪个提交改的"
git show <commit>                   # 提交详情
```

**方法论总结**：
1. 先盘静态环境（模块/固件/头文件/内核配置），再动手；
2. 从日志还原设备的完整生命周期；
3. 用端点指纹做无文档的接口归属判断;
4. `modinfo` 别名 + sysfs modalias 逆推匹配规则，定位"谁抢了谁"；
5. 改代码前先想清楚：这个改动如何影响 probe 时序、udev 自动加载、与其他驱动的竞态;
6. 验证分层做：日志（控制通道）→ 接口（注册）→ 扫描（功能）。

---

## 八、附录：系统改动清单与维护说明

### 8.1 本次改动一览

**源码修改**（`/home/zibiren/mt76/mt76/`，均未提交）：

| 文件 | 改动 | 目的 |
|---|---|---|
| `mt76x2/usb.c:28` | `USB_DEVICE(0x0e8d,0x7662)` → `USB_DEVICE_AND_INTERFACE_INFO(0x0e8d,0x7662,0xff,0xff,0xff)` | 只匹配 WiFi 接口，不抢蓝牙接口 |
| `mt76x2/eeprom.c:8` | `asm/unaligned.h` → `linux/unaligned.h` | 6.19 头文件适配 |
| `mt76x02_usb_core.c:267` | `hrtimer_init` + 赋值 `.function` → `hrtimer_setup(...)` | 6.19 API 适配 |

**系统安装**（由 `mt7662u-setup.sh` 完成）：

| 路径 | 内容 |
|---|---|
| `/usr/lib/modules/$(uname -r)/updates/mt7662u/` | 编译出的 6 个 .ko（depmod 优先级高于内核自带） |
| `/usr/local/sbin/mt7662u-bind` | udev 触发的辅助绑定脚本（含 btusb 占用时的自动释放逻辑） |
| `/etc/udev/rules.d/99-mt7662u.rules` | 监听 7662 的 vendor-specific 接口 add 事件 |
| `/home/zibiren/mt76/mt7662u-setup.sh` | 一键安装/修复脚本（幂等，可重复运行） |

**无需照料的既有配置**：usb_modeswitch 的 0e8d:2870 切换规则、
`/usr/lib/firmware/` 下的固件符号链接（断链无害，内核自动走 `.zst` 解压）。

### 8.2 内核升级后怎么办

- **通常什么都不用做**：`updates/` 里的模块 vermagic 不匹配新内核会自动失效，
  modprobe 回退到新内核自带的 mt76x2u，udev 辅助脚本用动态 `new_id` 完成绑定，
  功能不断（失去的只是"接口级精确匹配"，风险极低）。
- **想恢复修补版模块**（推荐，可获得 udev 原生自动加载）：

```bash
cd /home/zibiren/mt76/mt76
# 若新内核 API 又有变化，先修编译错误（git log 或查 torvalds 树对照）
make -j$(nproc) -C /lib/modules/$(uname -r)/build M=$PWD \
     CONFIG_MT76_SDIO= CONFIG_MT76x0_COMMON= CONFIG_MT76x2E= \
     CONFIG_MT7603E= CONFIG_MT7615_COMMON= CONFIG_MT7915E= \
     CONFIG_MT7921_COMMON= CONFIG_MT7996E= CONFIG_MT7925_COMMON= \
     CONFIG_MT792x_LIB= CONFIG_MT792x_USB= CONFIG_MT76_CONNAC_LIB= \
     CONFIG_MT76_NPU= CONFIG_NL80211_TESTMODE=
sudo bash /home/zibiren/mt76/mt7662u-setup.sh   # 脚本会覆盖安装到新内核的 updates/
```

- **验证**：`modinfo -n mt76x2u` 应指向 `updates/mt7662u/`；插拔后
  `nmcli device wifi list ifname wlp10s0f3u1u2i2` 能扫到 AP。

### 8.3 遗留事项

- **蓝牙不可用**（与本卡无关的内核层问题）：btusb 对 MT7662 用的是 MT79xx 的
  WMT 握手协议（`hci1: Failed to get device id (-110)`），老芯片不识别，必然超时。
  若未来内核的 btusb 增加了对老 MTK 的适配，蓝牙可自然恢复；
- 初始化时的三条 `error: MCU resp evt:9 seq:1-0`：仅在固件加载瞬间出现一次，
  之后（含扫描全程）日志干净，功能完好，属良性告警，可忽略。
