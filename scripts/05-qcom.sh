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
# 注意: 09-image-rootfs.sh 会删除 rootfs 内的 qemu 垫片, 重新跑本阶段时必须补回,
# 否则后面的 enable_unit / ldconfig (需要 chroot+qemu) 会静默失败。
setup_qemu_shim

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
  # ★ 必须在 STAGE 里补 libqrtr.so 软链: `-lqrtr` 只认 libqrtr.so / libqrtr.a,
  #   光有 libqrtr.so.1 是找不到的 (ld.lld: unable to find library -lqrtr)。
  #   本地构建时 rootfs 里还留着上一次装好的 /usr/lib/libqrtr.so, 会被 clang 的
  #   sysroot 搜索路径兜住, 所以这个坑只在"全新 rootfs"的 CI 上暴露 —— 一旦暴露,
  #   后面 rmtfs/pd-mapper/tqftpserv/qrtr-* 会**全部**链接失败, 而脚本只 warn 不报错,
  #   最后产出一个没有 WiFi、没有音频的镜像 (2026-10-02 真机上就是这样)。
  ln -sfn libqrtr.so.1 "$STAGE/libqrtr.so"
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
  # 注意: 必须直接写单元文件, 不能 sed 上游的 *.service.in ——
  # 模板里有 @prefix@/@bindir@ 等多个占位符, 漏替换任何一个都会让 systemd
  # 报 "bad unit file setting" 而拒绝加载, 结果就是没有 Wi-Fi (已踩过坑)。
  cat > "$ROOT/usr/lib/systemd/system/tqftpserv.service" <<'UNIT'
[Unit]
Description=QRTR TFTP service
# 通过 QRTR 给远端处理器提供固件。没有它: 调制解调器的 msm/modem/wlan_pd
# 电源域起不来 -> 不发布 WLFW(69) 服务 -> ath10k 拿不到网卡 -> Wi-Fi 扫描为空。
After=qrtr.service

[Service]
ExecStart=/usr/bin/tqftpserv
Restart=always
StateDirectory=tqftpserv

[Install]
WantedBy=multi-user.target
UNIT
fi

# ---------------------------------------------------------------------------
# 4. 单元与内核模块调整
# ---------------------------------------------------------------------------
for u in "$ROOT"/usr/lib/systemd/system/{pd-mapper,rmtfs}.service; do
  [ -f "$u" ] && sed -i '/ConditionKernelVersion/d' "$u"
done
# servreg 电源域映射表: 必须由【内核】qcom_pd_mapper 提供 ——
# 真机验证: 设备固件里的 *.jsn 只有 adsp/cdsp/slpi 条目, 而
# msm/modem/wlan_pd (Wi-Fi 必需) 只存在于内核的硬编码表里。
# 用 modules-load.d 让它尽早加载, 而不是靠 udev 异步 modalias。
cat > "$ROOT/etc/modules-load.d/raphael-pd-mapper.conf" <<'EOF'
# 调制解调器在启动早期就会查 servreg 要 msm/modem/wlan_pd, 必须提前就位
qcom_pd_mapper
EOF

[ -x "$ROOT/usr/bin/rmtfs" ]     && enable_unit rmtfs.service
[ -f "$ROOT/usr/lib/systemd/system/tqftpserv.service" ] && enable_unit tqftpserv.service
# 用户态 pd-mapper 默认不启用: 真机验证内核 qcom_pd_mapper 已覆盖
# adsp_audio_pd / adsp_root_pd / cdsp_root_pd / mpss_root_pd_gps / mpss_wlan_pd。
# 若以后要调 SLPI/传感器, 可以 systemctl enable --now pd-mapper 再试。
if [ -e "$ROOT/usr/lib/systemd/system/pd-mapper.service" ]; then
  gq /usr/bin/systemctl --root=/ disable pd-mapper >/dev/null 2>&1 || true
  rm -f "$ROOT/etc/systemd/system"/*.wants/pd-mapper.service
  log "  用户态 pd-mapper 保持禁用 (内核 qcom_pd_mapper 已提供必需的电源域)"
fi
# 清理历史遗留: 早期版本写过 blacklist (会导致 Wi-Fi 完全不可用)
rm -f "$ROOT/etc/modprobe.d/raphael-pd-mapper.conf"
rm -f "$ROOT/etc/systemd/system/multi-user.target.wants/pd-mapper.service"
rm -f "$ROOT/etc/systemd/system/graphical.target.wants/pd-mapper.service"

gq /usr/bin/ldconfig >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 5. 校验
# ---------------------------------------------------------------------------
log "产物校验:"
MISSING=()
for b in rmtfs pd-mapper tqftpserv qrtr-lookup; do
  if [ -x "$ROOT/usr/bin/$b" ]; then
    printf '  %-12s %s\n' "$b" "$(file -b "$ROOT/usr/bin/$b" | cut -c1-60)"
  else
    warn "  $b 未生成"
    # libqrtr / rmtfs / tqftpserv 是"缺了镜像就是残废"的三件套:
    #   没有 rmtfs      -> 调制解调器起不来
    #   没有 tqftpserv  -> ADSP 拿不到固件 -> Wi-Fi 扫描为空 + 音频 AFE 端口使能超时
    # 以前这里只 warn, 结果 CI 静默产出没 WiFi/没声音的镜像, 所以改成硬失败。
    case "$b" in rmtfs|tqftpserv) MISSING+=("$b") ;; esac
  fi
done
if [ -f "$ROOT/usr/lib/libqrtr.so.1" ]; then
  log "  libqrtr.so.1 已安装"
else
  MISSING+=(libqrtr.so.1)
fi
if [ "${#MISSING[@]}" -gt 0 ]; then
  die "阶段 05 缺少必需产物: ${MISSING[*]} —— 缺这些会让镜像没有 Wi-Fi 与音频, 拒绝继续"
fi

rm -rf "$SRC" "$STAGE"
log "阶段 05 完成"
