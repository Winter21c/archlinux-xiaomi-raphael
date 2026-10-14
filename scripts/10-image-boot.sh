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

# 设备树: 直接用内核作者 deb 里那份 (kernel-deb 的 qcom/sm8150-xiaomi-raphael.dtb),
# 它已经包含 5 条 DAI 链路 (mm1/mm2/speaker/slimcap/slim-playback) 和 audio-routing。
# 真机实测 (2026-10-15):
#   * 与本项目原先那份"从 U-Boot 导出"的 DTB 相比只有 46 行差异, 其中
#     panel/dsi/touchscreen/backlight/mdss **0 差异** -> 显示配置一致, 无风险;
#     其余差异是 U-Boot 自带的 serial-number/uefi-mmap/bootargs/内存 reg 等,
#     内核走 EFI 时内存由固件提供, 实测多次启动正常。
#   * 从前这份 DTB 是残缺的(sound 节点为空), 所以本项目才自带了一份把 slim 链路
#     **删掉**的版本; 那是为了绕开"codec 枚举太慢导致整块声卡卡在 EPROBE_DEFER"。
#     现在那个竞态由 raphael-audio-init.sh 解决(见 06-config.sh: blacklist
#     snd_soc_sm8150 + 等 codec 就绪再加载), 于是 slim 链路可以保留 ——
#     保留后 codec 才会进声卡, 耳机的 HPHL/HPHR 通路才可用。
#   * 唯一仍不通的是麦克风: slimcap 链路在, 但 codec 的 SLIMbus 上行(TX)超时,
#     arecord 打不开或录到全零 (见 notes/microphone-and-kernel-plan.md)。
# 构建时仍然只注入蓝牙地址 (设备唯一值, 不进公开仓库)。
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
  # 蓝牙地址归一化: 允许 11:22:33:44:55:66 / 11-22-33-44-55-66 / 112233445566 /
  # "11 22 33 44 55 66" 四种写法, 统一成 fdtput 要的 "11 22 33 44 55 66"。
  # (CI 上踩过: Secret 里写成带冒号的, fdtput 直接报参数错 -> 镜像没蓝牙)
  BT_MAC_NORM="$(normalize_bt_mac "$BT_MAC" 2>/dev/null || true)"
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
    warn "蓝牙地址格式不对: 去掉分隔符后是 ${#BT_MAC_HEX} 位十六进制, 需要正好 12 位 (如 11:22:33:44:55:66 或 112233445566)$([ ${#BT_MAC_HEX} -gt 12 ] && echo ' —— 值里混进了多余字符' || echo ' —— 位数不够, 可能没填全') -> 该镜像蓝牙不可用"
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
# 无线管制域: 不设的话是"世界域", 很多 5GHz 信道被禁用 (连不上 5G Wi-Fi)
[ -n "${WIFI_COUNTRY:-}" ] && ROOTOPTS="$ROOTOPTS cfg80211.ieee80211_regdom=$WIFI_COUNTRY"
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
title   Arch Linux ARM (raphael) - $DE_SUMMARY
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
