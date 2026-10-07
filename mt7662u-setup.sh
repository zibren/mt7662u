#!/bin/bash
# MT7662U USB 网卡（0e8d:7662, BT+WIFI combo）驱动编译/安装/绑定脚本
#
# 用法: bash mt7662u-setup.sh
#   - 若无编译产物会先以普通用户身份编译（需已安装当前内核头文件）
#   - 安装/加载等 root 步骤会自动通过 sudo 重新调用本脚本
#
# 脚本所做的核心操作:
#   1. 安装修补版 mt76 模块到 /usr/lib/modules/$(uname -r)/updates/（优先级高于内核自带）
#   2. 解绑 btusb 对本设备的占用（btusb 的 MTK 路径会把 WiFi 接口误当 ISO 接口抢占）
#   3. 绑定 mt76x2u 到 vendor-specific 的 WiFi 接口
#   4. 部署 udev 规则，保证以后插拔/开机自动恢复
#
# 幂等可重复运行，可作"修复"脚本使用。

set -u
SRC=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)

MAKE_SUBSET="CONFIG_MT76_SDIO= CONFIG_MT76x0_COMMON= CONFIG_MT76x2E= \
CONFIG_MT7603E= CONFIG_MT7615_COMMON= CONFIG_MT7915E= \
CONFIG_MT7921_COMMON= CONFIG_MT7996E= CONFIG_MT7925_COMMON= \
CONFIG_MT792x_LIB= CONFIG_MT792x_USB= CONFIG_MT76_CONNAC_LIB= \
CONFIG_MT76_NPU= CONFIG_NL80211_TESTMODE="

build() {
    echo "== 编译 mt76x2u 模块子集 =="
    if [ ! -d "/lib/modules/$(uname -r)/build" ]; then
        echo "错误: 缺少当前内核头文件（Arch: sudo pacman -S linux-zen-headers / linux-headers）"
        exit 1
    fi
    make -j"$(nproc)" -C "/lib/modules/$(uname -r)/build" M="$SRC" $MAKE_SUBSET || exit 1
}

check_firmware() {
    local ok=""
    for f in /usr/lib/firmware/mt7662.bin /usr/lib/firmware/mt7662.bin.zst \
             /usr/lib/firmware/mediatek/mt7662.bin /usr/lib/firmware/mediatek/mt7662.bin.zst; do
        [ -e "$f" ] && ok=1 && break
    done
    if [ -z "$ok" ]; then
        echo "警告: 未找到 mt7662 固件（mt7662.bin / mt7662_rom_patch.bin）"
        echo "      请安装 linux-firmware 包（Arch/Debian: linux-firmware; Fedora: linux-firmware 或 iwlax2xx... 中的 mediatek 子包）"
        echo "      固件缺失时驱动会加载失败（request_firmware 失败）"
    fi
}

# ---------- 普通用户阶段: 编译, 然后提权 ----------
if [ "$(id -u)" -ne 0 ]; then
    check_firmware
    [ -f "$SRC/mt76x2/mt76x2u.ko" ] || build
    echo "== 以 sudo 运行安装步骤 =="
    exec sudo bash "$0" "$@"
fi

# ---------- root 阶段: 安装/加载/绑定 ----------
KVER=$(uname -r)
UPD=/usr/lib/modules/$KVER/updates/mt7662u

echo "== 1/5 安装修补版 mt76 模块 =="
if [ ! -f "$SRC/mt76x2/mt76x2u.ko" ]; then
    build
fi
mkdir -p "$UPD/mt76x2"
install -m644 "$SRC/mt76.ko" "$SRC/mt76-usb.ko" "$SRC/mt76x02-lib.ko" "$SRC/mt76x02-usb.ko" "$UPD/"
install -m644 "$SRC/mt76x2/mt76x2-common.ko" "$SRC/mt76x2/mt76x2u.ko" "$UPD/mt76x2/"
depmod "$KVER"
echo "已安装到 $UPD（depmod 优先级高于内核自带模块）"

echo "== 2/5 加载驱动 =="
modprobe mac80211 2>/dev/null; modprobe cfg80211 2>/dev/null
if ! modprobe mt76x2u; then
    echo "modprobe mt76x2u 失败（若刚升级过内核请重新运行本脚本重新编译）:"
    dmesg | tail -5
    exit 1
fi
echo "mt76x2u 实际加载文件: $(modinfo -k "$KVER" -n mt76x2u | head -1)"

