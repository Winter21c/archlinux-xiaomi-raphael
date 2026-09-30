#!/bin/bash
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
  rm -rf "$ROOT"
  mkdir -p "$ROOT"
  # tar 遇到无法映射的属主 (uid 1000 alarm) 会返回非 0, 属正常现象
  tar --numeric-owner -xzf "$TARBALL" -C "$ROOT" 2> "$WORK/logs/tar-warnings.txt" || true
  log "解包完成: $(du -sh "$ROOT" | cut -f1) ($(find "$ROOT" | wc -l) 个条目)"
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
