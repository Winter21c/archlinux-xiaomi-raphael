#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 10 — 生成 cache 分区的 FAT32 引导镜像
#  引导链: U-Boot(boot 分区) -> EFI 启动项 \EFI\BOOT\BOOTAA64.EFI (systemd-boot)
#          -> loader/entries/*.conf -> linux.efi (内核 Image) + initramfs
#          -> root=UUID=<rootfs> (userdata 分区)
#  以作者提供的 256MB FAT32 镜像为模板, 只替换/新增文件 (无需 root)。
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount
setup_mtools

confirm_stage "10 生成 cache 引导镜像"
KV="$(cat "$WORK/kver" 2>/dev/null || true)"
UUID="$(rootfs_uuid)"
IMG="$OUT/boot-cache.img"

[ -s "$DL/xiaomi-k20pro-boot.img" ] || die "缺少 FAT 模板 ($DL/xiaomi-k20pro-boot.img)"
cp -f "$DL/xiaomi-k20pro-boot.img" "$IMG"
log "基于模板: $(basename "$DL/xiaomi-k20pro-boot.img") ($(du -h "$IMG" | cut -f1))"

# ---- 准备要写入的文件 -----------------------------------------------------
STAGE="$WORK/bootstage"
rm -rf "$STAGE"
mkdir -p "$STAGE/loader/entries" "$STAGE/dtbs/qcom"

cp -f "$ROOT/boot/Image" "$STAGE/linux.efi" || die "缺少内核 Image (先跑 03-kernel.sh)"
cp -f "$WORK/initramfs.img" "$STAGE/initramfs" || die "缺少 initramfs (先跑 08-initramfs.sh)"
cp -f "$ROOT/usr/lib/modules/$KV/dtbs/qcom/sm8150-xiaomi-raphael.dtb" "$STAGE/dtbs/qcom/" 2>/dev/null || true

# 修补过的设备树: 内核树自带的 DTB 是残缺的 (sound 节点为空, 无相机节点),
# 实际生效的是 U-Boot 下发的 DT。dtb/raphael-redmi-k20pro.dtb 在它基础上做了:
#   1) 蓝牙节点补 local-bd-address (否则控制器上报全零 BD_ADDR, 蓝牙完全不可用)
#   2) 删掉 slimcap-dai-link 和 slim-playback-dai-link —— 它们引用的 WCD9340
#      codec DAI 常常枚举不出来 (SLIMbus/ADSP 的 QMI 握手有竞态), 一旦缺了就
#      让**整块声卡**卡在 EPROBE_DEFER (aplay -l 一个 card 都没有,
#      PipeWire 只剩"虚拟输出", 完全没声音)。删掉后声卡永远能注册,
#      底部扬声器 (TFA9874/QUAT_MI2S) 稳定可用。
#   3) 删掉 audio-routing —— 之前为修麦克风加的那批 MCLK/MIC BIAS 路由,
#      在这块 codec 上控件不存在, 会让 ASoC 报 "Failed to add route" 并
#      **导致整块声卡注册失败**。路由改由 userspace (UCM/amixer) 负责。
# 原始配置:
#   1) 蓝牙节点缺 local-bd-address -> 控制器上报全零 BD_ADDR ->
#      内核 hci_power_on() 立刻关闭设备且不发 mgmt Index Added -> 蓝牙完全不可用
#   2) 采集路径缺 MCLK 依赖 -> WCD9340 数字核无时钟 -> 录音全零
# dtb/raphael-redmi-k20pro.dtb = 从运行中的设备导出 U-Boot DT 后只加这两处, 其余逐字节一致
DT_LINE=""
if [ -f "$PROJ/dtb/raphael-redmi-k20pro.dtb" ]; then
  cp -f "$PROJ/dtb/raphael-redmi-k20pro.dtb" "$STAGE/dtbs/qcom/raphael-redmi-k20pro.dtb"
  DT_LINE="devicetree /dtbs/qcom/raphael-redmi-k20pro.dtb"
  # 蓝牙地址属于设备唯一标识, 不写进公开仓库 —— 构建时注入:
  #   优先 config/local.conf (已 gitignore), 其次环境变量 RAPHAEL_BT_MAC
  BT_MAC="${RAPHAEL_BT_MAC:-}"
  if [ -z "$BT_MAC" ] && [ -f "$PROJ/config/local.conf" ]; then
    BT_MAC="$(sed -n 's/^BT_MAC="\(.*\)".*/\1/p' "$PROJ/config/local.conf" | head -1)"
  fi
  # 蓝牙地址归一化: 允许 f0:04:e0:78:00:02 / f0-04-e0-78-00-02 / f004e0780002 /
  # "f0 04 e0 78 00 02" 四种写法, 统一成 fdtput 要的 "f0 04 e0 78 00 02"。
  # (CI 上踩过: Secret 里写成带冒号的, fdtput 直接报参数错 -> 镜像没蓝牙)
  BT_MAC_NORM=""
  # 只保留十六进制字符: 冒号 / 连字符 / 空格 / 换行 / 引号 一律丢掉, 于是
  # Secret 里粘成 "f0:04:e0:78:00:02"、'f004e0780002'、末尾带换行 都能用。
  BT_MAC_HEX="$(printf '%s' "$BT_MAC" | tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f')"
  if printf '%s' "$BT_MAC_HEX" | grep -qE '^[0-9a-f]{12}$'; then
    BT_MAC_NORM="$(printf '%s' "$BT_MAC_HEX" | sed 's/../& /g; s/ $//')"
  fi
  if [ -n "$BT_MAC_NORM" ] && command -v fdtput >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    if fdtput -t bx "$STAGE/dtbs/qcom/raphael-redmi-k20pro.dtb" \
         /soc@0/geniqup@cc0000/serial@c8c000/bluetooth local-bd-address $BT_MAC_NORM 2>/dev/null; then
      log "设备树: 使用修补版, 并已注入本机蓝牙地址 ($BT_MAC_NORM)"
    else
      warn "蓝牙地址注入失败 (设备树里没有 bluetooth 节点?)"
    fi
  elif [ -n "$BT_MAC" ]; then
    # 只报长度不报内容 (Secret 可能是敏感值, 也已经被 CI 打码)
    warn "蓝牙地址格式不对: 去掉分隔符后是 ${#BT_MAC_HEX} 位十六进制, 需要正好 12 位 (如 f0:04:e0:78:00:02 或 f004e0780002)$([ ${#BT_MAC_HEX} -gt 12 ] && echo ' —— 值里混进了多余字符' || echo ' —— 位数不够, 可能没填全') -> 该镜像蓝牙不可用"
  else
    warn "未提供蓝牙地址 -> 该镜像蓝牙不可用 (在 config/local.conf 里设 BT_MAC, 或用 RAPHAEL_BT_MAC)"
  fi
