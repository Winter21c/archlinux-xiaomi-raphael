#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  蓝牙地址小工具 —— 给"从 GitHub 下载来的引导镜像"补上本机地址
#
#  为什么需要它: 蓝牙地址是**每台设备唯一**的, 产线写在设备自己的 dtbo 分区里,
#  而刷机会把 dtbo 清掉; 所以公开镜像里不可能带某个人的地址。
#  没有地址时内核会因为"控制器上报全零 BD_ADDR"直接把蓝牙关掉 (见 README §8.9)。
#
#  用法:
#     ./scripts/bt-mac.sh show <boot-cache.img>          # 看镜像里现在是什么
#     ./scripts/bt-mac.sh set  <boot-cache.img> <地址>    # 写进去 (原地修改, 先备份)
#
#  地址写法 = **设备树字节序** (小端), 与设备原厂 DTB 一致, 例如
#     11 22 33 44 55 66      <->  系统里 bluetoothctl 显示为 66:55:44:33:22:11
#  也就是说: 如果你手上只有屏幕上显示的地址, 把它反着写。
#  冒号/连字符/空格/大小写都无所谓, 只要求正好 12 位十六进制。
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '5,20p' "$0"; exit 1; }
[ $# -ge 2 ] || usage
CMD="$1"; IMG="$2"
[ -f "$IMG" ] || die "找不到镜像: $IMG"

show_mac() {
  export MTOOLS_SKIP_CHECK=1 MTOOLSRC=/dev/null
  local tmp; tmp="$(mktemp -d)"
  mrun mcopy -o -i "$IMG" "::/dtbs/qcom/raphael-redmi-k20pro.dtb" "$tmp/dtb" 2>/dev/null \
    || { rm -rf "$tmp"; die "从镜像里取不出设备树 (不是本项目的引导镜像?)"; }
  local raw
  raw="$(fdtget "$tmp/dtb" "$BT_DT_NODE" local-bd-address 2>/dev/null || true)"
  rm -rf "$tmp"
  if [ -z "$raw" ]; then
    echo "镜像里没有蓝牙地址 (蓝牙会不可用)"
    return 0
  fi
  local hex visible
  hex="$(printf '%s' "$raw" | awk '{for(i=1;i<=NF;i++) printf "%02x", $i}')"
  visible="$(printf '%s' "$hex" | sed 's/../&:/g; s/:$//' | awk -F: '{for(i=NF;i>0;i--) printf "%s%s", $i, (i>1?":":"\n")}')"
  echo "设备树: $raw"
  echo "系统里显示为: $visible"
}

case "$CMD" in
  show) show_mac ;;
  set)
    [ $# -ge 3 ] || usage
    MAC_NORM="$(normalize_bt_mac "$3")" || die "地址格式不对: '$3' (需要 12 位十六进制)"
    cp -f "$IMG" "$IMG.bak"
    inject_bt_mac_into_boot_img "$IMG" "$MAC_NORM" || die "写入失败"
    log "已写入 $IMG (原文件备份为 $IMG.bak)"
    IMG="$IMG" show_mac
    ;;
  *) usage ;;
esac
