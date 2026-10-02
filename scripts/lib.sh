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
    mkdir -p "$ROOT/proc"
    if [ "$(id -u)" = "0" ]; then
      # 已经是真 root (sudo ./build.sh): 不要再套 user namespace ——
      # userns 内挂载 procfs 会受限制, 实测 unshare -r 会报
      # "挂载 .../work/root/proc 失败: 权限不够"。这里只建 mount/pid namespace。
      log "真 root 构建模式 (mount+pid namespace)"
      exec unshare -m -p -f --mount-proc="$ROOT/proc" --propagation private \
        env RAPHAEL_NS=1 PROJ="$PROJ" bash "$0" "$@"
    fi
    log "进入 user namespace (无 root 构建模式)"
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

# ------------------------------------------- 构建树属主归一化 ----------------
# 为什么必须做 (2026-10 事故复盘):
#   构建时如果在 userns 里以"假 root"跑, 生成/改动的文件在宿主上属主是 uid 1000。
#   镜像一旦带着 uid 1000 的文件, setuid 程序 (mount/umount/sudo/su/passwd/
#   unix_chkpwd/dbus-daemon-launch-helper) 就变成 setuid-1000: root 执行它们时
#   euid 会被内核改成 1000 -> "must be superuser to use mount"。
#   后果: systemd-remount-fs / boot.mount / tmp.mount / sys-kernel-config.mount /
#   usb-ncm (脚本里 mount -t configfs) / sshd 全部失败, 桌面进不去、网络也没了。
# 只有真 root (uid_map 首行 0 0) 才修得回来; userns 里 chown 到 0 是空操作。
user_uid_gid() {
  local line
  line="$(grep "^$USERNAME:" "$ROOT/etc/passwd" 2>/dev/null | head -1)"
  echo "${line:-::1000:1000}" | awk -F: '{print $3":"$4}'
}
gid_of() { grep "^$1:" "$ROOT/etc/group" 2>/dev/null | head -1 | cut -d: -f3; }

is_real_root() {
  [ "$(id -u)" = 0 ] || return 1
  awk 'NR==1{exit !($1==0 && $2==0)}' /proc/self/uid_map 2>/dev/null
}