else
  warn "缺少 dtb/raphael-redmi-k20pro.dtb -> 蓝牙与麦克风不可用"
fi

# systemd-boot: 用 Arch 自己的版本 (与 rootfs 内 systemd 同版本), 同时保留模板自带版本
SB=""
for c in "$ROOT/usr/lib/systemd/boot/efi/systemd-bootaa64.efi" \
         "$ROOT/usr/lib/systemd/boot/efi/systemd-bootaarch64.efi"; do
  [ -f "$c" ] && { SB="$c"; break; }
done
if [ -n "$SB" ]; then
  cp -f "$SB" "$STAGE/bootaa64.efi"
  log "systemd-boot: $(basename "$SB") ($(du -h "$SB" | cut -f1))"
else
  warn "rootfs 内找不到 systemd-bootaa64.efi, 保留模板自带的引导器"
fi

# ---- root 挂载参数 (必须与 09 生成的镜像布局一致) --------------------------
ROOTFS_LAYOUT="$(rootfs_layout)"
case "$ROOTFS_LAYOUT" in
  btrfs-subvol)
    ROOTFSTYPE=btrfs
    ROOTFLAGS="$(btrfs_opts "$BTRFS_SUBVOL_ROOT")"
    ;;
  btrfs-flat)
    ROOTFSTYPE=btrfs
    ROOTFLAGS="$(btrfs_opts)"
    ;;
  *)
    ROOTFSTYPE=ext4
    ROOTFLAGS=""
    ;;
esac
ROOTOPTS="root=UUID=$UUID rootfstype=$ROOTFSTYPE"
[ -n "$ROOTFLAGS" ] && ROOTOPTS="$ROOTOPTS rootflags=$ROOTFLAGS"
ROOTOPTS="$ROOTOPTS rw rootwait console=tty0"
log "root 参数: $ROOTOPTS"
log "  (布局 $ROOTFS_LAYOUT; initramfs 里 btrfs 无需模块, 内核内建)"

