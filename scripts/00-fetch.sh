#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 00 — 下载所有上游产物
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

confirm_stage "00 下载依赖"

# Arch Linux ARM aarch64 通用 rootfs
fetch "$ALARM_ROOTFS_URL" "$DL/ArchLinuxARM-aarch64-latest.tar.gz"

# 作者预编译内核 (Debian 包, 里面是 vmlinuz/模块/dtb)
for f in linux-image-xiaomi-raphael.deb linux-headers-xiaomi-raphael.deb \
         firmware-xiaomi-raphael.deb alsa-xiaomi-raphael.deb; do
  fetch "$KERNEL_DEB_BASE/$f" "$DL/$f"
done

# cache 分区 FAT32 模板 (内含 systemd-boot), rootfs 用不到但作为模板
fetch "$BOOT_IMG_URL" "$DL/xiaomi-k20pro-boot.img"

# u-boot 引导镜像 (刷入 boot 分区)
# ★ 这里必须**解压**: 上游发的是一个 zip (里面就一个 u-boot.img), 而 11-flash.sh
#   要 work/uboot/u-boot.img、99-make-release.sh 也要把它打进发布包。
#   踩过的坑: 原来只下载不解压, 本地因为早先手动解过一次所以一直没暴露, 到了 CI
#   (全新环境) 就变成: 发布包只有 boot-cache + rootfs **两个**文件, 而 刷机说明.txt
#   里还写着让人 fastboot flash boot u-boot.img —— 用户照着做会卡住。
fetch "$UBOOT_RELEASE_URL/$UBOOT_IMG_ZIP" "$DL/$UBOOT_IMG_ZIP"
if [ -s "$WORK/uboot/u-boot.img" ]; then
  log "u-boot.img 已存在, 跳过解压"
else
  command -v unzip >/dev/null 2>&1 || die "缺少 unzip (解压 U-Boot 包需要)"
  mkdir -p "$WORK/uboot"
  unzip -o -j "$DL/$UBOOT_IMG_ZIP" 'u-boot.img' -d "$WORK/uboot" >/dev/null \
    || die "从 $UBOOT_IMG_ZIP 里解不出 u-boot.img"
  [ -s "$WORK/uboot/u-boot.img" ] || die "解压后没找到 work/uboot/u-boot.img"
  log "已解压: work/uboot/u-boot.img ($(du -h "$WORK/uboot/u-boot.img" | cut -f1))"
fi

# 宿主 mtools (读写 FAT 镜像)
setup_mtools

log "全部依赖就绪:"
ls -lh "$DL" | sed 's/^/    /'
