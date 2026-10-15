#!/usr/bin/env bash
# 03b-ms91xx.sh: 编译并安装 MacroSilicon MS91xx (MS9132/MS9133/MS9135) USB 投屏驱动
# ---------------------------------------------------------------------------
#   做什么:
#     把 vendor/ms91xx 里的驱动交叉编译成 aarch64 内核模块装进 rootfs。
#     插上 USB→HDMI/VGA 转接器 (lsusb 看到 345f:9132 / 345f:9133 / 534d:6021) 后
#     系统会多出一块屏, 可以直接当扩展屏/投屏用 (Wayland 与 X11 都行)。
#
#   源码来源:
#     MacroSilicon 官方 GPL-2.0 源码的 "modern-kernel fork", 见 vendor/ms91xx/README.md。
#     我们按本项目的 7.2 内核又补了四处适配 (都带 LINUX_VERSION_CODE 条件, 不影响老内核):
#       1. drm_helper_mode_fill_fb_struct() 在 7.2 又把 info 参数加回来了
#       2. 原子钩子在 7.2 起收 struct drm_atomic_commit (以前是 drm_atomic_state)
#       3. fb_create() 同样多了一个 info 参数
#       4. __kernel_write 在本项目内核里属于 autofs4 命名空间 -> 改用 kernel_write
#
#   两个构建坑 (都已处理):
#     * 头文件 deb 里带的是 **aarch64** 的宿主工具 (fixdep/modpost), 在 x86_64 构建机上
#       跑不了 -> 认出来后删掉, 让 kbuild 用宿主 cc 重编 (headers 包里带源码)。
#       同时要伪造 .config 与 include/config/auto.conf.cmd, 否则 kbuild 会去跑 syncconfig,
#       而 headers 包没有 Kconfig, syncconfig 必失败。
#     * 生成 modpost 之后 kbuild 会因缺 scripts/dtc/Makefile 中止 —— 那是编 dtc 用的,
#       外部模块用不到, 所以只看 .ko 有没有生成, 不看 make 的整体退出码。
# ---------------------------------------------------------------------------
set -euo pipefail
source "$(dirname "$0")/lib.sh"

confirm_stage "03b 编译 MS91xx 投屏驱动"
[ -n "${SKIP_MS91XX:-}" ] && { log "SKIP_MS91XX=1, 跳过投屏驱动"; exit 0; }

KV="$(cat "$WORK/kver" 2>/dev/null || true)"
[ -n "$KV" ] || die "找不到 $WORK/kver, 请先跑 03-kernel.sh"
KDIR="$WORK/deb/headers/usr/src/linux-headers-$KV"
[ -d "$KDIR" ] || die "找不到内核头文件树: $KDIR"
SRC="$PWD/vendor/ms91xx"
[ -d "$SRC/drm" ] || die "找不到驱动源码: $SRC/drm"

# ---- 1. 让 kbuild 能在 x86_64 上跑 ----------------------------------------
removed=0
for t in scripts/sorttable scripts/selinux/mdp/mdp scripts/mod/modpost \
         scripts/kallsyms scripts/basic/fixdep scripts/asn1_compiler; do
  case "$(file -b "$KDIR/$t" 2>/dev/null || true)" in
    *ELF*aarch64*) rm -f "$KDIR/$t" 2>/dev/null || true; removed=$((removed+1)) ;;
  esac
done
[ "$removed" -gt 0 ] && log "清掉 $removed 个 aarch64 宿主工具 (构建机会自己重编)"

if [ ! -f "$KDIR/.config" ]; then
  cp "$KDIR/include/config/auto.conf" "$KDIR/.config"
  touch -d "2024-01-01" "$KDIR/.config"
fi
printf '' > "$KDIR/include/config/auto.conf.cmd"
touch "$KDIR/include/config/auto.conf" "$KDIR/include/config/auto.conf.cmd"

if [ ! -x "$KDIR/scripts/basic/fixdep" ]; then
  log "编译 fixdep"
  # 该目标会在编完脚本工具后因缺 scripts/dtc 报错, 属于预期, 忽略退出码
  make -C "$KDIR" ARCH=arm64 LLVM=1 scripts >/dev/null 2>&1 || true
fi
[ -x "$KDIR/scripts/basic/fixdep" ] || die "fixdep 没编出来, 无法继续"