# ---- loader 配置 ----------------------------------------------------------
cat > "$STAGE/loader/loader.conf" <<'EOF'
default  arch.conf
timeout  3
editor   yes
console-mode keep
EOF

cat > "$STAGE/loader/entries/arch.conf" <<EOF
title   Arch Linux ARM (raphael) - Plasma Mobile
linux   /linux.efi
initrd  /initramfs
$DT_LINE
options $ROOTOPTS loglevel=4
EOF

# 兜底条目: 不加载 initramfs, 由内核直接挂载根分区 (UFS/btrfs/ext4 均已内建)
cat > "$STAGE/loader/entries/arch-direct.conf" <<EOF
title   Arch Linux ARM (raphael) - no initramfs (recovery)
linux   /linux.efi
$DT_LINE
options $ROOTOPTS loglevel=7
EOF

# 调试条目: 详细日志 + 单用户救援
cat > "$STAGE/loader/entries/arch-debug.conf" <<EOF
title   Arch Linux ARM (raphael) - debug shell
linux   /linux.efi
initrd  /initramfs
$DT_LINE
options $ROOTOPTS loglevel=7 systemd.log_level=debug
EOF

# 保留上游 Debian 条目会让菜单里出现一个必然失败的选项, 删掉
# (模板里叫 ubuntu.conf)

# ---- 写入 FAT 镜像 --------------------------------------------------------
log "写入 FAT 镜像"
mtools_mkdir "$IMG" "::/loader"
mtools_mkdir "$IMG" "::/loader/entries"
mtools_mkdir "$IMG" "::/dtbs"
mtools_mkdir "$IMG" "::/dtbs/qcom"

mtools_del "$IMG" "::/loader/entries/ubuntu.conf"

# 先把模板自带的厂商引导器取出来备份, 再覆盖它
mkdir -p "$WORK/vendor-efi"
if 7z x -y -o"$WORK/vendor-efi" "$DL/xiaomi-k20pro-boot.img" "efi/boot/bootaa64.efi" >/dev/null 2>&1 \
   && [ -f "$WORK/vendor-efi/efi/boot/bootaa64.efi" ]; then
  mtools_copy "$IMG" "$WORK/vendor-efi/efi/boot/bootaa64.efi" "::/efi/boot/bootaa64-vendor.efi"
  log "已备份模板引导器为 /efi/boot/bootaa64-vendor.efi"
else
  warn "未能抽取模板自带引导器用于备份 (不影响构建)"
fi

mtools_copy "$IMG" "$STAGE/linux.efi"                        "::/linux.efi"
mtools_copy "$IMG" "$STAGE/initramfs"                        "::/initramfs"
mtools_copy "$IMG" "$STAGE/loader/loader.conf"               "::/loader/loader.conf"
mtools_copy "$IMG" "$STAGE/loader/entries/arch.conf"         "::/loader/entries/arch.conf"
mtools_copy "$IMG" "$STAGE/loader/entries/arch-direct.conf"  "::/loader/entries/arch-direct.conf"
mtools_copy "$IMG" "$STAGE/loader/entries/arch-debug.conf"   "::/loader/entries/arch-debug.conf"
[ -f "$STAGE/dtbs/qcom/sm8150-xiaomi-raphael.dtb" ] && \
  mtools_copy "$IMG" "$STAGE/dtbs/qcom/sm8150-xiaomi-raphael.dtb" "::/dtbs/qcom/sm8150-xiaomi-raphael.dtb"
[ -f "$STAGE/dtbs/qcom/raphael-redmi-k20pro.dtb" ] && \
  mtools_copy "$IMG" "$STAGE/dtbs/qcom/raphael-redmi-k20pro.dtb" "::/dtbs/qcom/raphael-redmi-k20pro.dtb"
[ -n "$SB" ] && mtools_copy "$IMG" "$STAGE/bootaa64.efi" "::/efi/boot/bootaa64.efi"

log "镜像内容:"
mtools_list "$IMG" "::/" | sed 's/^/    /'

# ---- 校验 -----------------------------------------------------------------
SIZE=$(stat -c %s "$IMG")
log "boot-cache.img: $((SIZE/1024/1024)) MiB (cache 分区需 ≥ ${BOOTFAT_SIZE_MB}MiB)"
[ "$SIZE" -eq $((BOOTFAT_SIZE_MB*1024*1024)) ] || warn "镜像大小与模板不一致, 请确认 cache 分区足够大"

log "cache 引导镜像完成: $IMG"
