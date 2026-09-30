#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 05 — 构建 Qualcomm 用户态服务 (Arch Linux ARM 仓库里没有)
#
#  为什么需要:
#    rmtfs      — 把调制解调器的 EFS/共享内存分区通过 QMI 提供给 MSS; 没有它
#                 调制解调器固件无法启动 (无信号/无数据)
#    pd-mapper  — 回答 ADSP 的 protection-domain 查询 (音频、Wi-Fi WLAN PD 需要)
#    tqftpserv  — 通过 QRTR 给 ADSP/CDSP 传固件 (没有它音频起不来)
#    qrtr       — 上面三个都依赖的 IPC Router 用户态库 (ALARM 仓库没有)
#
#  构建方式: 宿主 clang 交叉编译 (--target=aarch64-linux-gnu + rootfs 作为
#  sysroot + ALARM gcc 包的 crt/libgcc)。不需要 root, 也不需要 binfmt_misc。
#  (之所以不用 qemu 原生编译: qemu-user 无法在无 binfmt 的情况下执行子进程。)
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount

confirm_stage "05 构建 Qualcomm 用户态服务 (交叉编译)"

SRC="$WORK/qcom-src"
GCCDIR_ROOT="$WORK/gcc-sysroot"
mkdir -p "$SRC" "$LOGS"

# ---------------------------------------------------------------------------
# 1. 交叉编译工具链: clang + rootfs sysroot + ALARM gcc 的 crt/libgcc
# ---------------------------------------------------------------------------
if [ ! -d "$GCCDIR_ROOT/usr/lib/gcc" ]; then
  log "下载 ALARM gcc 包 (提供 crtbegin/libgcc, 链接阶段需要)"
  fn="$(curl -sSL --max-time 30 "http://mirror.archlinuxarm.org/aarch64/core/" \
        | grep -oE 'gcc-[0-9][^"]*aarch64\.pkg\.tar\.xz' | head -1)"
  [ -n "$fn" ] || die "无法定位 ALARM gcc 包"
  fetch "http://mirror.archlinuxarm.org/aarch64/core/$fn" "$DL/$fn"
  rm -rf "$GCCDIR_ROOT"; mkdir -p "$GCCDIR_ROOT"
  tar -xf "$DL/$fn" -C "$GCCDIR_ROOT" 2>/dev/null || true
fi
GCCLIB="$(ls -d "$GCCDIR_ROOT"/usr/lib/gcc/aarch64-unknown-linux-gnu/*/ 2>/dev/null | head -1)"
[ -n "$GCCLIB" ] || die "找不到 ALARM gcc 的 libgcc 目录"

CC_BASE=(clang --target=aarch64-linux-gnu --sysroot="$ROOT"
         -B"$GCCLIB" -L"$GCCLIB" -fuse-ld=lld -O2 -Wall -Wno-unused-result)
log "编译器: $(clang --version | head -1)"
log "sysroot: $ROOT"

# ---------------------------------------------------------------------------
# 2. 源码
# ---------------------------------------------------------------------------
log "下载/解包源码"
for p in qrtr rmtfs pd-mapper tqftpserv; do
  fetch "https://github.com/linux-msm/$p/archive/refs/heads/master.tar.gz" "$DL/$p-master.tar.gz"
  rm -rf "$SRC/$p"; mkdir -p "$SRC/$p"
  tar -xzf "$DL/$p-master.tar.gz" -C "$SRC/$p" --strip-components=1
done

# 所有 daemon 都 #include <libqrtr.h>, 把 qrtr 头文件目录加进公共编译参数
CC_BASE+=(-I"$SRC/qrtr/include")

STAGE="$WORK/qcom-out"
rm -rf "$STAGE"; mkdir -p "$STAGE"

compile() {  # compile <logname> <args...>
  local name="$1"; shift
  log "编译 $name"
  if "${CC_BASE[@]}" "$@" > "$LOGS/build-$name.log" 2>&1; then
    return 0
  fi
  warn "  编译 $name 失败, 日志尾部:"
  tail -8 "$LOGS/build-$name.log" | sed 's/^/      /' >&2
  return 1
}

