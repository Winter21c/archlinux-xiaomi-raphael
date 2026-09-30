#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 03 — 安装 raphael 定制内核 (作者预编译) + 设备树
#  源: GengWei1997/kernel-deb 的 linux-image/headers deb
#  目标布局 (Arch 约定):
#     /usr/lib/modules/<kver>/            内核模块
#     /boot/vmlinuz-<kver>                内核 Image (EFI stub) 暂存, 最终进 FAT
#     /usr/lib/modules/<kver>/dtbs/qcom/  设备树副本 (rootfs 内)
#     (FAT 分区的装载见阶段 10)
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount

confirm_stage "03 安装定制内核 $KERNEL_VERSION"

TMP="$WORK/deb"
rm -rf "$TMP" && mkdir -p "$TMP"/{image,headers}

unpack_deb() {  # unpack_deb <deb> <destdir>
  local deb="$1" dest="$2"
  ( cd "$dest" && ar x "$deb" && tar --zstd -xf data.tar.zst && rm -f data.tar.zst control.tar.zst debian-binary )
}

log "解包 linux-image deb"
unpack_deb "$DL/linux-image-xiaomi-raphael.deb" "$TMP/image"
log "解包 linux-headers deb"
unpack_deb "$DL/linux-headers-xiaomi-raphael.deb" "$TMP/headers"

KV="$(ls "$TMP/image/lib/modules" | head -1)"
[ -n "$KV" ] || die "找不到内核模块目录"
log "内核版本: $KV"

# ---- 模块 -----------------------------------------------------------------
rm -rf "$ROOT/usr/lib/modules/$KV"
mkdir -p "$ROOT/usr/lib/modules"
cp -a "$TMP/image/lib/modules/$KV" "$ROOT/usr/lib/modules/"
# Debian 把 modules.*.bin 里的路径写成 /lib/modules, Arch 上 /lib -> usr/lib 软链
# 保证该软链存在 (ALARM 默认就有)
[ -e "$ROOT/lib" ] || ln -s usr/lib "$ROOT/lib"

# ---- 内核 Image -----------------------------------------------------------
VMLINUZ="$(ls "$TMP/image/boot"/vmlinuz-* 2>/dev/null | head -1)"
[ -n "$VMLINUZ" ] || die "deb 内找不到 vmlinuz"
mkdir -p "$ROOT/boot"
cp -f "$VMLINUZ" "$ROOT/boot/Image"
cp -f "$VMLINUZ" "$ROOT/boot/vmlinuz-$KV"
cp -f "$TMP/image/boot/config-$KV" "$ROOT/boot/config-$KV" 2>/dev/null || true
cp -f "$TMP/image/boot/System.map-$KV" "$ROOT/boot/System.map-$KV" 2>/dev/null || true

# ---- 设备树 ---------------------------------------------------------------
mkdir -p "$ROOT/usr/lib/modules/$KV/dtbs/qcom"
if [ -d "$TMP/image/boot/dtbs/qcom" ]; then
  cp -f "$TMP/image/boot/dtbs/qcom"/*.dtb "$ROOT/usr/lib/modules/$KV/dtbs/qcom/" 2>/dev/null || true
fi
raph_dtb="$ROOT/usr/lib/modules/$KV/dtbs/qcom/sm8150-xiaomi-raphael.dtb"
[ -f "$raph_dtb" ] || die "缺少 sm8150-xiaomi-raphael.dtb"
log "设备树: $(ls "$ROOT/usr/lib/modules/$KV/dtbs/qcom" | wc -l) 个 dtb (含 raphael)"

# ---- 头文件 (供用户后续自行编译模块) --------------------------------------
if [ -d "$TMP/headers/usr/src" ]; then
  mkdir -p "$ROOT/usr/src"
  cp -a "$TMP/headers/usr/src/." "$ROOT/usr/src/"
  # Arch 上内核头文件约定在 /usr/lib/modules/<kver>/build
  if [ -d "$ROOT/usr/src/linux-headers-$KV" ] && [ ! -e "$ROOT/usr/lib/modules/$KV/build" ]; then
    ln -sfn "/usr/src/linux-headers-$KV" "$ROOT/usr/lib/modules/$KV/build"
  fi
fi

# ---- 依赖关系 (用宿主 depmod, 与架构无关) ---------------------------------
if command -v depmod >/dev/null; then
  log "重建 modules.dep"
  depmod -b "$ROOT" -a "$KV" 2>/dev/null || warn "depmod 失败 (沿用 deb 内自带的 modules.dep)"
fi

echo "$KV" > "$WORK/kver"
log "内核安装完成: $KV"
log "  模块数: $(find "$ROOT/usr/lib/modules/$KV" -name '*.ko*' | wc -l)"
log "  Image : $(du -h "$ROOT/boot/Image" | cut -f1)"
