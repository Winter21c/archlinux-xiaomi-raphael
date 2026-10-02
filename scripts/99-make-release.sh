#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 99 — 把 out/ 里的产物打包成可发布的形式
#
#  GitHub Release 单个 asset 上限 2 GB, 而 rootfs 镜像有 6 GB 左右,
#  所以这里用 zstd 压缩 + 自动分卷, 并生成:
#    release/SHA256SUMS       全部文件校验和
#    release/刷机说明.txt      下载后怎么合并 + 怎么刷
#    release/upload.sh        直接发布到当前仓库 Release 的命令
#
#  用法:
#     ./scripts/99-make-release.sh [版本号]     # 默认 v1.0.0
#     ./scripts/99-make-release.sh v1.0.0 --upload   # 打包完直接上传
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TAG="${1:-v1.0.0}"
DO_UPLOAD=0
[ "${2:-}" = "--upload" ] && DO_UPLOAD=1

REL="$PROJ/release"
PART_SIZE="1900M"          # 单卷上限 (留出余量, GitHub 限制 2GB)
# 压缩级别: 本地出正式版用 19 (最小), CI/快速验证可用 RAPHAEL_RELEASE_ZSTD_LEVEL=6
# (6.9GB 镜像在 4 核 runner 上: -19 要 30 分钟以上, -6 只要几分钟)
ZSTD_LEVEL="${RAPHAEL_RELEASE_ZSTD_LEVEL:-19}"
mkdir -p "$REL"
rm -f "$REL"/*

confirm_stage "99 打包发布文件 ($TAG, zstd -$ZSTD_LEVEL)"

# ---------------------------------------------------------------------------
# 1. 收集产物
# ---------------------------------------------------------------------------
declare -a FILES=()
[ -s "$OUT/rootfs.sparse.img" ] && FILES+=("$OUT/rootfs.sparse.img") \
  || { [ -s "$OUT/rootfs.img" ] && FILES+=("$OUT/rootfs.img"); }
[ -s "$OUT/boot-cache.img" ] && FILES+=("$OUT/boot-cache.img")
[ -s "$WORK/uboot/u-boot.img" ] && FILES+=("$WORK/uboot/u-boot.img")
[ ${#FILES[@]} -gt 0 ] || die "out/ 里没有产物, 先跑 build.sh"

# ---------------------------------------------------------------------------
# 2. 压缩 + 分卷
# ---------------------------------------------------------------------------
log "压缩并分卷 (单卷上限 $PART_SIZE)"
for f in "${FILES[@]}"; do
  base="$(basename "$f")"
  log "  $base ($(du -h "$f" | cut -f1))"
  if [[ "$base" == *.img ]] && [ "$(stat -c %s "$f")" -gt 100000000 ]; then
    zstd -"$ZSTD_LEVEL" -T0 -q -f -o "$REL/$base.zst" "$f"
    if [ "$(stat -c %s "$REL/$base.zst")" -gt $((1900*1024*1024)) ]; then
      split -b "$PART_SIZE" -d -a 2 "$REL/$base.zst" "$REL/$base.zst.part"
      rm -f "$REL/$base.zst"
      log "    -> $(ls "$REL/$base.zst.part"* | wc -l) 个分卷"
    else
      log "    -> $(du -h "$REL/$base.zst" | cut -f1)"
    fi
  else
    cp -f "$f" "$REL/$base"
  fi
done

# ---------------------------------------------------------------------------
# 3. 校验和 + 说明
# ---------------------------------------------------------------------------
( cd "$REL" && sha256sum * > SHA256SUMS )
log "校验和: release/SHA256SUMS"

cat > "$REL/刷机说明.txt" <<EOF
Xiaomi Redmi K20 Pro (raphael / SM8150) — Arch Linux ARM + KDE Plasma Mobile
版本: $TAG
生成时间: $(date -Iseconds)

【文件说明】
  rootfs.sparse.img.zst*   Arch 根文件系统 (ext4, sparse)  -> 刷入 userdata 分区
  boot-cache.img           systemd-boot + 内核 + initramfs -> 刷入 cache 分区
  u-boot.img               U-Boot 引导                     -> 刷入 boot 分区
  SHA256SUMS               校验和 (先校验再刷!)

【第 1 步: 校验】
  sha256sum -c SHA256SUMS

【第 2 步: 合并分卷 (如果有 .part00/.part01...)】
  cat rootfs.sparse.img.zst.part* > rootfs.sparse.img.zst
  zstd -d rootfs.sparse.img.zst          # 得到 rootfs.sparse.img

【第 3 步: 刷机】手机进 fastboot (关机后按住 音量- + 电源)
  fastboot erase dtbo
  fastboot erase boot
  fastboot erase cache
  fastboot erase userdata
  fastboot flash boot     u-boot.img
  fastboot flash cache    boot-cache.img
  fastboot flash userdata rootfs.sparse.img
  fastboot reboot

【第 4 步: 首次开机】
  自动登录 Plasma Mobile, 用户 $USERNAME / 密码 (构建时设定, 默认 1234), root 密码 (同上)
  首启动会自动扩容根分区、初始化 pacman 密钥环, 请耐心等 1-2 分钟
  ⚠ 请立刻修改默认密码: passwd && sudo passwd root

【注意】
  * 会清空手机数据, 刷机前请备份
  * 需要 bootloader 已解锁
  * 完整文档与自行构建方法见仓库 README.md
EOF

cat > "$REL/upload.sh" <<EOF
#!/bin/bash
# 发布到 GitHub Release (需要已登录的 gh CLI)
set -e
cd "\$(dirname "\$0")"
gh release create "$TAG" \\
  --title "Arch Linux ARM for Redmi K20 Pro $TAG" \\
  --notes-file 刷机说明.txt \\
  \$(ls | grep -vE '^(upload.sh|刷机说明.txt)\$')
EOF
chmod +x "$REL/upload.sh"

log "打包结果:"
ls -lh "$REL" | tail -n +2 | sed 's/^/    /'

if [ "$DO_UPLOAD" = 1 ]; then
  log "上传到 Release $TAG ..."
  ( cd "$REL" && ./upload.sh )
  log "已发布: $(gh repo view --json url -q .url)/releases/tag/$TAG"
else
  log "如需上传: cd release && ./upload.sh"
fi
