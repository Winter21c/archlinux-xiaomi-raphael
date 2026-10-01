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

# ---- 卸载构建期的挂载点 ---------------------------------------------------
# ns_mount 把 /proc 与 /dev/* 挂进了 $ROOT; 不先卸载的话 mke2fs -d / mkfs.btrfs -r
# 会把**宿主机的 proc/dev 内容**整份拷进镜像 (体积膨胀 + 泄露宿主信息)。
# 镜像里只需要空的 /proc /sys /dev 目录, 启动时由 systemd 挂载。
log "卸载构建期挂载点 (proc/sys/dev)"
for m in "$ROOT/proc" "$ROOT/sys" "$ROOT/dev/pts" "$ROOT/dev/shm" "$ROOT/dev"; do
  mountpoint -q "$m" 2>/dev/null && umount -R "$m" 2>/dev/null || true
done
for f in "$ROOT"/dev/*; do
  mountpoint -q "$f" 2>/dev/null && umount "$f" 2>/dev/null || true
done
for d in proc sys dev dev/pts dev/shm run tmp; do mkdir -p "$ROOT/$d"; done
chmod 1777 "$ROOT/tmp" "$ROOT/var/tmp" 2>/dev/null || true

# ---- 属主归一化 -----------------------------------------------------------
# cp -a 会原样搬走"树里是什么属主"; 如果树是 userns 构建留下的 (uid 1000),
# 镜像里 /usr/bin/mount 就变成 setuid-1000 -> root 跑它 euid=1000 ->
# 开机后所有 mount 失败 (remount-fs/boot.mount/tmp.mount/configfs/usb-ncm/sshd)。
# 所以必须在灌数据之前把树修回 root:root。真 root 才做得成, 否则报错。
normalize_ownership || warn "跳过属主归一化 (非真 root): 这份镜像的 setuid 程序会失效!"

LAYOUT="$(rootfs_layout)"
log "根文件系统布局: $LAYOUT (ROOTFS_TYPE=$ROOTFS_TYPE)"

case "$LAYOUT" in
  btrfs-subvol|btrfs-flat)
    if [ "$LAYOUT" = "btrfs-subvol" ]; then
      # 有 root: 空文件系统 -> 带 compress 挂载 -> 建 @ / @home -> cp -a 灌数据
      # (只有这样写入的数据才会被 zstd 压缩; mkfs -r 是直接写块, 不压缩)
      log "创建空 btrfs 并带压缩挂载 (compress=$BTRFS_COMPRESS)"
      rm -f "$IMG"; truncate -s "$IMAGE_SIZE" "$IMG"
      mkfs.btrfs -q -f -L userdata -U "$UUID" "$IMG"
      MNT="$WORK/btrfs-mnt"
      rm -rf "$MNT"; mkdir -p "$MNT"
      if mount -o "loop,compress=$BTRFS_COMPRESS" "$IMG" "$MNT" 2>/dev/null; then
        btrfs subvolume create "$MNT/$BTRFS_SUBVOL_ROOT" >/dev/null
        btrfs subvolume create "$MNT/$BTRFS_SUBVOL_HOME" >/dev/null
        log "  复制 rootfs -> /$BTRFS_SUBVOL_ROOT (压缩写入, 需要几分钟)"
        cp -a "$ROOT/." "$MNT/$BTRFS_SUBVOL_ROOT/"
        mkdir -p "$MNT/$BTRFS_SUBVOL_HOME"
        # /home 的数据在 @ 和 @home 里各留一份:
        # 挂上 @home 时用 @home; 万一挂载失败, @/home 里的同一份数据照样能用 (不会出现空家目录)
        if [ -d "$MNT/$BTRFS_SUBVOL_ROOT/home" ]; then
          cp -a "$MNT/$BTRFS_SUBVOL_ROOT/home/." "$MNT/$BTRFS_SUBVOL_HOME/" 2>/dev/null || true
        fi
        mkdir -p "$MNT/$BTRFS_SUBVOL_ROOT/home" "$MNT/$BTRFS_SUBVOL_HOME"
        sync
        # 默认子卷设为 @: 即使引导参数丢了也能起来
        SVID="$(btrfs subvolume list "$MNT" 2>/dev/null | awk -v n="$BTRFS_SUBVOL_ROOT" '$NF==n{print $2}')"
        [ -n "$SVID" ] && btrfs subvolume set-default "$SVID" "$MNT" 2>/dev/null || true
        log "  压缩情况: $(btrfs filesystem usage -b "$MNT" 2>/dev/null | awk '/Free \\(estimated\\)|Used:/{print $0}' | head -2 | tr '\n' ' ')"
        umount "$MNT"
        log "  子卷完成: /$BTRFS_SUBVOL_ROOT (默认子卷) + /$BTRFS_SUBVOL_HOME (/home)"
      else
        warn "loop 挂载失败 (容器缺 /dev/loop*?) -> 回退单子卷布局"
        LAYOUT="btrfs-flat"; echo "$LAYOUT" > "$WORK/rootfs-layout"
        rm -f "$IMG"; truncate -s "$IMAGE_SIZE" "$IMG"
        mkfs.btrfs -q -f -L userdata -U "$UUID" -r "$ROOT" "$IMG"
      fi
      rmdir "$MNT" 2>/dev/null || true
    else
      log "mkfs.btrfs -r ($IMAGE_SIZE): 单子卷布局 (数据在顶层)"
      truncate -s "$IMAGE_SIZE" "$IMG"
      mkfs.btrfs -q -f -L userdata -U "$UUID" -r "$ROOT" "$IMG"
      log "  注: mkfs -r 直接写块不走压缩; 压缩对系统运行后的写入生效"
    fi

    log "校验 btrfs 文件系统"
    btrfs check --readonly "$IMG" 2>&1 | tail -4 | sed 's/^/    /' || true
    log "镜像信息:"
    btrfs inspect-internal dump-super "$IMG" 2>/dev/null \
      | grep -E 'fsid|total_bytes|bytes_used|sectorsize|label' | sed 's/^/    /' || true
    ;;
  *)
    log "mke2fs -d ($IMAGE_SIZE) ..."
    mke2fs -q -t ext4 -F -L userdata -U "$UUID" \
           -m 1 -E lazy_itable_init=1,lazy_journal_init=1 \
           -d "$ROOT" "$IMG" "$IMAGE_SIZE"
    log "校验文件系统"
    e2fsck -f -y "$IMG" >/dev/null 2>&1 || true
    log "镜像信息:"
    dumpe2fs -h "$IMG" 2>/dev/null | grep -E 'Filesystem UUID|Block count|Block size|Filesystem features|Free blocks' | sed 's/^/    /'
    ;;
esac

log "已用: $(du -h --apparent-size "$IMG" | cut -f1) 实际占用: $(du -h "$IMG" | cut -f1)"

# ---- sparse 镜像 ----------------------------------------------------------
if command -v img2simg >/dev/null; then
  log "生成 sparse 镜像 (fastboot 刷写更快)"
  img2simg "$IMG" "$OUT/rootfs.sparse.img" 4096
  ls -lh "$OUT/rootfs.sparse.img" | awk '{print "    rootfs.sparse.img:", $5}'
fi

echo "$UUID" > "$WORK/rootfs.uuid"
echo "$LAYOUT" > "$WORK/rootfs-layout"
log "rootfs 镜像完成: $IMG (UUID=$UUID, 布局=$LAYOUT)"
