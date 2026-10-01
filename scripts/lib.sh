#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  公共函数库 — 所有阶段脚本共用
#  设计约束: 本机没有 root 权限, 因此全部构建在 user namespace 内以 "假 root"
#  身份完成; aarch64 二进制通过 qemu-user 显式调用执行 (不依赖 binfmt_misc)。
# ============================================================================
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$PROJ/config/build.conf"

WORK="$PROJ/work"
ROOT="$WORK/root"                      # 目标 rootfs 目录树
DL="$PROJ/dl"                          # 下载缓存
OUT="$PROJ/out"                        # 产物
LOGS="$PROJ/logs"
TOOLS="$PROJ/tools"                    # 从 Arch x86_64 仓库取来的宿主工具 (mtools)
STAGE_DIR="$WORK/bootfat"              # cache 分区 FAT 内容暂存
QDIR_IN_ROOT="/.raphael-build"         # rootfs 内的 qemu 宿主垫片目录 (相对路径)
QDIR="$ROOT$QDIR_IN_ROOT"

mkdir -p "$WORK" "$DL" "$OUT" "$LOGS" "$TOOLS" "$WORK/logs" "$WORK/empty-hooks"

# ---------------------------------------------------------------- 日志 ------
log()  { printf '\033[1;32m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] ERROR:\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# ------------------------------------------------- 下载 (断点续传 + 重试) ----
fetch() {  # fetch <url> <dest>
  local url="$1" dest="$2"
  [ -s "$dest" ] && { log "已缓存: $(basename "$dest") ($(du -h "$dest" | cut -f1))"; return 0; }
  log "下载: $url"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -C - -o "$dest.part" "$url" \
    || die "下载失败: $url"
  mv "$dest.part" "$dest"
}

# ------------------------------------------- user namespace 自举 ------------
# 用法: 在每个阶段脚本开头 require_ns
require_ns() {
  if [ "${RAPHAEL_NS:-0}" != "1" ]; then
    log "进入 user namespace (无 root 构建模式)"
    mkdir -p "$ROOT/proc"
    exec unshare -r -m -p -f --mount-proc="$ROOT/proc" --propagation private \
      env RAPHAEL_NS=1 PROJ="$PROJ" bash "$0" "$@"
  fi
}

# 在 namespace 内准备 chroot 环境。
# 注意: 宿主 systemd 会把 /proc /sys /dev 标记为 locked mount, 非特权 userns
# 无法 bind 这些挂载点, 因此 /proc 由 unshare --mount-proc 提供, /dev 中的
# 设备节点逐个 bind (单文件 bind 不受 locked 限制)。
ns_mount() {
  [ -d "$ROOT" ] || die "rootfs 不存在: $ROOT"
  mkdir -p "$ROOT"/{proc,sys,dev,dev/pts,tmp,run}
  mountpoint -q "$ROOT" || mount --bind "$ROOT" "$ROOT"
  mountpoint -q "$ROOT/proc" || warn "/proc 未挂载, 请确认通过 unshare --mount-proc 启动"
  ns_dev_mount
  cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf" 2>/dev/null || true
}

ns_dev_mount() {
  local d
  for d in null zero full random urandom tty; do
    [ -e "/dev/$d" ] || continue
    [ -e "$ROOT/dev/$d" ] || : > "$ROOT/dev/$d" 2>/dev/null || continue
    mountpoint -q "$ROOT/dev/$d" 2>/dev/null && continue
    mount --bind "/dev/$d" "$ROOT/dev/$d" 2>/dev/null || true
  done
}

ns_umount() {
  local d
  for d in null zero full random urandom tty; do
    mountpoint -q "$ROOT/dev/$d" 2>/dev/null && umount -l "$ROOT/dev/$d" 2>/dev/null || true
  done
  mountpoint -q "$ROOT" && umount -l "$ROOT" 2>/dev/null || true
}

# ------------------------------------------------- qemu 宿主垫片 ------------
# 把 x86_64 的 qemu-aarch64 及其依赖放进 rootfs, 使得 chroot 内可以显式执行
# aarch64 程序。注意: 只能直接 exec ELF (动态加载器), 不能依赖 shell 脚本,
# 因为 chroot 内的 /bin/sh 是 aarch64, 没有 binfmt_misc 无法被执行。
setup_qemu_shim() {
  [ -x "$QDIR/qemu-aarch64" ] && [ -x "$QDIR/ld-linux-x86-64.so.2" ] && return 0
  log "安装 qemu 宿主垫片 -> $QDIR"
  mkdir -p "$QDIR/lib"
  cp -f /usr/bin/qemu-aarch64 "$QDIR/qemu-aarch64"
  local ld
  ld="$(ldd /usr/bin/qemu-aarch64 | awk '/ld-linux-x86-64/{print $3; exit}')"
  [ -n "$ld" ] || die "找不到 x86_64 动态加载器"
  cp -fL "$ld" "$QDIR/ld-linux-x86-64.so.2"
  ldd /usr/bin/qemu-aarch64 | awk '{print $3}' | grep -E '^/' | sort -u | while read -r l; do
    cp -fL "$l" "$QDIR/lib/" 2>/dev/null || true
  done
  chmod -R a+rX "$QDIR"
}

# 在 chroot 内执行一个 aarch64 程序: gq /usr/bin/ldconfig [-args]
gq() {
  # 垫片可能被阶段 01 的 rootfs 清理删掉, 这里按需重建
  # (setup_qemu_shim 自带存在性检查, 正常路径下只是一次 [ -x ] 判断)
  # 注意重定向到 stderr: gq 常被 $(...) 捕获输出, 安装日志不能混进返回值
  setup_qemu_shim >&2
  chroot "$ROOT" "$QDIR_IN_ROOT/ld-linux-x86-64.so.2" \
    --library-path "$QDIR_IN_ROOT/lib" "$QDIR_IN_ROOT/qemu-aarch64" "$@"
}

# 校验 rootfs 内 aarch64 工具链可用
verify_qemu() {
  local out
  out="$(gq /usr/bin/uname -m 2>&1)" || die "qemu 垫片不可用: $out"
  [ "$out" = "aarch64" ] || warn "uname 返回 '$out' (期望 aarch64)"
  log "qemu 垫片自检通过: uname -m = $out"
}

# ------------------------------------------- 宿主工具 (mtools) --------------
# mtools 用于在无 root 情况下读写 FAT 镜像 (cache 分区)
setup_mtools() {
  [ -x "$TOOLS/mtools/usr/bin/mcopy" ] && return 0
  log "获取宿主 mtools (x86_64)"
  local url fn base
  base="https://geo.mirror.pkgbuild.com/extra/os/x86_64"
  fn="$(curl -sSL --max-time 30 "$base/" | grep -oE 'mtools-[0-9][^"]*x86_64\.pkg\.tar\.zst' | head -1)"
  [ -n "$fn" ] || die "无法从镜像列出 mtools 包"
  url="$base/$fn"
  fetch "$url" "$DL/$fn"
  rm -rf "$TOOLS/mtools" && mkdir -p "$TOOLS/mtools"
  tar --zstd -xf "$DL/$fn" -C "$TOOLS/mtools"
  [ -x "$TOOLS/mtools/usr/bin/mcopy" ] || die "mtools 解包失败"
  log "mtools: $("$TOOLS/mtools/usr/bin/mcopy" --version 2>&1 | head -1)"
}

