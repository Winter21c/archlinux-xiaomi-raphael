#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 08 — 生成 initramfs (手工组装, 不依赖 mkinitcpio 执行环境)
#  为什么需要: root 分区在 UFS 上, 内核已内建 ufshcd/ext4, 理论上可以不用
#  initramfs; 但保留一个极简 initramfs 可以在挂载失败时给出救援 shell,
#  也为将来做全盘加密留出接口。
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns

confirm_stage "08 生成 initramfs"
KV="$(cat "$WORK/kver" 2>/dev/null || true)"
[ -n "$KV" ] || die "缺少内核版本 (先跑 03-kernel.sh)"

IR="$WORK/initramfs"
rm -rf "$IR"
mkdir -p "$IR"/{bin,sbin,proc,sys,dev,run,tmp,newroot,usr/lib/firmware}
chmod 1777 "$IR/tmp"
# ★ /lib -> usr/lib 这个软链必须有: 内核的 firmware loader 只按 /lib/firmware
#   (以及 /lib/firmware/updates) 找文件, 不认 /usr/lib/firmware。initramfs 里少了
#   它, 下面特意塞进来的 a630_sqe.fw / a640_gmu.bin 就等于没塞 ——
#   真机 dmesg 复现:
#     [0.63s] msm_dpu: Direct firmware load for qcom/a630_sqe.fw failed with error -2
#     [10.0s] msm_dpu: [drm:adreno_request_fw] loaded qcom/a630_sqe.fw from new location
#   0.63s 那次失败会让内建 adreno/msm_dpu 在没有 SQE 固件的情况下起来, 之后屏
#   在熄屏/开机瞬间花屏 (正是之前排查很久的那个问题); 10 秒后才成功已经晚了。
ln -sfn usr/lib "$IR/lib"

# ---- 静态 busybox ---------------------------------------------------------
# /usr/bin/busybox (busybox 包, 静态链接, 392 个 applet) 才有 mount/switch_root/findfs,
# mkinitcpio-busybox 里的精简版缺少 mount 等关键 applet, 不能用于自建 initramfs。
BB="$ROOT/usr/bin/busybox"
[ -x "$BB" ] || die "找不到 /usr/bin/busybox (需要 busybox 包)"
APPETS="$(/usr/bin/qemu-aarch64 "$BB" --list 2>/dev/null || true)"
for a in mount umount switch_root findfs modprobe sh; do
  echo "$APPETS" | grep -qx "$a" || die "busybox 缺少 applet: $a"
done
log "busybox 自检通过 ($(echo "$APPETS" | wc -l) 个 applet)"
cp -f "$BB" "$IR/bin/busybox"
chmod 755 "$IR/bin/busybox"
for a in sh mount umount switch_root sleep cat echo ls mkdir mknod dmesg blkid findfs \
         modprobe lsmod grep sed awk cut tr date poweroff reboot sync test printf; do
  ln -sfn busybox "$IR/bin/$a"
done
ln -sfn ../bin/busybox "$IR/sbin/init" 2>/dev/null || true

# ---- 需要的模块 (UFS/ext4 已内建, 这里只带上可能用到的) -------------------
KDIR="$IR/usr/lib/modules/$KV"
mkdir -p "$KDIR"
copy_mod() {
  local m="$1"
  local f
  f="$(find "$ROOT/usr/lib/modules/$KV" -name "${m}.ko*" | head -1)"
  [ -n "$f" ] || return 0
  local rel="${f#$ROOT/usr/lib/modules/$KV/}"
  mkdir -p "$KDIR/$(dirname "$rel")"
  cp -f "$f" "$KDIR/$rel"
}
for m in phy-qcom-qmp-ufs ufs-qcom scsi_common ext4 crc32c_generic; do copy_mod "$m"; done
log "initramfs 模块: $(find "$KDIR" -name '*.ko*' | wc -l) 个 (UFS/ext4 已内建)"

# ---- 早期固件 (remoteproc IPA/ZAP, 很小) ----------------------------------
for f in "$ROOT/usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/a640_zap.mbn" \
         "$ROOT/usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/ipa_fws.mbn"; do
  [ -f "$f" ] || continue
  mkdir -p "$IR/usr/lib/firmware/qcom/sm8150/Xiaomi/raphael"
  cp -f "$f" "$IR/usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/"
done

# ---- ★ GPU (Adreno 640) 固件: 必须在 initramfs 里 ---------------------------
#   msm_dpu/adreno 是内建驱动, 在 0.9 秒就 probe 并 request_firmware();
#   那时只有 initramfs 可读, rootfs 还没挂 -> 找不到 a630_sqe.fw / a640_gmu.bin
#   -> GPU 3D 起不来 -> 之后每次合成器初始化都会 "06040001: hangcheck recover"
#   伴随一次花屏 (锁屏/开机时尤其明显)。真机验证: 放进 initramfs 后两条固件都
#   能加载成功 ("loaded qcom/a630_sqe.fw from new location")。
for f in a630_sqe.fw a640_gmu.bin a630_gmu.bin; do
  src="$ROOT/usr/lib/firmware/qcom/$f"
  [ -f "$src" ] || continue
  mkdir -p "$IR/usr/lib/firmware/qcom"
  cp -f "$src" "$IR/usr/lib/firmware/qcom/"
  log "  早期 GPU 固件: qcom/$f"