# ---- libqrtr --------------------------------------------------------------
OK_LIBQRTR=0
if compile libqrtr -fPIC -shared -Wl,-soname,libqrtr.so.1 \
      -I "$SRC/qrtr/include" -o "$STAGE/libqrtr.so.1" \
      "$SRC/qrtr/lib/logging.c" "$SRC/qrtr/lib/qmi.c" "$SRC/qrtr/lib/qrtr.c"; then
  OK_LIBQRTR=1
fi

LINK_QRTR=(-L"$STAGE" -lqrtr -Wl,-rpath-link,"$STAGE")

# ---- qrtr 工具 ------------------------------------------------------------
if [ "$OK_LIBQRTR" = 1 ]; then
  compile qrtr-lookup "${LINK_QRTR[@]}" -I "$SRC/qrtr/include" \
      -o "$STAGE/qrtr-lookup" "$SRC/qrtr/src/lookup.c" || true
  compile qrtr-cfg "${LINK_QRTR[@]}" -I "$SRC/qrtr/include" \
      -o "$STAGE/qrtr-cfg" "$SRC/qrtr/src/addr.c" "$SRC/qrtr/src/cfg.c" || true
fi

# ---- rmtfs (需要 libudev; glibc 2.34+ 后不需要 -lpthread) -----------------
OK_RMTFS=0
if [ "$OK_LIBQRTR" = 1 ]; then
  if compile rmtfs "${LINK_QRTR[@]}" -I "$SRC/rmtfs" \
        -o "$STAGE/rmtfs" \
        "$SRC/rmtfs/qmi_rmtfs.c" "$SRC/rmtfs/rmtfs.c" "$SRC/rmtfs/rproc.c" \
        "$SRC/rmtfs/sharedmem.c" "$SRC/rmtfs/storage.c" "$SRC/rmtfs/util.c" \
        -ludev; then
    OK_RMTFS=1
  fi
fi

# ---- pd-mapper ------------------------------------------------------------
OK_PDMAP=0
if [ "$OK_LIBQRTR" = 1 ]; then
  if compile pd-mapper "${LINK_QRTR[@]}" -I "$SRC/pd-mapper" \
        -o "$STAGE/pd-mapper" \
        "$SRC/pd-mapper/pd-mapper.c" "$SRC/pd-mapper/assoc.c" \
        "$SRC/pd-mapper/json.c" "$SRC/pd-mapper/servreg_loc.c" \
        "$SRC/pd-mapper/lzma_decomp.c" -llzma; then
    OK_PDMAP=1
  fi
fi

# ---- tqftpserv (需要 libzstd) --------------------------------------------
OK_TQ=0
if [ "$OK_LIBQRTR" = 1 ]; then
  if compile tqftpserv "${LINK_QRTR[@]}" -I "$SRC/tqftpserv" -DHAVE_ZSTD \
        -o "$STAGE/tqftpserv" \
        "$SRC/tqftpserv/translate.c" "$SRC/tqftpserv/tqftpserv.c" \
        "$SRC/tqftpserv/zstd-decompress.c" -lzstd; then
    OK_TQ=1
  fi
fi

# ---------------------------------------------------------------------------
# 3. 安装进 rootfs
# ---------------------------------------------------------------------------
log "安装到 rootfs"
install -D -m 755 "$STAGE/libqrtr.so.1" "$ROOT/usr/lib/libqrtr.so.1"
ln -sfn libqrtr.so.1 "$ROOT/usr/lib/libqrtr.so"
install -D -m 644 "$SRC/qrtr/include/libqrtr.h" "$ROOT/usr/include/libqrtr.h"
install -D -m 644 "$SRC/qrtr/include/logging.h" "$ROOT/usr/include/logging.h"
install -D -m 644 "$SRC/qrtr/include/ns.h"      "$ROOT/usr/include/ns.h"
mkdir -p "$ROOT/usr/lib/pkgconfig"
cat > "$ROOT/usr/lib/pkgconfig/libqrtr.pc" <<'EOF'
prefix=/usr
exec_prefix=${prefix}
libdir=${prefix}/lib
includedir=${prefix}/include

