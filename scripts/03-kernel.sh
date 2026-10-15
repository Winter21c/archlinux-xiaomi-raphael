#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 03 — 安装 raphael 定制内核 (作者预编译) + 设备树
#  源: GengWei1997/kernel-deb 的 linux-image/headers deb
#  目标布局 (Arch 约定):
#     /usr/lib/modules/<kver>/            内核模块
#     /boot/vmlinuz-<kver>                内核 Image (EFI stub) 暂存, 最终进 FAT
#     /usr/lib/modules/<kver>/dtbs/qcom/  设备树副本 (rootfs 内)
#     (FAT 分区的装载见阶段 10)
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount

confirm_stage "03 安装定制内核 $KERNEL_VERSION"

TMP="$WORK/deb"
rm -rf "$TMP" && mkdir -p "$TMP"/{image,headers}

unpack_deb() {  # unpack_deb <deb> <destdir>
  local deb="$1" dest="$2"
  ( cd "$dest" && ar x "$deb" && tar --zstd -xf data.tar.zst && rm -f data.tar.zst control.tar.zst debian-binary )
}

log "解包 linux-image deb"
unpack_deb "$DL/linux-image-xiaomi-raphael.deb" "$TMP/image"
log "解包 linux-headers deb"
unpack_deb "$DL/linux-headers-xiaomi-raphael.deb" "$TMP/headers"

KV="$(ls "$TMP/image/lib/modules" | head -1)"
[ -n "$KV" ] || die "找不到内核模块目录"
log "内核版本: $KV"

# ---- 清理上次残留 ----------------------------------------------------------
# ★ 上游换内核版本时 (例如 g29662fdcefa9 -> ga1573649db08) 这里必须显式清理:
#   下面的 cp 只覆盖同名目录, 增量构建会把上一版内核的模块 (200 多兆) 和
#   /boot 下的 vmlinuz/config/System.map 一起留在镜像里。
for _d in "$ROOT"/usr/lib/modules/*/; do
  [ -d "$_d" ] || continue
  _v="$(basename "$_d")"
  [ "$_v" = "$KV" ] && continue
  log "  清理上一版内核模块: $_v"
  rm -rf "$_d"
done
for _d in "$ROOT"/usr/src/linux-headers-*/; do
  [ -d "$_d" ] || continue
  _v="$(basename "$_d")"
  [ "$_v" = "linux-headers-$KV" ] && continue
  log "  清理上一版内核头文件: $_v"
  rm -rf "$_d"
done
rm -f "$ROOT"/boot/vmlinuz-* "$ROOT"/boot/config-* "$ROOT"/boot/System.map-*

# ---- 模块 -----------------------------------------------------------------
rm -rf "$ROOT/usr/lib/modules/$KV"
mkdir -p "$ROOT/usr/lib/modules"
cp -a "$TMP/image/lib/modules/$KV" "$ROOT/usr/lib/modules/"
# Debian 把 modules.*.bin 里的路径写成 /lib/modules, Arch 上 /lib -> usr/lib 软链
# 保证该软链存在 (ALARM 默认就有)
[ -e "$ROOT/lib" ] || ln -s usr/lib "$ROOT/lib"

# ---- 内核 Image -----------------------------------------------------------
VMLINUZ="$(ls "$TMP/image/boot"/vmlinuz-* 2>/dev/null | head -1)"
[ -n "$VMLINUZ" ] || die "deb 内找不到 vmlinuz"
mkdir -p "$ROOT/boot"
cp -f "$VMLINUZ" "$ROOT/boot/Image"
cp -f "$VMLINUZ" "$ROOT/boot/vmlinuz-$KV"
cp -f "$TMP/image/boot/config-$KV" "$ROOT/boot/config-$KV" 2>/dev/null || true
cp -f "$TMP/image/boot/System.map-$KV" "$ROOT/boot/System.map-$KV" 2>/dev/null || true

# ---- 设备树 ---------------------------------------------------------------
# ★ 上游 deb 换过打包布局, 两种都要认 (2026-10-11 修: 新布局导致 CI 挂在
#   "缺少 sm8150-xiaomi-raphael.dtb"):
#     老: boot/dtbs/qcom/*.dtb                       (只有 qcom 相关的少量 dtb)
#     新: usr/lib/linux-image-<kver>/qcom/*.dtb      (通用多平台内核, qcom 有 42M)
#   新布局只挑 sm8150-*.dtb (11 个, 1.1M) —— 全拷会把引导镜像撑大 40 多兆,
#   而本项目只用得上同 SoC 家族这几块。
mkdir -p "$ROOT/usr/lib/modules/$KV/dtbs/qcom"
dtb_src=""
for d in "$TMP/image/boot/dtbs/qcom" \
         "$TMP/image/usr/lib/linux-image-$KV/qcom"; do
  [ -d "$d" ] && { dtb_src="$d"; break; }
