#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 09 — 生成 rootfs 磁盘镜像 (ext4)
#  关键点:
#   * 在 user namespace 内执行 mke2fs -d, 这样镜像里的文件属主是 uid 0
#     (namespace 内所有文件都映射为 root)
#   * 镜像大小 8G, 首启动由 fstab 的 x-systemd.growfs 扩容到 userdata 实际大小
#   * 同时产出 fastboot 用的 sparse 镜像 (体积/时间都小很多)
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount

confirm_stage "09 生成 rootfs.img"
UUID="$(rootfs_uuid)"
IMG="$OUT/rootfs.img"

# ---- 清理构建残留 ---------------------------------------------------------
log "清理构建残留"
rm -rf "$ROOT/.raphael-build"
rm -rf "$ROOT/var/cache/pacman/pkg"/* 2>/dev/null || true
# 注意: 不要删 /etc/resolv.conf —— 06-config.sh 已写入兜底 DNS, 且 NM 配了
# rc-manager=file 会自行接管。这里只保证它存在且是普通文件 (不是 resolved 桩软链)。
# 始终写成兜底 DNS: 构建过程中 ns_mount 会把宿主机的 resolv.conf 拷进来
# (tailscale 之类的地址带进镜像就错了), 联网后 NetworkManager (rc-manager=file) 会重写。
rm -f "$ROOT/etc/resolv.conf"
printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > "$ROOT/etc/resolv.conf"
chmod 644 "$ROOT/etc/resolv.conf"
rm -rf "$ROOT/tmp"/* "$ROOT/var/tmp"/* 2>/dev/null || true
rm -f "$ROOT/etc/machine-id" 2>/dev/null || true
echo "uninitialized" > "$ROOT/etc/machine-id"
# 挂载点保持空目录 (设备上由 systemd 挂载)
for d in proc sys dev run tmp; do mkdir -p "$ROOT/$d"; done
# 不把宿主的 DNS/ssh key 带进镜像
rm -f "$ROOT"/etc/ssh/ssh_host_* 2>/dev/null || true

log "rootfs 内容: $(du -sh "$ROOT" | cut -f1), $(find "$ROOT" | wc -l) 个条目"

# ---- 生成镜像 -------------------------------------------------------------
rm -f "$IMG" "$OUT/rootfs.sparse.img"
log "mke2fs -d ($IMAGE_SIZE) ..."
mke2fs -q -t ext4 -F -L userdata -U "$UUID" \
       -m 1 -E lazy_itable_init=1,lazy_journal_init=1 \
       -d "$ROOT" "$IMG" "$IMAGE_SIZE"

log "校验文件系统"
e2fsck -f -y "$IMG" >/dev/null 2>&1 || true
log "镜像信息:"
dumpe2fs -h "$IMG" 2>/dev/null | grep -E 'Filesystem UUID|Block count|Block size|Filesystem features|Free blocks' | sed 's/^/    /'
log "已用: $(du -h --apparent-size "$IMG" | cut -f1) 实际占用: $(du -h "$IMG" | cut -f1)"

# ---- sparse 镜像 ----------------------------------------------------------
if command -v img2simg >/dev/null; then
  log "生成 sparse 镜像 (fastboot 刷写更快)"
  img2simg "$IMG" "$OUT/rootfs.sparse.img" 4096
  ls -lh "$OUT/rootfs.sparse.img" | awk '{print "    rootfs.sparse.img:", $5}'
fi

echo "$UUID" > "$WORK/rootfs.uuid"
log "rootfs 镜像完成: $IMG (UUID=$UUID)"
