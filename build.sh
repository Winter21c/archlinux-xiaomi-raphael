#!/bin/bash
# ============================================================================
#  Raphael Arch 构建总入口
#
#  用法:
#     ./build.sh                  # 完整构建 (00 -> 10)
#     ./build.sh --from 03        # 从指定阶段开始
#     ./build.sh --only 06 07     # 只跑指定阶段
#     ./build.sh --list           # 列出阶段
#
#  说明: 全部构建在 user namespace 内完成, 不需要 root 权限。
#        原理见 README.md "构建原理" 一节。
# ============================================================================
set -euo pipefail

PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJ"

STAGES=(
  "00-fetch.sh:下载上游产物 (rootfs / 内核 deb / 固件 / U-Boot / 模板)"
  "01-rootfs.sh:解包 Arch Linux ARM rootfs 并校正权限"
  "02-pacman.sh:安装基础系统 + KDE Plasma 桌面 + Plasma Mobile"
  "03-kernel.sh:安装 raphael 定制内核 (Image + 模块 + dtb)"
  "04-firmware.sh:安装设备固件 + ALSA UCM 音频配置"
  "05-qcom.sh:构建 rmtfs / pd-mapper / tqftpserv (调制解调器与音频必需)"
  "06-config.sh:系统配置 (locale/fstab/用户/NCM 网络/电源/zram)"
  "07-desktop.sh:Plasma 桌面与 Plasma Mobile 会话配置"
  "08-initramfs.sh:生成 initramfs"
  "09-image-rootfs.sh:生成 rootfs.ext4 镜像 (含 sparse 版本)"
  "10-image-boot.sh:生成 cache 分区 FAT32 引导镜像"
)

list_stages() {
  local i=0
  for s in "${STAGES[@]}"; do
    printf '  %-22s %s\n' "${s%%:*}" "${s#*:}"
    i=$((i+1))
  done
  echo
  echo "  11-flash.sh            刷机脚本 (刷 U-Boot + 引导 + rootfs, 可选先备份)"
}

ONLY=()
FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list|-l) list_stages; exit 0 ;;
    --from) FROM="$2"; shift 2 ;;
    --only) shift; while [ $# -gt 0 ] && [[ "$1" != --* ]]; do ONLY+=("$1"); shift; done ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; list_stages; exit 1 ;;
  esac
done

should_run() {
  local n="$1"
  if [ ${#ONLY[@]} -gt 0 ]; then
    local o
    for o in "${ONLY[@]}"; do [ "$o" = "$n" ] && return 0; done
    return 1
  fi
  if [ -n "$FROM" ]; then
    [ "$n" \> "$FROM" ] || [ "$n" = "$FROM" ] && return 0
    return 1
  fi
  return 0
}

echo "=============================================================="
echo "  Xiaomi Redmi K20 Pro (raphael / SM8150) — Arch Linux ARM"
echo "  KDE Plasma 桌面 + Plasma Mobile"
echo "=============================================================="
echo

START=$(date +%s)
for s in "${STAGES[@]}"; do
  name="${s%%:*}"
  num="${name%%-*}"
  desc="${s#*:}"
  if should_run "$num"; then
    echo
    echo ">>> [$num] $desc"
    bash "scripts/$name" 2>&1 | tee -a "logs/build.log" || {
      echo
      echo "!!! 阶段 $name 失败, 详见 logs/build.log"
      exit 1
    }
  fi
done
END=$(date +%s)

echo
echo "=============================================================="
echo "  构建完成, 用时 $(( (END-START)/60 )) 分 $(( (END-START)%60 )) 秒"
echo "=============================================================="
ls -lh out/ 2>/dev/null | sed 's/^/  /'
echo
echo "下一步: ./scripts/11-flash.sh --help"
