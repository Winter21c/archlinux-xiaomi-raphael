#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 02 — 用 pacman 安装 Arch Linux ARM 软件包
#  做法: 在 user namespace 内, 用宿主 x86_64 的 pacman 以 --arch aarch64
#        直接安装到目标 rootfs (不需要 chroot 执行 aarch64 程序, 速度快)。
#        install scriptlet 全部跳过 (--noscriptlet), 之后在本阶段末尾用 qemu
#        显式补跑关键的构建后步骤 (ldconfig / sysusers / 字体缓存 / GSettings)。
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount
setup_qemu_shim

confirm_stage "02 安装软件包 (pacman)"

PKGCACHE="$WORK/pkgcache"
BUILD_CONF="$WORK/pacman-build.conf"
mkdir -p "$PKGCACHE" "$WORK/empty-hooks"

cat > "$BUILD_CONF" <<EOF
[options]
Architecture = aarch64
SigLevel = Never
DownloadUser = root
DisableSandboxFilesystem
DisableSandboxSyscalls
HookDir = $WORK/empty-hooks/
HoldPkg = pacman glibc
IgnorePkg = wireless-regdb
ParallelDownloads = 12
CheckSpace
Color
[core]
Server = $ALARM_MIRROR_PRIMARY/\$arch/\$repo
Server = $ALARM_MIRROR_FALLBACK/\$arch/\$repo
[extra]
Server = $ALARM_MIRROR_PRIMARY/\$arch/\$repo
Server = $ALARM_MIRROR_FALLBACK/\$arch/\$repo
# archlinuxcn: AUR 助手 (paru)、rime-ice 等社区包, 参考 Shorin 指南
[archlinuxcn]
Server = https://mirrors.ustc.edu.cn/archlinuxcn/\$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/\$arch
Server = https://repo.archlinuxcn.org/\$arch
EOF

PACMAN=(pacman --arch aarch64 -r "$ROOT" --config "$BUILD_CONF"
        --dbpath "$ROOT/var/lib/pacman" --cachedir "$PKGCACHE" --noconfirm)

# 目标 rootfs 内的 pacman 配置 (设备上使用): 打开签名校验, 用国内镜像
mkdir -p "$ROOT/etc/pacman.d"
cat > "$ROOT/etc/pacman.d/mirrorlist" <<EOF
# 中国大陆镜像 (构建时写入)
Server = $ALARM_MIRROR_PRIMARY/\$arch/\$repo
Server = $ALARM_MIRROR_FALLBACK/\$arch/\$repo
Server = http://mirror.archlinuxarm.org/\$arch/\$repo
EOF
sed -i -e 's/^Architecture = .*/Architecture = aarch64/' \
       -e 's/^#Color/Color/' "$ROOT/etc/pacman.conf"
# ★ 关键: 作者内核没有编 CONFIG_SECURITY_LANDLOCK, 而 pacman 7.1 默认用 Landlock
#   沙箱下载, 在真机上会直接失败 ("Landlock is not supported by the kernel"),
#   结果是用户根本没法用 pacman 装软件。这里关掉沙箱。
for opt in DisableSandboxFilesystem DisableSandboxSyscalls; do
  grep -q "^$opt" "$ROOT/etc/pacman.conf" || sed -i "/^\[options\]/a $opt" "$ROOT/etc/pacman.conf"
done
# 目标系统加 archlinuxcn 源 (密钥由 raphael-firstboot 首次开机导入)
if ! grep -q '^\[archlinuxcn\]' "$ROOT/etc/pacman.conf"; then
  cat >> "$ROOT/etc/pacman.conf" <<'CNEOF'

[archlinuxcn]
# 密钥由 archlinuxcn-keyring 提供, raphael-firstboot 首次开机会 pacman-key --populate
SigLevel = Optional TrustedOnly
Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch
Server = https://repo.archlinuxcn.org/$arch
CNEOF
fi
# 幂等: 老 rootfs 里已有 [archlinuxcn] 段时补上 SigLevel
if ! grep -A1 '^\[archlinuxcn\]' "$ROOT/etc/pacman.conf" | grep -q '^SigLevel'; then
  sed -i '/^\[archlinuxcn\]/a SigLevel = Optional TrustedOnly' "$ROOT/etc/pacman.conf"