# modpost: 用 headers 包自带的源码直接编 (宿主程序, 与目标架构无关)。
#   ★ 不能带 -I"$KDIR/include": 那会让内核的 linux/types.h 遮蔽系统头, 直接编挂。
#   ★ 早先的写法依赖宿主 /lib/modules/*/build 里的 modpost, 本地能用但 CI
#     (GitHub runner 没装内核头) 必挂 —— 已改成先自建、宿主只作兜底。
if [ ! -x "$KDIR/scripts/mod/modpost" ]; then
  # 宿主编译器: 本地一般是 cc, CI 的 Arch 容器只装了 clang
  MODPOST_CC="$(command -v cc || command -v clang || command -v gcc || true)"
  [ -n "$MODPOST_CC" ] || die "找不到 C 编译器 (cc / clang / gcc 都没有)"
  log "编译 modpost ($MODPOST_CC, headers 包自带源码)"
  ( cd "$KDIR/scripts/mod" && \
    "$MODPOST_CC" -O2 -o modpost modpost.c file2alias.c sumversion.c symsearch.c \
       -I. -I"$KDIR/scripts/include" ) >"$WORK/ms91xx-modpost.log" 2>&1 || true
fi
if [ ! -x "$KDIR/scripts/mod/modpost" ]; then
  HOST_MODPOST="$(ls -d /lib/modules/*/build/scripts/mod/modpost 2>/dev/null | head -1 || true)"
  if [ -n "$HOST_MODPOST" ]; then
    cp "$HOST_MODPOST" "$KDIR/scripts/mod/modpost" && chmod +x "$KDIR/scripts/mod/modpost"
    log "  自建失败, 借用宿主的 modpost ($HOST_MODPOST)"
  fi
fi
[ -x "$KDIR/scripts/mod/modpost" ] || {
  tail -5 "$WORK/ms91xx-modpost.log" 2>/dev/null >&2 || true
  die "modpost 不可用 (自建失败且宿主机没有内核构建树)"
}

# ---- 2. 编译模块 ----------------------------------------------------------
log "交叉编译 usbdisp_drm.ko (aarch64, 内核 $KV)"
# MO= 把中间产物放到 work/ 里, 别弄脏 vendor/ 下的源码树 (提交历史干净)
MO="$WORK/ms91xx-build"
rm -rf "$MO"; mkdir -p "$MO"
make -C "$KDIR" M="$SRC" MO="$MO" ARCH=arm64 LLVM=1 CONFIG_DRM_MS91XX=m modules \
     >"$WORK/ms91xx-build.log" 2>&1
KO="$MO/drm/usbdisp_drm.ko"

# ⚠️ MO= 不是所有内核版本都认。少数情况下 make 会忽略 MO=, 把产物直接写到
#   源码树 vendor/ms91xx/drm/ 下, 于是 $MO 里什么都没有, 但日志里明明有
#   "LD [M] drm/usbdisp_drm.ko"。所以找不到时再去源码树找一次,
#   找到就搬进 $MO (保持"不弄脏源码树"的约定), 再跑一次 modpost。
if [ ! -f "$KO" ] && [ -f "$SRC/drm/usbdisp_drm.ko" ]; then
  log "  make 忽略了 MO=, 从源码树取产物"
  cp -f "$SRC/drm/usbdisp_drm.ko" "$KO"
fi

# 开机自动加载: 插上 MS91xx 投屏器即可用, 不用手动 modprobe
#   (没有硬件时加载也无害, 只注册一个 DRM 驱动)
mkdir -p "$ROOT/etc/modules-load.d"
echo usbdisp_drm > "$ROOT/etc/modules-load.d/raphael-msdisp.conf"
log "  投屏: 已配置开机自动加载 usbdisp_drm"

if [ ! -f "$KO" ]; then
  tail -25 "$WORK/ms91xx-build.log" >&2 || true
  die "模块没编出来 (完整日志: $WORK/ms91xx-build.log)"
fi
log "  ✓ $(basename "$KO")  $(du -h "$KO" | cut -f1)"

# ---- 3. 装进 rootfs 并刷新模块依赖 ----------------------------------------
DEST="$ROOT/usr/lib/modules/$KV/updates/msdisp"
install -d "$DEST"
install -m 644 "$KO" "$DEST/"
# Arch 上 /lib -> usr/lib, 保证软链在 (ALARM 默认就有)
[ -e "$ROOT/lib" ] || ln -s usr/lib "$ROOT/lib"
if command -v depmod >/dev/null 2>&1; then
  if depmod -b "$ROOT" "$KV" 2>/dev/null; then
    log "  depmod 完成 (转接器插入后由 USB modalias 自动加载)"
  else
    warn "  depmod 失败, 插上转接器后可能需要手动 modprobe usbdisp_drm"
  fi
else
  warn "  构建机没有 depmod, 设备上首次启动后需要跑一次 depmod -a"
fi

log "投屏驱动就绪: 插上 USB→HDMI/VGA 转接器即可, 用 xrandr --listproviders /"
log "  gnome-randr / 系统设置里的显示器页面确认第二块屏"
