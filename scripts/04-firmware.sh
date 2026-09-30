#!/bin/bash
# ============================================================================
#  阶段 04 — 安装 raphael 定制固件 + ALSA UCM 音频配置 + 精简无关固件
#
#  三个关键点:
#   1. 作者的设备专属固件是 .zst 压缩的, 而内核固件加载器优先尝试 "无后缀"
#      文件名 —— 必须删掉通用固件里的同名未压缩文件, 否则 Wi-Fi/蓝牙会加载到
#      通用固件而不是设备专属固件。
#   2. Adreno 640 与 630 共用 a630_sqe.fw, 内核里并不存在 a640_sqe.fw。
#   3. ALARM 基础镜像自带整套 linux-firmware (含 nvidia/amd/radeon 等 1GB 级
#      无关固件), 手机上完全用不到, 删掉可显著缩小镜像。
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount

confirm_stage "04 安装固件与音频配置"

TMP="$WORK/deb"
mkdir -p "$TMP"
unpack_deb() {
  local deb="$1" dest="$2"
  rm -rf "$dest"; mkdir -p "$dest"
  ( cd "$dest" && ar x "$deb" && tar --zstd -xf data.tar.zst && rm -f data.tar.zst control.tar.zst debian-binary )
}

# ---------------------------------------------------------------------------
# 1. 精简无关固件包 (只保留 qcom / other: 后者提供 qca 蓝牙 TLV)
# ---------------------------------------------------------------------------
# atheros 提供 WCN3990/WCN3998 蓝牙 rampatch (qca/crbtfw21.tlv) 等, 必须保留,
# 但它同时带来与设备专属固件同名的未压缩 Wi-Fi 固件, 由第 3 步删除
KEEP_FW="linux-firmware-qcom linux-firmware-atheros linux-firmware-other linux-firmware-whence linux-firmware"
PKGARGS=(--arch aarch64 -r "$ROOT" --config "$WORK/pacman-build.conf"
         --dbpath "$ROOT/var/lib/pacman" --cachedir "$WORK/pkgcache"
         --noconfirm --noscriptlet)

if [ -s "$WORK/pacman-build.conf" ]; then
  # (a) 装回被基础镜像之外误删的必要固件包 (atheros 提供蓝牙 rampatch)
  INSTALL_FW=""
  for p in $KEEP_FW; do
    if ! ls -d "$ROOT"/var/lib/pacman/local/"$p"-* >/dev/null 2>&1; then
      INSTALL_FW="$INSTALL_FW $p"
    fi
  done
  if [ -n "$INSTALL_FW" ]; then
    log "安装缺失的必要固件包:$INSTALL_FW"
    pacman "${PKGARGS[@]}" -S $INSTALL_FW >/dev/null 2>&1 || warn "  安装失败, 继续"
  fi
  # (b) 卸载无关固件包 (手机用不到, 可省 1GB 级空间)
  DROP_FW=""
  for p in $(ls "$ROOT/var/lib/pacman/local" 2>/dev/null | grep '^linux-firmware-' | sed 's/-[0-9].*//' | sort -u); do
    case " $KEEP_FW " in
      *" $p "*) ;;
      *) DROP_FW="$DROP_FW $p" ;;
    esac
  done
  if [ -n "$DROP_FW" ]; then
    log "卸载无关固件包:$DROP_FW"
    pacman "${PKGARGS[@]}" -Rdd $DROP_FW >/dev/null 2>&1 || warn "  卸载失败, 继续"
  fi
fi

# ---------------------------------------------------------------------------
# 2. 设备专属固件
# ---------------------------------------------------------------------------
log "解包 firmware-xiaomi-raphael.deb"
unpack_deb "$DL/firmware-xiaomi-raphael.deb" "$TMP/fw"

mkdir -p "$ROOT/usr/lib" "$ROOT/usr/share"
if [ -d "$TMP/fw/usr/lib/firmware" ]; then
  cp -a "$TMP/fw/usr/lib/firmware/." "$ROOT/usr/lib/firmware/"
  log "  /usr/lib/firmware: $(find "$TMP/fw/usr/lib/firmware" -type f | wc -l) 个文件"
fi
if [ -d "$TMP/fw/usr/share/qcom" ]; then
  mkdir -p "$ROOT/usr/share/qcom"
  cp -a "$TMP/fw/usr/share/qcom/." "$ROOT/usr/share/qcom/"
  log "  /usr/share/qcom: $(find "$TMP/fw/usr/share/qcom" -type f | wc -l) 个文件 (音频 acdb / 传感器)"
