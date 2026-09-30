#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 11 — 刷机 (需要手机进入 fastboot / TWRP, 会清空数据)
#
#  用法:
#     ./scripts/11-flash.sh --backup   # 可选: 用 TWRP 备份 boot/dtbo 分区
#     ./scripts/11-flash.sh --flash    # 刷入 U-Boot + 引导 + Arch rootfs
#     ./scripts/11-flash.sh --dry-run  # 只打印命令, 不动手机
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODE=""
DRY=0
for a in "$@"; do
  case "$a" in
    --backup) MODE=backup ;;
    --flash)  MODE=flash ;;
    --dry-run) DRY=1 ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) die "未知参数: $a" ;;
  esac
done
[ -n "$MODE" ] || { sed -n '2,12p' "$0"; exit 1; }

UBOOT_IMG="$WORK/uboot/u-boot.img"
ROOTFS_IMG="$OUT/rootfs.sparse.img"
[ -s "$ROOTFS_IMG" ] || ROOTFS_IMG="$OUT/rootfs.img"
BOOT_IMG="$OUT/boot-cache.img"

run() {
  if [ "$DRY" = "1" ]; then echo "  [dry-run] $*"; else echo "  $ $*"; "$@"; fi
}

if [ "$MODE" = "backup" ]; then
  echo "=== 备份 boot / dtbo / cache 分区 (需要 TWRP) ==="
  TWRP="$DL/twrp-3.7.1_12-1-raphael.img"
  if [ ! -s "$TWRP" ]; then
    echo "缺少 TWRP 镜像: $TWRP"
    echo "可从上游一键安装包获取, 或直接跳过备份 (Android 可用 fastboot 线刷包恢复)"
    exit 1
  fi
  mkdir -p "$OUT/backup"
  echo "1) 手机进入 fastboot: 关机后按住 音量- + 电源键"
  read -rp "   准备好后按回车继续..." _
  run fastboot devices
  echo "2) 临时启动 TWRP (不写入手机)"
  run fastboot boot "$TWRP"
  echo "3) 等待 TWRP 启动后备份分区"
  sleep 20
  for p in boot dtbo cache; do
    run adb shell "dd if=/dev/block/bootdevice/by-name/$p of=/tmp/$p.img bs=1M"
    run adb pull "/tmp/$p.img" "$OUT/backup/$p.img"
  done
  echo "备份完成 -> $OUT/backup/"
  exit 0
fi

echo "=============================================================="
echo "  刷入 Arch Linux ARM 到 Redmi K20 Pro"
echo "=============================================================="
echo "  ⚠ 以下操作会清空 userdata 分区 (Android 系统与数据全部丢失)"
echo "  ⚠ 请确认 bootloader 已解锁"
echo
echo "  将被写入:"
echo "    boot      <- $UBOOT_IMG (U-Boot)"
echo "    cache     <- $BOOT_IMG (FAT32: systemd-boot + 内核 + initramfs)"
echo "    userdata  <- $ROOTFS_IMG (Arch rootfs)"
echo "    dtbo      <- 擦除"
echo
read -rp "确认继续? 输入 yes: " ok
[ "$ok" = "yes" ] || { echo "已取消"; exit 1; }

for f in "$UBOOT_IMG" "$ROOTFS_IMG" "$BOOT_IMG"; do
  [ -s "$f" ] || die "缺少产物: $f (先跑 build.sh)"
done

run fastboot devices
echo ">>> 擦除分区"
run fastboot erase dtbo
run fastboot erase boot
run fastboot erase cache
run fastboot erase userdata
echo ">>> 刷入"
run fastboot flash boot "$UBOOT_IMG"
run fastboot flash cache "$BOOT_IMG"
run fastboot flash userdata "$ROOTFS_IMG"
echo ">>> 重启"
run fastboot reboot

echo
echo "设备应该会在几秒后显示 U-Boot 启动菜单, 然后进入 Plasma Mobile。"
echo "首次启动会自动扩容根分区并初始化 pacman 密钥环, 可能多花 1-2 分钟。"
echo
echo "排障:"
echo "  * 黑屏无反应 -> 长按电源键 10 秒强制重启; 检查 cache 分区是否刷入成功"
echo "  * 卡在 systemd-boot -> 在 U-Boot 菜单里选 arch-direct.conf (不用 initramfs)"
echo "  * 想回 Android -> fastboot flash boot <备份的boot.img> 并用线刷包恢复"