normalize_ownership() {
  local ug setid_list="$WORK/setid.list" g p grp mm bad=0
  ug="$(user_uid_gid)"
  if ! is_real_root; then
    warn "════════════════════════════════════════════════════════════════"
    warn " 非真 root 构建 (userns): 无法把属主修回 root:root。"
    warn " 这样产出的镜像里 setuid 程序会失效, 刷机后 mount/sudo/sshd 全挂,"
    warn " 进不了桌面也没有网络。请用:  sudo ./build.sh  重新构建。"
    warn "════════════════════════════════════════════════════════════════"
    return 1
  fi
  log "属主归一化: 整树 -> root:root, /home/$USERNAME -> $ug"
  # 1) 记下 setuid/setgid 文件及其完整模式 (chown 可能清掉 s 位)
  find "$ROOT" -xdev -type f \( -perm -4000 -o -perm -2000 \) -printf '%m %p\n' \
    > "$setid_list" 2>/dev/null || : > "$setid_list"
  log "  setuid/setgid 文件: $(wc -l < "$setid_list") 个"
  # 2) 整树 chown (不跨文件系统, 不跟符号链接)
  find "$ROOT" -xdev -print0 2>/dev/null | xargs -0 -r -n 200 chown -h 0:0 2>/dev/null || true
  chown 0:0 "$ROOT" 2>/dev/null || true
  chmod 755 "$ROOT" 2>/dev/null || true
  # 3) 家目录还给用户
  chown -hR "$ug" "$ROOT/home/$USERNAME" 2>/dev/null || true
  # 4) 恢复 setuid/setgid 位
  while read -r m p; do [ -n "$p" ] && chmod "$m" "$p" 2>/dev/null || true; done < "$setid_list"
  # 5) 恢复少数几个"组属主"文件 (pacman 不认, 但功能上需要)
  for pair in "/usr/bin/wall:tty" "/usr/bin/write:tty" \
              "/usr/lib/utempter/utempter:utmp" \
              "/usr/lib/dbus-daemon-launch-helper:dbus" \
              "/var/log/journal:systemd-journal" \
              "/srv/ftp:ftp" "/var/games:games" "/etc/polkit-1/rules.d:polkitd"; do
    p="${pair%:*}"; grp="${pair#*:}"
    [ -e "$ROOT$p" ] || continue
    g="$(gid_of "$grp")"
    [ -n "$g" ] && chown "0:$g" "$ROOT$p" 2>/dev/null && log "  组属主: $p -> 0:$g ($grp)"
  done
  # 6) 断言: 关键 setuid 程序必须是 root:root 且带 s 位
  for p in usr/bin/mount usr/bin/umount usr/bin/sudo usr/bin/su usr/bin/passwd; do
    [ -e "$ROOT/$p" ] || continue
    mm="$(stat -c '%u:%g %a' "$ROOT/$p")"
    case "$mm" in 0:0\ 4*|0:0\ 6*) ;; *) warn "  ✗ $p = $mm (应为 0:0 + s 位)"; bad=1 ;; esac
  done
  [ "$bad" = 0 ] || die "属主归一化失败: setuid 程序属主不对, 这样的镜像刷进去开不了机"
  log "  校验通过: $(stat -c '%u:%g %a' "$ROOT/usr/bin/mount") /usr/bin/mount"
  return 0
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
    # 探测能否 loop 挂载 (精简系统/容器里常常没有 /dev/loop*, 有 root 就自己补)
    if [ "$(id -u)" = "0" ] && [ ! -e /dev/loop-control ]; then
      modprobe loop 2>/dev/null || true
      mknod /dev/loop-control c 10 237 2>/dev/null || true
      for _i in 0 1 2 3 4 5 6 7; do mknod "/dev/loop$_i" b 7 "$_i" 2>/dev/null || true; done
      log "已补 /dev/loop* 设备节点 (原系统缺失)"
    fi
    local t="$WORK/.loop-probe" m="$WORK/.loop-mnt"
    layout="btrfs-flat"
    # 注意: btrfs 最小设备尺寸 ~114MB, 探测文件必须够大 (给 64M 会 mkfs 失败 -> 误判 flat)
    if truncate -s 256M "$t" 2>/dev/null && mkfs.btrfs -q -f "$t" >/dev/null 2>&1; then
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
# ---------------------------------------- 蓝牙地址注入 ----------------------
# 蓝牙地址是**每台设备唯一**的 (产线写入设备自己的 dtbo 分区, 而刷机会清掉 dtbo),
# 所以公开镜像里不能带某个人的地址 -> 两条路:
#   1) 构建时注入: config/build.conf 旁边的 config/local.conf 的 BT_MAC,
#      或 CI 里用仓库 Secret IMAGE_BT_MAC (见 10-image-boot.sh)
#   2) 刷机时注入: scripts/11-flash.sh --bt-mac <地址> (把公开镜像临时改成自己的)
# 写法 = **设备树里的字节序**(小端), 与本项目历史 DTB 一致, 例如
#   11 22 33 44 55 66   ->  系统里 bluetoothctl 显示为 66:55:44:33:22:11
# (如果你手上只有屏幕上显示的地址, 把它反过来写即可。)
BT_DT_NODE="/soc@0/geniqup@cc0000/serial@c8c000/bluetooth"

# 归一化成 fdtput 需要的 "11 22 33 44 55 66"; 失败返回 1
normalize_bt_mac() {   # normalize_bt_mac <任意写法>
  local raw="$1" hex
  hex="$(printf '%s' "$raw" | tr -cd '0-9a-fA-F' | tr 'A-F' 'a-f')"
  printf '%s' "$hex" | grep -qE '^[0-9a-f]{12}$' || return 1
  printf '%s' "$hex" | sed 's/../& /g; s/ $//'
}