done
if [ -z "$dtb_src" ]; then
  # 版本目录名万一再变, 用 glob 兜一把
  dtb_src="$(ls -d "$TMP/image"/usr/lib/linux-image-*/qcom 2>/dev/null | head -1 || true)"
fi
[ -n "$dtb_src" ] || die "内核 deb 里找不到 qcom 设备树目录 (打包布局又变了? 见 03-kernel.sh 注释)"
if ls "$dtb_src"/sm8150-*.dtb >/dev/null 2>&1; then
  cp -f "$dtb_src"/sm8150-*.dtb "$ROOT/usr/lib/modules/$KV/dtbs/qcom/" 2>/dev/null || true
else
  cp -f "$dtb_src"/*.dtb "$ROOT/usr/lib/modules/$KV/dtbs/qcom/" 2>/dev/null || true
fi
raph_dtb="$ROOT/usr/lib/modules/$KV/dtbs/qcom/sm8150-xiaomi-raphael.dtb"
[ -f "$raph_dtb" ] || die "缺少 sm8150-xiaomi-raphael.dtb (来源目录: ${dtb_src#$TMP/image/})"

# ---- ★ 补采集音频路由 (2026-10-15 真机定位, 麦克风的前提) -------------------
# 上游 DTB 的 sound 节点 audio-routing 只有播放/偏置相关:
#     "RX_BIAS","MCLK","AMIC1","MIC BIAS3","AMIC3","MIC BIAS4"
# 没有任何 SLIMBUS_0_TX 路由。于是 q6routing_stream_open() 按 DAPM 找不到 TX 端口,
# arecord 直接返回 EINVAL (实测: hw:0,0/hw:0,1 都是 "Invalid argument")。
# slimcap-dai-link (cpu=<0xff 0x03> = SLIMBUS_0_TX) 本身是存在的, 只是没连线。
#
# 补丁: 追加 "SLIMBUS_0_TX","AIF1 CAP" (wcd934x 的 SND_SOC_DAPM_AIF_OUT_E)。
#   实测必须**只加这一条** —— 如果再写 "AIF1 CAP","SLIM TX0" / "SLIM TX0","DEC0"
#   (那是 codec 内部路由, 由 mixer 控制), machine driver 的
#   snd_soc_dapm_add_routes() 找不到该 widget, probe 直接失败:
#   lsmod 里有 snd_soc_sm8150, 但 /proc/asound/cards 是 "--- no soundcards ---"
#   -> 全系统没声音。已实测踩过, 别加。
# patch_sound_routing 已移到 scripts/lib.sh —— 阶段 10 也要用它
# (阶段 10 才决定**真正被引导**的那份 DTB, 只在这里补丁会漏掉启动用的那份)
patch_sound_routing "$raph_dtb"

log "设备树: $(ls "$ROOT/usr/lib/modules/$KV/dtbs/qcom" | wc -l) 个 dtb (含 raphael, 来自 ${dtb_src#$TMP/image/})"

# ---- 头文件 (供用户后续自行编译模块) --------------------------------------
if [ -d "$TMP/headers/usr/src" ]; then
  mkdir -p "$ROOT/usr/src"
  cp -a "$TMP/headers/usr/src/." "$ROOT/usr/src/"
  # Arch 上内核头文件约定在 /usr/lib/modules/<kver>/build
  if [ -d "$ROOT/usr/src/linux-headers-$KV" ] && [ ! -e "$ROOT/usr/lib/modules/$KV/build" ]; then
    ln -sfn "/usr/src/linux-headers-$KV" "$ROOT/usr/lib/modules/$KV/build"
  fi
fi

# ---- 依赖关系 (用宿主 depmod, 与架构无关) ---------------------------------
if command -v depmod >/dev/null; then
  log "重建 modules.dep"
  depmod -b "$ROOT" -a "$KV" 2>/dev/null || warn "depmod 失败 (沿用 deb 内自带的 modules.dep)"
fi

echo "$KV" > "$WORK/kver"
log "内核安装完成: $KV"
log "  模块数: $(find "$ROOT/usr/lib/modules/$KV" -name '*.ko*' | wc -l)"
log "  Image : $(du -h "$ROOT/boot/Image" | cut -f1)"
