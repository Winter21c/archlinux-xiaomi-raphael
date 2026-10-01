#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 01 — 解包 Arch Linux ARM rootfs
#  在 user namespace 内以 "假 root" 解包, 这样 setuid 位与属主才能正确落盘。
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount
setup_qemu_shim

confirm_stage "01 解包 Arch Linux ARM rootfs"

TARBALL="$DL/ArchLinuxARM-aarch64-latest.tar.gz"
[ -s "$TARBALL" ] || die "缺少 $TARBALL (先跑 00-fetch.sh)"

if [ -x "$ROOT/usr/bin/bash" ] && [ -x "$ROOT/usr/bin/pacman" ]; then
  log "rootfs 已存在, 跳过解包 ($(du -sh "$ROOT" | cut -f1))"
else
  log "解包中 (约 2.5GB, 需要几分钟)..."
  mkdir -p "$WORK/logs"
  # 注意: require_ns 用 unshare --mount-proc 把 /proc 挂在 $ROOT/proc,
  # ns_mount 又把 /dev/* 逐个 bind 进 $ROOT/dev。所以这里**不能**整体
  # rm -rf "$ROOT" —— 挂载点会报 "Device or resource busy" 而失败
  # (干净环境 / CI 上必现; 本地因为走了"已存在"分支才没暴露)。
  # 只清理挂载点之外的内容, 保留 proc / sys / dev 本身。
  if mountpoint -q "$ROOT" || mountpoint -q "$ROOT/proc" || mountpoint -q "$ROOT/dev"; then
    log "检测到 $ROOT 内已有挂载点, 只清理非挂载内容"
    find "$ROOT" -mindepth 1 -maxdepth 1 \
      ! -name proc ! -name sys ! -name dev \
      -exec rm -rf {} + 2>/dev/null || true
  else
    rm -rf "$ROOT"
  fi
  mkdir -p "$ROOT"
  # tar 遇到无法映射的属主 (uid 1000 alarm) 或已存在的挂载点会返回非 0, 属正常现象
  tar --numeric-owner -xzf "$TARBALL" -C "$ROOT" 2> "$WORK/logs/tar-warnings.txt" || true
  log "解包完成: $(du -sh "$ROOT" | cut -f1), 顶层 $(find "$ROOT" -maxdepth 1 -mindepth 1 | wc -l) 个条目"
  [ -x "$ROOT/usr/bin/bash" ] || die "解包后仍找不到 $ROOT/usr/bin/bash, 解包可能失败 (见 work/logs/tar-warnings.txt)"
fi

# ---------------------------------------------------------------------------
# 修正 setuid/setgid 位: 若解包不是在 root 下完成, 这些位会丢失, 导致
# sudo/passwd/su 等无法工作。这里直接从 tarball 元数据恢复。
# ---------------------------------------------------------------------------
log "校正 setuid/setgid 权限位"
python3 - "$TARBALL" > "$WORK/setid-list.txt" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as tf:
    for m in tf:
        if m.mode & 0o6000:
            print(oct(m.mode & 0o7777)[2:], m.name.lstrip('./'))
PY
fixed=0
while read -r mode path; do
  [ -n "$path" ] || continue
  [ -e "$ROOT/$path" ] || continue
  cur=$(stat -c '%a' "$ROOT/$path")
  [ "$cur" = "$mode" ] && continue
  chmod "$mode" "$ROOT/$path" && fixed=$((fixed+1))
done < "$WORK/setid-list.txt"
log "权限位修正: $fixed 个文件 (共 $(wc -l < "$WORK/setid-list.txt") 个 setuid/setgid 条目)"

# ---------------------------------------------------------------------------
# 卸载发行版自带的内核与固件: 我们用作者为 raphael 定制的内核和固件替换
# ---------------------------------------------------------------------------
KEEP_KVER="$(cat "$WORK/kver" 2>/dev/null || true)"
for d in "$ROOT"/usr/lib/modules/*; do
  [ -d "$d" ] || continue
  b="$(basename "$d")"
  case "$b" in
    *sm8150*) continue ;;                 # 定制内核, 保留
  esac
  [ -n "$KEEP_KVER" ] && [ "$b" = "$KEEP_KVER" ] && continue
  log "移除发行版通用内核模块: $b"
  rm -rf "$d"
done
if [ -d "$ROOT/var/lib/pacman/local" ]; then
  for p in linux-aarch64 linux-aarch64-headers; do
    for e in "$ROOT"/var/lib/pacman/local/$p-*; do
      [ -d "$e" ] || continue
      log "从 pacman 数据库注销: $(basename "$e")"
      rm -rf "$e"
    done
  done
fi
rm -f "$ROOT"/boot/vmlinuz-* "$ROOT"/boot/initramfs-* "$ROOT"/boot/Image "$ROOT"/boot/Image.gz 2>/dev/null || true
rm -rf "$ROOT"/boot/dtbs 2>/dev/null || true

# 基础目录
mkdir -p "$ROOT"/{boot,proc,sys,dev,run,tmp,root,home,etc/systemd/system,etc/systemd/logind.conf.d}
chmod 1777 "$ROOT/tmp" "$ROOT/var/tmp" 2>/dev/null || true
chmod 700 "$ROOT/root"

log "rootfs 就绪: $(du -sh "$ROOT" | cut -f1)"
verify_qemu