Name: libqrtr
Description: Qualcomm IPC Router userspace library
Version: 1.2
Libs: -L${libdir} -lqrtr
Cflags: -I${includedir}
EOF

for b in qrtr-lookup qrtr-cfg; do
  [ -f "$STAGE/$b" ] && install -D -m 755 "$STAGE/$b" "$ROOT/usr/bin/$b"
done

if [ "$OK_RMTFS" = 1 ]; then
  install -D -m 755 "$STAGE/rmtfs" "$ROOT/usr/bin/rmtfs"
  mkdir -p "$ROOT/var/lib/rmtfs" "$ROOT/usr/lib/udev/rules.d"
  sed -e 's+RMTFS_PATH+/usr/bin+g' -e 's+RMTFS_EFS_PATH+/var/lib/rmtfs+g' \
      "$SRC/rmtfs/rmtfs.service.in" > "$ROOT/usr/lib/systemd/system/rmtfs.service"
  sed -e 's+RMTFS_PATH+/usr/bin+g' -e 's+RMTFS_EFS_PATH+/var/lib/rmtfs+g' \
      "$SRC/rmtfs/rmtfs-dir.service.in" > "$ROOT/usr/lib/systemd/system/rmtfs-dir.service"
  install -D -m 644 "$SRC/rmtfs/rmtfs.rules" "$ROOT/usr/lib/udev/rules.d/99-rmtfs.rules"
fi
if [ "$OK_PDMAP" = 1 ]; then
  install -D -m 755 "$STAGE/pd-mapper" "$ROOT/usr/bin/pd-mapper"
  sed 's+PD_MAPPER_PATH+/usr/bin+g' "$SRC/pd-mapper/pd-mapper.service.in" \
      > "$ROOT/usr/lib/systemd/system/pd-mapper.service"
fi
if [ "$OK_TQ" = 1 ]; then
  install -D -m 755 "$STAGE/tqftpserv" "$ROOT/usr/bin/tqftpserv"
  sed -e 's+TQFTPSERV_PATH+/usr/bin+g' -e 's+@bindir@+/usr/bin+g' \
      "$SRC/tqftpserv/tqftpserv.service.in" \
      > "$ROOT/usr/lib/systemd/system/tqftpserv.service" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. 单元与内核模块调整
# ---------------------------------------------------------------------------
for u in "$ROOT"/usr/lib/systemd/system/{pd-mapper,rmtfs}.service; do
  [ -f "$u" ] && sed -i '/ConditionKernelVersion/d' "$u"
done
# 内核内建 pd-mapper (CONFIG_QCOM_PD_MAPPER) 与用户态版争抢同一个 QMI 服务号,
# 用户态版支持 SLPI (传感器), 因此屏蔽内核模块。
# 想换回内核版: 删除本文件并 systemctl disable pd-mapper
cat > "$ROOT/etc/modprobe.d/raphael-pd-mapper.conf" <<'EOF'
blacklist qcom_pd_mapper
EOF

[ -x "$ROOT/usr/bin/rmtfs" ]     && enable_unit rmtfs.service
[ -x "$ROOT/usr/bin/pd-mapper" ] && enable_unit pd-mapper.service
[ -f "$ROOT/usr/lib/systemd/system/tqftpserv.service" ] && enable_unit tqftpserv.service

gq /usr/bin/ldconfig >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 5. 校验
# ---------------------------------------------------------------------------
log "产物校验:"
for b in rmtfs pd-mapper tqftpserv qrtr-lookup; do
  if [ -x "$ROOT/usr/bin/$b" ]; then
    printf '  %-12s %s\n' "$b" "$(file -b "$ROOT/usr/bin/$b" | cut -c1-60)"
  else
    warn "  $b 未生成"
  fi
done
[ -f "$ROOT/usr/lib/libqrtr.so.1" ] && log "  libqrtr.so.1 已安装"

rm -rf "$SRC" "$STAGE"
log "阶段 05 完成"