# mtools 包装: 读写 FAT 镜像
mrun() { MTOOLS_SKIP_CHECK=1 MTOOLSRC=/dev/null "$TOOLS/mtools/usr/bin/$@" ; }

mtools_copy() {  # mtools_copy <img> <src> <dst-in-image>
  mrun mcopy -o -i "$1" "$2" "$3"
}
mtools_mkdir() { mrun mmd -i "$1" "$2" 2>/dev/null || true; }
mtools_del()   { mrun mdel -i "$1" "$2" 2>/dev/null || true; }
mtools_list()  { mrun mdir -i "$1" "$2" 2>&1 || true; }

# ------------------------------------------------- 杂项 --------------------
# 读取/生成 rootfs 的 ext4 UUID
rootfs_uuid() {
  if [ -s "$PROJ/$ROOTFS_UUID_FILE" ]; then
    cat "$PROJ/$ROOTFS_UUID_FILE"
  else
    mkdir -p "$(dirname "$PROJ/$ROOTFS_UUID_FILE")"
    python3 -c 'import uuid;print(uuid.uuid4())' > "$PROJ/$ROOTFS_UUID_FILE"
    cat "$PROJ/$ROOTFS_UUID_FILE"
  fi
}

KVER="$(ls "$ROOT/usr/lib/modules" 2>/dev/null | grep -E '^7\.' | head -1 || true)"