# 把 BT 地址写进 FAT 引导镜像里的设备树 (原地修改该镜像文件)
inject_bt_mac_into_boot_img() {   # inject_bt_mac_into_boot_img <boot-cache.img> <归一化后的地址>
  local img="$1" mac="$2" tmp
  [ -f "$img" ] || return 1
  command -v fdtput >/dev/null 2>&1 || { warn "缺少 fdtput (dtc 包), 无法注入蓝牙地址"; return 1; }
  setup_mtools >&2
  tmp="$(mktemp -d)"
  if ! mrun mcopy -o -i "$img" "::/dtbs/qcom/raphael-redmi-k20pro.dtb" "$tmp/dtb" 2>/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  # shellcheck disable=SC2086
  if ! fdtput -t bx "$tmp/dtb" "$BT_DT_NODE" local-bd-address $mac 2>/dev/null; then
    rm -rf "$tmp"; return 1
  fi
  mrun mcopy -o -i "$img" "$tmp/dtb" "::/dtbs/qcom/raphael-redmi-k20pro.dtb" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  return 0
}

# ---------------------------------------- 根文件系统 fstab ------------------
# ★ fstab 的根挂载选项必须和 09 实际造出的布局、10 写进引导项的 rootflags
#   **三者一致**。踩过的坑: rootfs-layout 缓存里写着 btrfs-subvol, 但 09 里
#   loop 挂载失败回退成 flat (例如宿主内核没带 loop 模块), 而 fstab 还是 06
#   按 subvol 写的 -> 镜像里没有 /@ 子卷却让内核去挂它 -> 开不了机。
#   所以 06 写完还不够, 09 在实际确定布局后要**再写一次** (幂等)。
write_root_fstab() {   # write_root_fstab [layout] [uuid]
  local layout="${1:-$(rootfs_layout)}"
  local uuid="${2:-$(rootfs_uuid)}"
  {
    printf '# <device>                                       <dir>   <type>  <options>                                                                          <dump> <pass>\n'
    # 根用 **UUID**: 由内核/udev 直接从文件系统读出, 不依赖 GPT 分区名。
    # (PARTLABEL 解析不到时 systemd-remount-fs 会失败, 根可能停在只读 -> 一堆服务挂)
    case "$layout" in
      btrfs-subvol)
        # 注意: / 这一行**不要**加 nofail —— 加了 systemd 可能跳过"把根重挂成 rw",
        # 结果根一直只读, sshd(生成主机密钥)/usb-ncm(写 configfs) 等全失败。
        printf 'UUID=%-42s /       btrfs   rw,%s,x-systemd.growfs  0      1\n' "$uuid" "$(btrfs_opts "$BTRFS_SUBVOL_ROOT")"
        # /home **不单独挂载**: 数据本来就在 @/home 里 (@home 只是副本)。实测单独挂
        # @home 会让 user@1000 会话 "Dependency failed" -> SDDM respawn 循环。
        ;;
      btrfs-flat)
        printf 'UUID=%-42s /       btrfs   rw,%s,x-systemd.growfs  0      1\n' "$uuid" "$(btrfs_opts)"
        ;;
      *)
        printf 'UUID=%-42s /       ext4    rw,errors=remount-ro,x-systemd.growfs  0      1\n' "$uuid"
        ;;
    esac
    # /boot 带 nofail: 分区名解析不到也只是这一个单元失败, 不会拖垮启动
    printf 'PARTLABEL=cache                                /boot   vfat    umask=0077,nofail,noatime,x-systemd.device-timeout=10       0      0\n'
  } > "$ROOT/etc/fstab"
}

btrfs_opts() {   # btrfs_opts [subvol]
  local sv="${1:-}"
  local o="compress=${BTRFS_COMPRESS:-zstd:3},noatime,ssd,discard=async,space_cache=v2"
  [ -n "$sv" ] && o="subvol=/$sv,$o"
  echo "$o"
}
