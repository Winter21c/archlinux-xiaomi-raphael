#!/bin/bash
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
fetch "$UBOOT_RELEASE_URL/$UBOOT_IMG_ZIP" "$DL/$UBOOT_IMG_ZIP"

# 宿主 mtools (读写 FAT 镜像)
setup_mtools

log "全部依赖就绪:"
ls -lh "$DL" | sed 's/^/    /'