fi
grep -q '^Architecture' "$ROOT/etc/pacman.conf" || echo 'Architecture = aarch64' >> "$ROOT/etc/pacman.conf"
# 目标系统上启用签名校验 (需要先 archlinuxarm-keyring)
if ! grep -q '^SigLevel' "$ROOT/etc/pacman.conf"; then
  sed -i 's/^\[options\]/[options]\nSigLevel = Required DatabaseOptional/' "$ROOT/etc/pacman.conf"
fi

log "同步软件包数据库"
"${PACMAN[@]}" -Sy

# ---------------------------------------------------------------------------
# 校验包名 (不存在的包只告警, 不中断; 手机端可选应用常常缺失)
# ---------------------------------------------------------------------------
VALID=(); MISSING=()
for p in $ALL_PKGS; do
  if "${PACMAN[@]}" -Si "$p" >/dev/null 2>&1; then VALID+=("$p"); else MISSING+=("$p"); fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
  warn "以下包在 Arch Linux ARM 仓库中不存在, 已跳过: ${MISSING[*]}"
fi
log "准备安装 ${#VALID[@]} 个包 (含依赖)"

# ---------------------------------------------------------------------------
# 安装
# ---------------------------------------------------------------------------
"${PACMAN[@]}" -S --noscriptlet --needed "${VALID[@]}" 2>&1 | tail -30

# ---------------------------------------------------------------------------
# 移除手机上不需要的电视版界面 (plasma-bigscreen):
# 它的自启动项会拉起 plasma-bigscreen-inputhandler, 缺 libcec 时报 status=127
# ---------------------------------------------------------------------------
if ls -d "$ROOT"/var/lib/pacman/local/plasma-bigscreen-* >/dev/null 2>&1; then
  log "移除 plasma-bigscreen (电视版界面, 手机用不到)"
  "${PACMAN[@]}" -Rdd plasma-bigscreen >/dev/null 2>&1 || warn "  移除失败"
fi

# ---------------------------------------------------------------------------
# 清理发行版自带内核遗留 & 默认用户
# ---------------------------------------------------------------------------
rm -rf "$ROOT/home/alarm"
if ! grep -q "^$USERNAME:" "$ROOT/etc/passwd"; then
  userdel --root "$ROOT" alarm 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 补跑 install scriptlet 的关键部分 (用 qemu 显式执行, 无需 binfmt)
# ---------------------------------------------------------------------------
log "补跑构建后步骤 (ldconfig / sysusers / tmpfiles / 字体与 schema 缓存)"
run_if() {  # run_if <abs-path-in-rootfs> [args...]
  local bin="$1"; shift
  if [ -x "$ROOT$bin" ]; then
    gq "$bin" "$@" >/dev/null 2>&1 && log "  ok: $bin" || warn "  fail: $bin"
  fi
}
run_if /usr/bin/ldconfig
run_if /usr/bin/systemd-sysusers
run_if /usr/bin/systemd-tmpfiles --create
run_if /usr/bin/glib-compile-schemas /usr/share/glib-2.0/schemas
run_if /usr/bin/fc-cache -f
[ -x "$ROOT/usr/bin/update-desktop-database" ] && run_if /usr/bin/update-desktop-database -q
[ -x "$ROOT/usr/bin/update-mime-database" ] && run_if /usr/bin/update-mime-database /usr/share/mime
[ -d "$ROOT/usr/share/icons/hicolor" ] && run_if /usr/bin/gtk-update-icon-cache -qtf /usr/share/icons/hicolor
if [ -x "$ROOT/usr/bin/gdk-pixbuf-query-loaders" ]; then
  for d in "$ROOT"/usr/lib/gdk-pixbuf-2.0/*/; do
    [ -d "$d" ] || continue
    gq /usr/bin/gdk-pixbuf-query-loaders > "$d/loaders.cache" 2>/dev/null || true
  done
fi

log "已安装包数: $(ls "$ROOT/var/lib/pacman/local" | wc -l)"
log "rootfs 大小: $(du -sh "$ROOT" | cut -f1)"