echo "== 3/5 释放 btusb 对接口的占用 =="
DEV=""
for d in /sys/bus/usb/devices/*; do
    [ -f "$d/idVendor" ] || continue
    if [ "$(cat "$d/idVendor")" = "0e8d" ] && [ "$(cat "$d/idProduct")" = "7662" ]; then
        DEV=$(basename "$d"); break
    fi
done
if [ -z "$DEV" ]; then
    echo "警告: 没找到 0e8d:7662 设备（若刚开机/刚插入，等 usb_modeswitch 切换完成后重跑本脚本）"
else
    echo "USB 设备: $DEV"
    # 对主蓝牙接口(1.0) unbind 是安全且完整的拆除路径:
    # btusb_disconnect 会经 data->disconnect=btusb_mtk_disconnect 释放被强占的 1.2(ISO claim),
    # 再释放 1.1(isoc), hci 随之注销 —— 三个接口全部归还
    if [ -L "/sys/bus/usb/devices/$DEV:1.0/driver" ]; then
        echo "$DEV:1.0" > /sys/bus/usb/drivers/btusb/unbind
        echo "已解绑 btusb（该设备的蓝牙在当前内核无法工作: btusb 对 MT7662 误用 MT79xx 的 WMT 协议）"
    fi
    sleep 1

    echo "== 4/5 绑定 WiFi 接口($DEV:1.2) =="
    if [ -e "/sys/bus/usb/devices/$DEV:1.2/driver" ]; then
        echo "接口已被占用: $(readlink "/sys/bus/usb/devices/$DEV:1.2/driver")"
    else
        # 修补版模块的静态表可直接匹配 vendor-specific 接口
        if ! echo "$DEV:1.2" > /sys/bus/usb/drivers/mt76x2u/bind 2>/dev/null; then
            # 退路（如内核升级后回退到内核自带模块）: 动态 new_id 触发重新匹配
            # 对接口 1.0/1.1 的 probe 会因端点数不符(需 2 IN + 6 OUT)自动失败，无副作用
            echo "0e8d 7662" > /sys/bus/usb/drivers/mt76x2u/new_id 2>/dev/null
            sleep 2
        fi
    fi
    if [ -L "/sys/bus/usb/devices/$DEV:1.2/driver" ]; then
        echo "成功! WiFi 接口已绑定到: $(readlink "/sys/bus/usb/devices/$DEV:1.2/driver" | sed 's|.*/||')"
    else
        echo "绑定失败，最近内核日志:"; dmesg | tail -20
    fi
    # 清理动态 id，避免它将来把蓝牙接口也匹配进来
    echo "0e8d 7662" > /sys/bus/usb/drivers/mt76x2u/remove_id 2>/dev/null || true
fi

echo "== 5/5 部署 udev 持久化规则 =="
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/mt7662u-bind <<'HELPER_EOF'
#!/bin/bash
# udev 触发: 确保 MT7662U combo 的 WiFi 接口绑定到 mt76x2u
intf="$1"                        # 例如 3-1.2:1.2
[ -n "$intf" ] || exit 0
dev="${intf%:*}"                 # 例如 3-1.2
ip=/sys/bus/usb/devices/$intf
[ -e "$ip" ] || exit 0
modprobe mt76x2u 2>/dev/null
# 情况A: btusb 抢占了 WiFi 接口(MTK ISO claim) —— 通过解绑主蓝牙接口安全释放全部
if [ "$(readlink "$ip/driver" 2>/dev/null | sed 's|.*/||')" = "btusb" ]; then
    echo "$dev:1.0" > /sys/bus/usb/drivers/btusb/unbind 2>/dev/null
    sleep 1
fi
# 情况B: 接口空闲 —— 绑定
if [ ! -e "$ip/driver" ]; then
    echo "$intf" > /sys/bus/usb/drivers/mt76x2u/bind 2>/dev/null || \
        echo "0e8d 7662" > /sys/bus/usb/drivers/mt76x2u/new_id 2>/dev/null
    sleep 1
    [ -e "$ip/driver" ] || echo "$intf" > /sys/bus/usb/drivers/mt76x2u/bind 2>/dev/null
    echo "0e8d 7662" > /sys/bus/usb/drivers/mt76x2u/remove_id 2>/dev/null
fi
exit 0
HELPER_EOF
chmod 755 /usr/local/sbin/mt7662u-bind

cat > /etc/udev/rules.d/99-mt7662u.rules <<'RULE_EOF'
# MT7662U BT+WIFI combo: vendor-specific(WiFi)接口出现时确保绑定到 mt76x2u
ACTION=="add", SUBSYSTEM=="usb", ENV{MODALIAS}=="usb:v0E8Dp7662*icFFiscFFipFF*", RUN+="/usr/local/sbin/mt7662u-bind %k"
RULE_EOF
udevadm control --reload
echo "已安装: /usr/local/sbin/mt7662u-bind 和 /etc/udev/rules.d/99-mt7662u.rules"

echo ""
echo "========== 当前状态 =========="
sleep 3
ip -br link
echo "--- 相关内核日志 ---"
dmesg | grep -iE 'mt76|wlan|firmware' | tail -15