# ---------------------------------------- systemd 单元启停 ------------------
# 在 chroot 内用 qemu 跑 systemctl --root=/ (离线模式, 不需要 dbus)
enable_unit() {
  local u="$1"
  if gq /usr/bin/systemctl --root=/ enable "$u" >/dev/null 2>&1; then
    log "  enable: $u"
    return 0
  fi
  local wants="multi-user.target" f
  f="$(grep -rl "^WantedBy=" "$ROOT/usr/lib/systemd/system/$u" "$ROOT/etc/systemd/system/$u" 2>/dev/null | head -1)"
  [ -n "$f" ] && wants="$(sed -n 's/^WantedBy=//p' "$f" | tr -d ' ' | cut -d' ' -f1)"
  mkdir -p "$ROOT/etc/systemd/system/$wants.wants"
  ln -sfn "/usr/lib/systemd/system/$u" "$ROOT/etc/systemd/system/$wants.wants/$u"
  log "  enable (手工软链): $u -> $wants.wants"
}
mask_unit() {
  local u="$1"
  if gq /usr/bin/systemctl --root=/ mask "$u" >/dev/null 2>&1; then
    log "  mask: $u"
    return 0
  fi
  ln -sfn /dev/null "$ROOT/etc/systemd/system/$u"
  log "  mask (手工软链): $u"
}

confirm_stage() { log "===== 阶段: $* ====="; }

# ------------------------------------------- 根文件系统布局 ------------------
# 统一在这里决定 rootfs 的布局, 各阶段 (06 fstab / 08 initramfs / 09 镜像 /
# 10 引导参数) 都读同一份结果, 保证永远自洽。返回值:
#   ext4          传统 ext4 镜像
#   btrfs-subvol  btrfs + @ / @home 子卷 (参考 Shorin 指南; 需要 root 才能建子卷)
#   btrfs-flat    btrfs 单子卷 (数据在顶层; 无 root 时的退路, 依然有透明压缩)
# 结果缓存在 $WORK/rootfs-layout, 可用 RAPHAEL_FORCE_LAYOUT 覆盖调试。
rootfs_layout() {
  if [ -s "$WORK/rootfs-layout" ] && [ -z "${RAPHAEL_FORCE_LAYOUT:-}" ]; then
    cat "$WORK/rootfs-layout"; return 0
  fi
  local layout
  if [ -n "${RAPHAEL_FORCE_LAYOUT:-}" ]; then
    layout="$RAPHAEL_FORCE_LAYOUT"
  elif [ "${ROOTFS_TYPE:-btrfs}" != "btrfs" ]; then
    layout="ext4"
  elif [ "$(id -u)" != "0" ]; then
    layout="btrfs-flat"           # 无 root: 挂不上, 建不了子卷
  elif ! command -v mkfs.btrfs >/dev/null 2>&1; then
    layout="ext4"
  else
    # 探测能否 loop 挂载 (CI 容器里可能没有 /dev/loop*)
    local t="$WORK/.loop-probe" m="$WORK/.loop-mnt"
    layout="btrfs-flat"
    if truncate -s 64M "$t" 2>/dev/null && mkfs.btrfs -q -f "$t" >/dev/null 2>&1; then
      mkdir -p "$m"
      if mount -o loop "$t" "$m" 2>/dev/null; then
        layout="btrfs-subvol"
        umount "$m" 2>/dev/null || true
      fi
      rmdir "$m" 2>/dev/null || true
    fi
    rm -f "$t"
  fi
  mkdir -p "$WORK"
  echo "$layout" > "$WORK/rootfs-layout"
  echo "$layout"
}

# btrfs 挂载参数 (含透明压缩); 子卷布局时额外给出 subvol= 前缀
btrfs_opts() {   # btrfs_opts [subvol]
  local sv="${1:-}"
  local o="compress=${BTRFS_COMPRESS:-zstd:3},noatime,ssd,discard=async,space_cache=v2"
  [ -n "$sv" ] && o="subvol=/$sv,$o"
  echo "$o"
}