done
# cfg80211 也是内建, 早期就要 regulatory.db (wireless-regdb 包)
for f in regulatory.db regulatory.db.p7s; do
  [ -f "$ROOT/usr/lib/firmware/$f" ] || continue
  cp -f "$ROOT/usr/lib/firmware/$f" "$IR/usr/lib/firmware/"
done

# ---- /init ----------------------------------------------------------------
cat > "$IR/init" <<'INIT'
#!/bin/busybox sh
# raphael 极简 initramfs: 挂载根分区后 switch_root 到真实系统
export PATH=/bin:/sbin
/bin/busybox --install -s /bin 2>/dev/null

mount -t proc  proc  /proc 2>/dev/null
mount -t sysfs sysfs /sys  2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null

rescue() {
  echo
  echo "==============================================================="
  echo " 根分区挂载失败: $1"
  echo " 可用设备:"; ls -l /dev/sd* /dev/mmcblk* 2>/dev/null
  echo " 输入 'exit' 或 Ctrl-D 继续尝试启动; 输入 shell 命令可手工挂载"
  echo "==============================================================="
  setsid sh -c 'exec sh </dev/tty0 >/dev/tty0 2>&1' 2>/dev/null || sh
}

CMDLINE="$(cat /proc/cmdline)"
ROOTARG=""
for a in $CMDLINE; do
  case "$a" in
    root=*)      ROOTARG="${a#root=}" ;;
    rootfstype=*) ROOTFSTYPE="${a#rootfstype=}" ;;
    rootflags=*)  ROOTFLAGS="${a#rootflags=}" ;;
    rw)           RW=1 ;;
    ro)           RW=0 ;;
  esac
done
[ -n "$ROOTARG" ] || rescue "内核命令行没有 root="

resolve_dev() {
  case "$1" in
    UUID=*)     findfs "UUID=${1#UUID=}" 2>/dev/null ;;
    LABEL=*)    findfs "LABEL=${1#LABEL=}" 2>/dev/null ;;
    PARTUUID=*) findfs "PARTUUID=${1#PARTUUID=}" 2>/dev/null ;;
    PARTLABEL=*)
      # 内核不支持 PARTLABEL, 用 sysfs 里 udev 风格的 by-partlabel 或遍历比对
      if [ -e "/dev/disk/by-partlabel/${1#PARTLABEL=}" ]; then
        echo "/dev/disk/by-partlabel/${1#PARTLABEL=}"
      fi ;;
    *)          echo "$1" ;;
  esac
}

DEV=""
i=0
while [ $i -lt 40 ]; do
  DEV="$(resolve_dev "$ROOTARG")"
  [ -n "$DEV" ] && [ -b "$DEV" ] && break
  [ -b "$ROOTARG" ] && { DEV="$ROOTARG"; break; }
  sleep 0.25
  i=$((i+1))
done
[ -n "$DEV" ] || rescue "无法解析根设备 $ROOTARG"

OPTS="$ROOTFLAGS"
[ "${RW:-1}" = "1" ] && OPTS="$OPTS,rw" || OPTS="$OPTS,ro"
echo "挂载 $DEV -> /newroot (${ROOTFSTYPE:-自动探测}, $OPTS)"
if [ -n "$ROOTFSTYPE" ]; then
  mount -t "$ROOTFSTYPE" -o "$OPTS" "$DEV" /newroot || rescue "mount $DEV 失败"
else
  mount -o "$OPTS" "$DEV" /newroot || rescue "mount $DEV 失败"
fi

[ -x /newroot/sbin/init ] || [ -x /newroot/usr/lib/systemd/systemd ] || rescue "根分区里没有 init"

mount --move /proc /newroot/proc
mount --move /sys  /newroot/sys
mount --move /dev  /newroot/dev
exec switch_root /newroot /sbin/init
INIT
chmod 755 "$IR/init"

# ---- 打包 (zstd) ----------------------------------------------------------
log "打包 initramfs"
( cd "$IR" && find . -print0 | cpio --null -o --format=newc --owner=0:0 2>/dev/null | zstd -19 -T0 -q -f -o "$WORK/initramfs.img" )
ls -lh "$WORK/initramfs.img" | awk '{print "  initramfs.img:", $5}'

# ---- 同步到 rootfs (备份用) ----------------------------------------------
mkdir -p "$ROOT/boot"
cp -f "$WORK/initramfs.img" "$ROOT/boot/initramfs-raphael.img"
log "initramfs 完成"