fi

# ---------------------------------------------------------------------------
# 3. 删除会抢先的未压缩同名固件
# ---------------------------------------------------------------------------
log "清理与设备专属固件同名的未压缩通用固件"
removed=0
while IFS= read -r -d '' z; do
  rel="${z#$TMP/fw}"                 # /usr/lib/firmware/...
  plain="$ROOT${rel%.zst}"
  if [ -f "$plain" ]; then
    rm -f "$plain" && { log "  移除抢先文件: ${plain#$ROOT}"; removed=$((removed+1)); }
  fi
done < <(find "$TMP/fw/usr/lib/firmware" -name '*.zst' -print0)
log "  共移除 $removed 个冲突文件"

# 上游 wireless-regdb 用 vendor 内核不信任的密钥签名 (REQUIRE_SIGNED_REGDB=y),
# 加载必然失败, 按上游 Debian 镜像的做法删掉, 退化为 world 域
rm -f "$ROOT"/usr/lib/firmware/regulatory.db "$ROOT"/usr/lib/firmware/regulatory.db.p7s 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. ALSA UCM
# ---------------------------------------------------------------------------
log "解包 alsa-xiaomi-raphael.deb"
unpack_deb "$DL/alsa-xiaomi-raphael.deb" "$TMP/alsa"
if [ -d "$TMP/alsa/usr/share/alsa/ucm2" ]; then
  mkdir -p "$ROOT/usr/share/alsa/ucm2"
  cp -a "$TMP/alsa/usr/share/alsa/ucm2/." "$ROOT/usr/share/alsa/ucm2/"
  log "  UCM: $(find "$TMP/alsa/usr/share/alsa/ucm2" -type f | wc -l) 个配置文件"
fi

# ---------------------------------------------------------------------------
# 5. 自检
# ---------------------------------------------------------------------------
KV="$(cat "$WORK/kver" 2>/dev/null || echo '')"
FAIL=0
check_fw() {
  if [ -e "$ROOT/usr/lib/firmware/$1" ]; then log "  ✓ $2: $1"; else warn "  ✗ 缺少 $2: $1"; FAIL=$((FAIL+1)); fi
}
check_absent() {
  if [ -e "$ROOT/usr/lib/firmware/$1" ]; then warn "  ✗ 仍存在抢先文件 $2: $1"; FAIL=$((FAIL+1)); fi
}
log "固件自检:"
check_fw "qcom/sm8150/Xiaomi/raphael/adsp.mbn"      "ADSP (音频/传感器)"
check_fw "qcom/sm8150/Xiaomi/raphael/cdsp.mbn"      "CDSP"
check_fw "qcom/sm8150/Xiaomi/raphael/modem.mbn"     "调制解调器"
check_fw "qcom/sm8150/Xiaomi/raphael/a640_zap.mbn"  "Adreno 640 zap shader"
check_fw "ath10k/WCN3990/hw1.0/firmware-5.bin.zst"  "WCN3990 Wi-Fi (设备专属)"
check_fw "qca/crnv21.bin.zst"                       "蓝牙 NVM (设备专属)"
check_fw "qca/crbtfw21.tlv"                         "蓝牙 TLV (linux-firmware-other)"
check_fw "qcom/a640_gmu.bin"                        "Adreno 640 GMU"
check_fw "qcom/a630_sqe.fw"                         "Adreno SQE (A640/A630 共用)"
check_absent "ath10k/WCN3990/hw1.0/firmware-5.bin"  "WCN3990"
check_absent "qca/crnv21.bin"                       "蓝牙 NVM"

if [ -n "$KV" ] && [ -f "$ROOT/boot/config-$KV" ]; then
  if grep -q '^CONFIG_FW_LOADER_COMPRESS_ZSTD=y' "$ROOT/boot/config-$KV"; then
    log "内核支持 zstd 压缩固件 (CONFIG_FW_LOADER_COMPRESS_ZSTD=y)"
  else
    warn "内核未启用 zstd 固件解压, 正在解压 .zst 固件"
    find "$ROOT/usr/lib/firmware" -name '*.zst' -print0 | while IFS= read -r -d '' f; do
      zstd -d --rm -q "$f" -o "${f%.zst}" 2>/dev/null || true
    done
  fi
fi

log "固件目录大小: $(du -sh "$ROOT/usr/lib/firmware" | cut -f1)"
if [ "$FAIL" -eq 0 ]; then log "固件与音频配置安装完成 (自检通过)"; else warn "固件自检有 $FAIL 项异常"; fi
