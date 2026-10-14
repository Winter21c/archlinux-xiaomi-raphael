#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 06 — 系统基础配置
#  (对照上游 Debian 构建的 scripts/04,07,08,10,11,12,13,14,15,16 逐条移植)
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount
setup_qemu_shim

confirm_stage "06 系统基础配置"
KV="$(cat "$WORK/kver" 2>/dev/null || true)"

# 工具: 生成密码哈希 (sha512-crypt)
hash_pw() {
  local pw="$1" salt
  salt="$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  openssl passwd -6 -salt "$salt" "$pw"
}
# openssl 6 号算法自检
hash_pw test | grep -q '^\$6\$' || die "无法生成 sha512 密码哈希 (需要 openssl passwd -6)"
log "密码哈希生成器自检通过"

# ---------------------------------------------------------------------------
# 1. systemd 单元启停 (chroot 内用 qemu 跑 systemctl --root)
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 2. 主机名 / hosts / locale / 时区 / 键盘
# ---------------------------------------------------------------------------
log "配置主机名与基础系统文件"
echo "$HOSTNAME" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1        localhost
::1              localhost
127.0.1.1        $HOSTNAME.localdomain $HOSTNAME
EOF

sed -i -e "s/^#\?$LOCALE/$LOCALE/" "$ROOT/etc/locale.gen"
grep -q "^$LOCALE" "$ROOT/etc/locale.gen" || echo "$LOCALE UTF-8" >> "$ROOT/etc/locale.gen"
grep -q '^en_US.UTF-8' "$ROOT/etc/locale.gen" || echo "en_US.UTF-8 UTF-8" >> "$ROOT/etc/locale.gen"
cat > "$ROOT/etc/locale.conf" <<EOF
LANG=$LOCALE
LC_MESSAGES=$LOCALE
EOF
echo "KEYMAP=$KEYMAP" > "$ROOT/etc/vconsole.conf"
echo "FONT=LatArCyrHeb-16" >> "$ROOT/etc/vconsole.conf"
ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$ROOT/etc/localtime"
echo "$TIMEZONE" > "$ROOT/etc/timezone"
log "生成 locale"
gq /usr/bin/bash /usr/bin/locale-gen >/dev/null 2>&1 && log "  locale-gen 完成" || warn "  locale-gen 失败 (首次开机可手动执行)"

# ---------------------------------------------------------------------------
# 3. fstab (对上上游脚本 11: root 用 PARTLABEL + 首启动自动扩容)
# ---------------------------------------------------------------------------
# fstab: 布局由 lib.sh 的 rootfs_layout() 统一决定 (与 09 镜像 / 10 引导参数一致)
#   btrfs-subvol : @ 挂 / , @home 挂 /home (参考 Shorin 指南)
#   btrfs-flat   : 单子卷 btrfs, 数据在顶层 (无 root 构建时的退路)
#   ext4         : 传统布局
# 都用 UUID 定位根 / PARTLABEL 定位 /boot (镜像里就是这个分区标签), 首启动 x-systemd.growfs 扩容
# ---------------------------------------------------------------------------
ROOTFS_LAYOUT="$(rootfs_layout)"
ROOTFS_UUID="$(rootfs_uuid)"
log "写 /etc/fstab (布局: $ROOTFS_LAYOUT, root UUID=$ROOTFS_UUID)"
# 真正干活的是 lib.sh 的 write_root_fstab(): 09 阶段在实际确定布局后会再调一次,
# 以防"缓存说 subvol 但实际回退成 flat"导致 fstab 与镜像不一致 (见 lib.sh 注释)。
write_root_fstab "$ROOTFS_LAYOUT" "$ROOTFS_UUID"
log "  $(grep -c . "$ROOT/etc/fstab") 行:"; sed 's/^/    /' "$ROOT/etc/fstab"
if [ ! -e "$ROOT/usr/lib/systemd/system/systemd-growfs@.service" ]; then
  warn "systemd 未提供 systemd-growfs@, 改用自建扩容服务"
  # 按布局选扩容工具: btrfs 用 btrfs filesystem resize, ext4 用 resize2fs
  cat > "$ROOT/usr/local/sbin/raphael-growfs.sh" <<'GROWEOF'
#!/bin/bash
# 首启动把根文件系统撑满 userdata 分区 (systemd-growfs@ 不可用时的兜底)
set -e
dev=/dev/disk/by-partlabel/userdata
[ -b "$dev" ] || exit 0
fstype=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
case "$fstype" in
  btrfs) command -v btrfs >/dev/null && btrfs filesystem resize max / ;;
  ext4|ext3|ext2) resize2fs -f "$dev" ;;
  *) exit 0 ;;
esac
GROWEOF
  chmod 755 "$ROOT/usr/local/sbin/raphael-growfs.sh"
  cat > "$ROOT/etc/systemd/system/raphael-growfs.service" <<'EOF'
[Unit]
Description=Grow root filesystem to fill userdata partition
DefaultDependencies=no
After=local-fs.target
Requires=local-fs.target
Before=sysinit.target shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-growfs.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  enable_unit raphael-growfs.service
fi

# ---------------------------------------------------------------------------
# 4. 账户 (上游脚本 12)
# ---------------------------------------------------------------------------
log "创建用户 $USERNAME 与 root 密码"
if ! grep -q "^$USERNAME:" "$ROOT/etc/passwd"; then
  UID_N=1000
  while grep -q ":$UID_N:" "$ROOT/etc/passwd"; do UID_N=$((UID_N+1)); done
  HOME_DIR="/home/$USERNAME"
  echo "$USERNAME:x:$UID_N:$UID_N::$HOME_DIR:/bin/bash" >> "$ROOT/etc/passwd"
  echo "$USERNAME:$(hash_pw "$USER_PASSWORD"):$(( $(date +%s) / 86400 )):0:99999:7:::" >> "$ROOT/etc/shadow"
  echo "$USERNAME:x:$UID_N:" >> "$ROOT/etc/group"
  echo "$USERNAME:!::" >> "$ROOT/etc/gshadow"
  for g in wheel video audio input storage power rfkill network lp; do
    if grep -q "^$g:" "$ROOT/etc/group"; then
      awk -F: -v g="$g" -v u="$USERNAME" 'BEGIN{OFS=":"}
        $1==g { if ($4=="") $4=u; else if ($4 !~ ("(^|,)" u "(,|$)")) $4=$4","u }
        { print }' "$ROOT/etc/group" > "$ROOT/etc/group.new"
      mv "$ROOT/etc/group.new" "$ROOT/etc/group"
    fi
  done
  mkdir -p "$ROOT$HOME_DIR"
  cp -a "$ROOT/etc/skel/." "$ROOT$HOME_DIR/" 2>/dev/null || true
  mkdir -p "$ROOT$HOME_DIR"/{Desktop,Documents,Downloads,Pictures,Music,Videos}
  chmod 700 "$ROOT$HOME_DIR"
  log "  已创建 $USERNAME (uid $UID_N, 组: wheel video audio input storage power rfkill)"
fi

# 密码: 每次都重设 (幂等), 这样改 build.conf 后重跑本阶段即可生效
# 默认 1234: 锁屏是数字键盘, 4 位 PIN 才按得出来
if grep -q "^$USERNAME:" "$ROOT/etc/passwd"; then
  sed -i "s|^$USERNAME:[^:]*:|$USERNAME:$(hash_pw "$USER_PASSWORD"):|" "$ROOT/etc/shadow"
fi
sed -i "s|^root:[^:]*:|root:$(hash_pw "$ROOT_PASSWORD"):|" "$ROOT/etc/shadow"
mkdir -p "$ROOT/etc/sudoers.d"
echo '%wheel ALL=(ALL:ALL) ALL' > "$ROOT/etc/sudoers.d/00-wheel"
chmod 440 "$ROOT/etc/sudoers.d/00-wheel"

# ---------------------------------------------------------------------------
# 5. SSH
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/etc/ssh/sshd_config.d"
cat > "$ROOT/etc/ssh/sshd_config.d/10-raphael.conf" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
X11Forwarding no
EOF
enable_unit sshd.service

# ---------------------------------------------------------------------------
# 6. 网络 (NetworkManager + Wi-Fi 省电关闭 + 上游脚本 13/15 的 ath10k 参数)
# ---------------------------------------------------------------------------
log "配置 NetworkManager 与 Wi-Fi"
mkdir -p "$ROOT/etc/NetworkManager/conf.d"
cat > "$ROOT/etc/NetworkManager/conf.d/wifi-powersave.conf" <<'EOF'
[connection]
wifi.powersave = 2
EOF
cat > "$ROOT/etc/NetworkManager/conf.d/00-raphael.conf" <<'EOF'
[main]
dns=default
# 自己写 /etc/resolv.conf: systemd-resolved 已被禁用, 不能让 resolv.conf 继续
# 是指向 /run/systemd/resolve/stub-resolv.conf 的软链 (那样会彻底没有 DNS)
rc-manager=file

[device]
wifi.scan-rand-mac-address=no
EOF
# 清掉发行版的 systemd-resolved 桩软链, 写一个兜底 DNS (联网后 NM 会重写)
rm -f "$ROOT/etc/resolv.conf"
printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' > "$ROOT/etc/resolv.conf"
chmod 644 "$ROOT/etc/resolv.conf"
mkdir -p "$ROOT/etc/modprobe.d"
cat > "$ROOT/etc/modprobe.d/ath10k.conf" <<'EOF'
# WCN3990 需要从设备分区读取校准数据, 跳过 OTP 校验 (上游 Debian 构建同款参数)
options ath10k_core skip_otp=y
EOF
cat > "$ROOT/etc/modprobe.d/blacklist-raphael.conf" <<'EOF'
# rmtfs/pd-mapper 未就绪时不要让 remoteproc 抢跑
softdep qcom_q6v5_pas pre: rmtfs

EOF
# Arch 的 dnsmasq 默认不读取 /etc/dnsmasq.d, 必须显式打开
touch "$ROOT/etc/dnsmasq.conf"
if ! grep -q '^conf-dir=/etc/dnsmasq.d' "$ROOT/etc/dnsmasq.conf"; then
  echo 'conf-dir=/etc/dnsmasq.d/,*.conf' >> "$ROOT/etc/dnsmasq.conf"
fi

# ---------------------------------------------------------------------------
# 6b. ★ pd-mapper 必须开机自启 (2026-10-01 真机排查出来的)
#     pd-mapper 是 ADSP/CDSP 的 servreg "服务注册" 守护进程 (qcom_pd_mapper 内核
#     模块的用户态对端)。它没跑的时候:
#       qcom,slim-ngd-ctrl: QMI wait timeout     <- SLIMbus 控制器握手 ADSP 超时
#       WCD9340 codec 不出现 (/sys/bus/slimbus/devices 空)
#       声卡 "SLIM Capture 1: codec dai not found" -> 一直 EPROBE_DEFER
#       -> aplay -l 没有 card 0, PipeWire 只剩 auto_null, 完全没声音
#     rmtfs/tqftpserv 的包自带 enable, 但 pd-mapper 的 unit 默认是 disabled,
#     所以必须在这里显式打开。
# ---------------------------------------------------------------------------
for u in pd-mapper.service rmtfs.service tqftpserv.service; do
  if [ -e "$ROOT/usr/lib/systemd/system/$u" ]; then
    enable_unit "$u"
  else
    warn "找不到 $u 的 unit (音频/调制解调器可能起不来)"
  fi
done
# ALARM 基础镜像默认启用 systemd-networkd + systemd-resolved, 会和
# NetworkManager 抢网卡/DNS, 必须关掉
#   wait-online 也要一起关: 它只是"等 networkd 上线", networkd 都禁掉了它必然
#   超时失败 —— 真机上表现为每次开机一个 failed 单元 (systemd-networkd-wait-online)。
for u in systemd-networkd.service systemd-networkd.socket \
         systemd-networkd-resolve-hook.socket systemd-networkd-varlink.socket \
         systemd-networkd-varlink-metrics.socket systemd-networkd-wait-online.service \
         systemd-resolved.service \
         systemd-resolved-monitor.socket systemd-resolved-varlink.socket; do
  if [ -e "$ROOT/usr/lib/systemd/system/$u" ]; then
    gq /usr/bin/systemctl --root=/ disable "$u" >/dev/null 2>&1 || true
    rm -f "$ROOT/etc/systemd/system"/*.wants/"$u"
    # ★ 光 disable 不够稳: tarball 里这些单元是"已 enable"状态, 而 enable 只是一堆
    #   *.wants 软链 —— 一旦有别的步骤重新应用 preset, 它们就会回来 (2026-10-02 CI 上
    #   就出现过: 日志明明打了 disable, 镜像里 9 个软链却还在, mtime 还是 tarball 的)。
    #   mask 是"软链到 /dev/null", 优先级高于任何 enable/preset, 用它兜底。
    mask_unit "$u"
    log "  disable + mask: $u (改用 NetworkManager)"
  fi
done
# 兜底复查: 把任何残留的 networkd/resolved wants 软链找出来 (并删掉), 让问题在日志里可见
LEFTOVER="$(find "$ROOT/etc/systemd/system" -path '*.wants/*' \( -name 'systemd-networkd*' -o -name 'systemd-resolved*' \) 2>/dev/null || true)"
if [ -n "$LEFTOVER" ]; then
  warn "  仍有 networkd/resolved 的 enable 软链, 已删除:"
  printf '%s\n' "$LEFTOVER" | sed 's/^/    /' | while read -r l; do echo "$l"; done
  printf '%s\n' "$LEFTOVER" | while read -r f; do rm -f "$f"; done
fi
enable_unit NetworkManager.service

# ---------------------------------------------------------------------------
# 7. USB NCM 网络共享 (上游脚本 10, 原样移植; 电脑直连设备 172.16.42.1)
# ---------------------------------------------------------------------------
log "配置 USB NCM 网络共享"
mkdir -p "$ROOT/etc/dnsmasq.d" "$ROOT/usr/local/sbin"
cat > "$ROOT/etc/dnsmasq.d/usb-ncm.conf" <<'EOF'
interface=usb0
bind-dynamic
port=0
dhcp-authoritative
dhcp-range=172.16.42.2,172.16.42.254,255.255.255.0,1h
dhcp-option=3,172.16.42.1
EOF
cat > "$ROOT/usr/local/sbin/setup-usb-ncm.sh" <<'EOF'
#!/bin/sh
# USB CDC-NCM 网络共享: 电脑通过 USB 直连设备 (设备 IP 172.16.42.1)
# ★ dwc3-qcom 的 UDC 比 multi-user 晚很多才出现, 不等它 gadget 就绑不上 ->
#   表现就是"USB CDCNCM Gadget networking 启动失败" + 电脑完全看不到设备(SSH 也没了)
set -e
modprobe libcomposite 2>/dev/null || true
grep -q ' /sys/kernel/config ' /proc/mounts || mount -t configfs none /sys/kernel/config
G=/sys/kernel/config/usb_gadget/g1
mkdir -p $G
echo 0x1d6b > $G/idVendor
echo 0x0104 > $G/idProduct
echo 0x0200 > $G/bcdUSB
mkdir -p $G/strings/0x409
echo raphael > $G/strings/0x409/manufacturer
echo "Arch Linux ARM" > $G/strings/0x409/product
echo "$(cat /etc/machine-id 2>/dev/null || echo raphael0001)" > $G/strings/0x409/serialnumber
mkdir -p $G/configs/c.1/strings/0x409
echo NCM > $G/configs/c.1/strings/0x409/configuration
mkdir -p $G/functions/ncm.usb0
ln -sfn $G/functions/ncm.usb0 $G/configs/c.1/

# 等 UDC 就绪 (最多 180 秒)
i=0; UDC=""
while [ $i -lt 90 ]; do
  UDC="$(ls /sys/class/udc 2>/dev/null | head -n 1)"
  [ -n "$UDC" ] && break
  i=$((i+1)); sleep 2
done
[ -n "$UDC" ] || { echo "setup-usb-ncm: UDC 一直没出现, 放弃"; exit 1; }
echo "setup-usb-ncm: 绑定 UDC $UDC (等待 $((i*2)) 秒)"
echo "$UDC" > $G/UDC

# 等网卡出现
i=0
while [ ! -d /sys/class/net/usb0 ] && [ $i -lt 30 ]; do i=$((i+1)); sleep 1; done
[ -d /sys/class/net/usb0 ] || { echo "setup-usb-ncm: usb0 没出现"; exit 1; }
ip link set usb0 up
ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
systemctl restart dnsmasq 2>/dev/null || true
echo "setup-usb-ncm: 完成 (usb0 = 172.16.42.1)"
EOF
chmod 755 "$ROOT/usr/local/sbin/setup-usb-ncm.sh"
cat > "$ROOT/etc/systemd/system/usb-ncm.service" <<'EOF'
[Unit]
Description=USB CDC-NCM gadget networking
After=sysinit.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-usb-ncm.sh
RemainAfterExit=yes
# UDC 来得太晚 / 绑定时出错就重试, 别让 USB 网络一直不通
Restart=on-failure
RestartSec=8

[Install]
WantedBy=multi-user.target
EOF
enable_unit usb-ncm.service

# ---------------------------------------------------------------------------
# 8. zram (上游脚本 15: zstd, 10GB)
# ---------------------------------------------------------------------------
log "配置 zram 交换"
cat > "$ROOT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = 10240
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

# ---------------------------------------------------------------------------
# 9. 电源管理 (上游脚本 13/14: 屏蔽休眠, 电源键交给桌面处理)
# ---------------------------------------------------------------------------
log "配置电源管理"
for u in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  mask_unit "$u"
done
mkdir -p "$ROOT/etc/systemd/logind.conf.d"
cat > "$ROOT/etc/systemd/logind.conf.d/10-raphael-power.conf" <<'EOF'
# 电源键交给 KDE PowerDevil 处理 (短按熄屏 / 长按关机菜单)
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
PowerKeyIgnoreInhibited=yes
IdleAction=ignore
EOF

# ---------------------------------------------------------------------------
# 10. journald / 闪存寿命 / 杂项
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/etc/systemd/journald.conf.d"
cat > "$ROOT/etc/systemd/journald.conf.d/00-raphael.conf" <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
SystemMaxUse=64M
EOF
enable_unit fstrim.timer
# ALARM 镜像首启动交互式初始化会卡住无人值守启动, 直接屏蔽
mask_unit systemd-firstboot.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 清掉 mkinitcpio 的 preset (2026-10-15 真机踩到)
#   ALARM base 带了 /etc/mkinitcpio.d/linux-aarch64.preset, 而那个包根本没装;
#   于是每次 pacman -Syu 的 "Updating linux initcpios" 钩子都会报:
#       ERROR: '/lib/modules/7.1.6-1-aarch64-ARCH' is not a valid kernel module directory
#       error: command failed to execute correctly
#   本项目 08 阶段是**手工组装** initramfs 的, 完全不需要 mkinitcpio preset, 清掉。
# ---------------------------------------------------------------------------
if [ -d "$ROOT/etc/mkinitcpio.d" ]; then
  rm -f "$ROOT"/etc/mkinitcpio.d/*.preset
  log "  已清掉 mkinitcpio preset (initramfs 由本项目的 08 阶段手工组装)"
fi
rm -f "$ROOT"/boot/initramfs-linux.img "$ROOT"/boot/initramfs-linux-fallback.img 2>/dev/null || true
rm -f "$ROOT/etc/machine-id" 2>/dev/null || true
echo "uninitialized" > "$ROOT/etc/machine-id"

# ---------------------------------------------------------------------------
# 11. 首次开机初始化 pacman 密钥环 (签名校验需要)
# ---------------------------------------------------------------------------
cat > "$ROOT/usr/local/sbin/raphael-firstboot.sh" <<'EOF'
#!/bin/bash
# 首次开机: 初始化 pacman 密钥环 (离线导入 archlinuxarm-keyring)
set -e
if [ ! -s /etc/pacman.d/gnupg/pubring.gpg ]; then
  pacman-key --init
  pacman-key --populate archlinuxarm
fi
# archlinuxcn 源密钥 (装了 paru / rime-ice 之类的社区包需要)
if [ -f /usr/share/pacman/keyrings/archlinuxcn.gpg ] && ! pacman-key --list-keys archlinuxcn >/dev/null 2>&1; then
  pacman-key --populate archlinuxcn || true
fi
systemctl disable raphael-firstboot.service || true
EOF
chmod 755 "$ROOT/usr/local/sbin/raphael-firstboot.sh"
cat > "$ROOT/etc/systemd/system/raphael-firstboot.service" <<'EOF'
[Unit]
Description=raphael first boot setup (pacman keyring)
After=network.target
ConditionPathExists=!/etc/pacman.d/gnupg/pubring.gpg

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-firstboot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
enable_unit raphael-firstboot.service

# ---------------------------------------------------------------------------
# btrfs 交换文件 (@swap 子卷 -> /swap/swapfile, 由 fstab 挂载 /swap)
#   btrfs 上放交换文件有两个硬要求: **不能被压缩** 且 **nocow** (chattr +C),
#   所以单独开一个子卷按 nodatacow,compress=no 挂载 (见 lib.sh 的 fstab)。
#   文件在首启动创建 (镜像里不预置, 免得镜像白胖 4G), 之后写进 fstab 常驻。
# ---------------------------------------------------------------------------
if [ "${BTRFS_SWAP_SIZE:-4G}" != "0" ]; then
  cat > "$ROOT/usr/local/sbin/raphael-swapfile.sh" <<SWAPEOF
#!/bin/bash
# 首启动创建 btrfs 交换文件 (大小: ${BTRFS_SWAP_SIZE})
set -e
SIZE="${BTRFS_SWAP_SIZE}"
mountpoint -q /swap || { echo "/swap 未挂载, 跳过交换文件"; exit 0; }
[ -f /swap/swapfile ] && exit 0
cd /swap
# 先建成 nocow 再写数据 (顺序不能反, 否则整文件已经 cow 了)
: > swapfile
chattr +C swapfile 2>/dev/null || true
fallocate -l "\$SIZE" swapfile 2>/dev/null || \
  dd if=/dev/zero of=swapfile bs=1M count=\$(numfmt --from=iec "\$SIZE" 2>/dev/null | awk '{print int(\$1/1048576)}') status=none
chmod 600 swapfile
mkswap swapfile >/dev/null
# 写进 fstab, 以后每次开机自动启用 (幂等)
grep -q '^/swap/swapfile' /etc/fstab || echo '/swap/swapfile none swap defaults 0 0' >> /etc/fstab
swapon /swap/swapfile 2>/dev/null || true
echo "交换文件就绪: \$(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr '\n' ' ')"
systemctl disable raphael-swapfile.service >/dev/null 2>&1 || true
SWAPEOF
  chmod 755 "$ROOT/usr/local/sbin/raphael-swapfile.sh"
  cat > "$ROOT/etc/systemd/system/raphael-swapfile.service" <<'EOF'
[Unit]
Description=raphael btrfs swapfile (@swap)
ConditionPathExists=!/swap/swapfile
RequiresMountsFor=/swap
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-swapfile.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  enable_unit raphael-swapfile.service
  log "  交换文件: 首启动在 @swap 上创建 ${BTRFS_SWAP_SIZE} (btrfs 交换文件必须 nocow)"
fi

# ---------------------------------------------------------------------------
# 11b. UCM: 声卡 driver 名在不同内核构建下可能是 sm8150 / sm8150_raphael
#      (实测: 官方内核 sm8150_raphael, 自建同源码内核 sm8150)。
#      alsa-ucm2 按 conf.d/<driver>/<cardname|longname>.conf 查找, 名字都补上。
#      用真实目录副本而不是符号链接 (符号链接实测不一定被跟随)。
# ---------------------------------------------------------------------------
UCM="$ROOT/usr/share/alsa/ucm2/conf.d"

# 复制时跳过"源就是目标"的情况: cp 对同一文件会报
# "are the same file" 并被 set -e 当成失败 (CI 上踩过)
ucm_copy() {  # ucm_copy <src> <dst>
  local src="$1" dst="$2"
  [ -f "$src" ] || return 0
  [ "$(readlink -f "$src")" = "$(readlink -f "$dst" 2>/dev/null)" ] && return 0
  cp -f "$src" "$dst"
}

if [ -d "$UCM/sm8150_raphael" ]; then
  UCM_SRC="$UCM/sm8150_raphael"

  # ---------------------------------------------------------------------------
  # ★ 2026-10-15 真机定位: 声卡"没有声音"的真凶在这一段
  #   1) PipeWire 的 ACP 是按 **conf.d/<声卡名>/<声卡名>.conf** 找 UCM 的。上游重新
  #      打包内核后声卡名从 sm8150_raphael 变成了 **Raphael**(取自 DTB model),
  #      而这里只建了 sm8150 / sm8150_raphael 两个目录 -> ACP 找不到 UCM ->
  #      退回通用的 **pro-audio** profile。
  #   2) pro-audio 打开 PCM 时的参数不对 -> Q6 AFE 端口使能失败:
  #        qcom-q6afe: AFE enable for port 0x1006 failed -110 / -22
  #        ASoC error at snd_soc_dai_prepare() on QUAT_MI2S_RX
  #      -> 数据到不了功放 -> **完全没声音** (裸 aplay 也一样)。
  #   3) 换成正常的 stereo profile 后实测: PCM state=RUNNING、dmesg 零报错、有声音。
  #   修复: 给所有可能的声卡名都建目录, 并且把 HiFi.conf 裁成"只留真能用的扬声器
  #   通路" —— UCM 里只要有一个打不开的 PCM(这里的 Headphone/SLIMBUS 链路, 上游
  #   DTB 里没有 slim-*-dai-link), ACP 会**放弃整个 UCM**, 卡片又只剩 pro-audio。
  # ---------------------------------------------------------------------------
  HIFI_TRIM="$UCM_SRC/HiFi.raphael.conf"
  cat > "$HIFI_TRIM" <<'HIFIEOF'
# UCM2 for Xiaomi Raphael (SM8150) — 只暴露能工作的扬声器通路
#   耳机(WCD9340/SLIMBUS)与麦克风通路在上游 DTB 里缺 slim-*-dai-link, 打不开;
#   而 UCM 里出现打不开的 PCM 会让 ACP 放弃整个 UCM(退回 pro-audio -> 没声音),
#   所以这里只留 Speaker。等 DTB 补上采集/耳机链路再逐步加回。
SectionVerb {
	EnableSequence [
		cset "name='QUAT_MI2S_RX Audio Mixer MultiMedia2' 1"
		cset "name='QUAT_MI2S_RX Audio Mixer MultiMedia1' 1"
	]
	DisableSequence [ ]
}

SectionDevice."Speaker" {
	Comment "Speaker (TFA9874)"
	EnableSequence [ ]
	DisableSequence [ ]
	Value {
		PlaybackPriority 100
		PlaybackPCM "hw:0,1"
	}
}
HIFIEOF

  # 声卡名在不同内核构建下都见过: 官方内核 sm8150_raphael、自建 sm8150、
  # 上游重新打包后变成 DTB model 里的 Raphael(以及 longname 形态)。全建上。
  for name in Raphael sm8150 sm8150_raphael xiaomi-XiaomiRedmiK20Pro; do
    mkdir -p "$UCM/$name"
    ucm_copy "$HIFI_TRIM" "$UCM/$name/HiFi.conf"
    printf 'Syntax 3\n\nSectionUseCase."HiFi" {\n\tFile "HiFi.conf"\n\tComment "HiFi quality Music"\n}\n' \
      > "$UCM/$name/$name.conf"
  done
  log "UCM: conf.d 下已备好 Raphael / sm8150 / sm8150_raphael / xiaomi-* 四套名字 (精简扬声器版)"
fi

# ---------------------------------------------------------------------------
# 11b-2. 音频初始化服务 (2026-10-01 真机排了一整轮才理清)
#   三个坑, 少一个就没声音 (PipeWire 只剩"虚拟输出", 一直静音):
#   (1) pd-mapper 启动时扫 /sys/class/remoteproc/*/firmware 来枚举 servreg 的
#       .jsn 映射; 它若抢在 remoteproc 注册之前起来, 就 "no pd maps available"
#       而且永不重扫 -> ADSP 的 SLIMBUS 服务查不到 -> slim-ngd QMI 握手超时。
#       所以这里先重启一次 pd-mapper。
#   (2) slim-ngd 被 blacklist 挡住自动加载 (见 /etc/modprobe.d/raphael-audio.conf),
#       由本服务在 pd-mapper 就绪后手动 modprobe, 内核会顺带重跑 deferred probe。
#   (3) 声卡 DAI 链接 "SLIM Capture 1" 的 codec 永远不出现, 会把整块声卡卡在
#       EPROBE_DEFER。仓库里的 dtb/raphael-redmi-k20pro.dtb 已经把这个链接删掉
#       (fdtget -l /sound 应只有 mm1/mm2/speaker/slim-playback)。
#   另外 UCM 在 alsa-lib 1.2.16 下解析失败, 所以 Q6 路由 mixer 直接由本服务写,
#   并且在 60 秒内反复确认 (ACP 激活 profile 时可能把它们复位)。
# ---------------------------------------------------------------------------
cat > "$ROOT/etc/modprobe.d/raphael-audio.conf" <<'MEOF'
# slim-ngd 要和 ADSP 做 QMI 握手, 握手窗口 ~1 秒; 抢跑就永久失败。
# 禁止自动加载, 改由 raphael-audio-init.service 在 pd-mapper 就绪后手动加载。
blacklist slim_qcom_ngd_ctrl
MEOF
cat > "$ROOT/usr/local/sbin/raphael-audio-init.sh" <<'AEOF'
#!/bin/bash
# Raphael 音频初始化
#  1) 等 remoteproc 就绪 -> 重启 pd-mapper (重新枚举 .jsn) -> 手动加载 slim-ngd
#  2) 等声卡 -> 以用户身份重启 PipeWire、选**能工作的立体声** profile
#     (2026-10-15: 原来是 pro-audio, 实测那个 profile 会让 Q6 AFE 使能失败 -> 没声音)
#  3) 写 Q6 路由 mixer, 并在 60 秒内反复确认
# 不要 unbind/bind slim-ngd: 内核 qcom_slim_ngd_remove 会 WARN 打栈回溯。
set +u
have_card() { aplay -l 2>/dev/null | grep -q '^card 0'; }
as_user() { sudo -u @USER@ env XDG_RUNTIME_DIR=/run/user/1000 "$@"; }

for i in $(seq 1 60); do
  [ -r /sys/class/remoteproc/remoteproc2/firmware ] && break; sleep 0.5
done
systemctl restart pd-mapper 2>/dev/null
sleep 1
lsmod | grep -q '^slim_qcom_ngd_ctrl' || modprobe slim_qcom_ngd_ctrl 2>/dev/null
modprobe snd_soc_sm8150 2>/dev/null

i=0; while [ $i -lt 40 ] && ! have_card; do i=$((i+1)); sleep 0.5; done
have_card || { echo "raphael-audio: 无声卡"; exit 0; }
echo "raphael-audio: 声卡就绪"

apply() {
  # MultiMedia1 就是 ALSA 的 hw:0,0, 也是裸 aplay 的默认设备; 不给它接后端就会报
  # "ASoC: no backend DAIs enabled for MultiMedia1" 而且一点声音都没有。
  # 下面 SLIMBUS_0_RX 那条是历史遗留 (slim-*-dai-link 已从 DTB 删掉, 控件不存在),
  # 真正干活的是两条 QUAT_MI2S_RX (底部扬声器 TFA9874):
  #   MultiMedia1 -> QUAT_MI2S_RX  (aplay / 原生 ALSA, 即 hw:0,0)
  #   MultiMedia2 -> QUAT_MI2S_RX  (PipeWire 的 pro-output-1, KDE 走这条)
  amixer -c 0 cset "name=SLIMBUS_0_RX Audio Mixer MultiMedia1" 1 >/dev/null 2>&1
  amixer -c 0 cset "name=QUAT_MI2S_RX Audio Mixer MultiMedia1" 1 >/dev/null 2>&1
  amixer -c 0 cset "name=QUAT_MI2S_RX Audio Mixer MultiMedia2" 1 >/dev/null 2>&1
  amixer -c 0 cset "name=SLIM RX0 MUX" AIF1_PB >/dev/null 2>&1
  amixer -c 0 cset "name=SLIM RX1 MUX" AIF1_PB >/dev/null 2>&1
  amixer -c 0 cset "name=RX INT1_1 MIX1 INP0" RX0 >/dev/null 2>&1
  amixer -c 0 cset "name=RX INT2_1 MIX1 INP0" RX1 >/dev/null 2>&1
  amixer -c 0 cset "name=COMP1 Switch" 1 >/dev/null 2>&1
  amixer -c 0 cset "name=COMP2 Switch" 1 >/dev/null 2>&1
  amixer -c 0 cset "name=RX INT1 DEM MUX" CLSH_DSM_OUT >/dev/null 2>&1
  amixer -c 0 cset "name=RX INT2 DEM MUX" CLSH_DSM_OUT >/dev/null 2>&1
  amixer -c 0 cset "name=RX1 Digital Volume" 68 >/dev/null 2>&1
  amixer -c 0 cset "name=RX2 Digital Volume" 68 >/dev/null 2>&1
}

for i in $(seq 1 60); do
  [ -S /run/user/1000/pipewire-0 ] && break; sleep 0.5
done
as_user systemctl --user restart wireplumber >/dev/null 2>&1
sleep 4
# ★ 2026-10-15: 这里原来是 pro-audio, 实测 pro-audio 打开 PCM 的参数会让 Q6 AFE
#   使能失败(-110/-22) -> 完全没声音; 换成普通立体声 profile 后 PCM RUNNING、零报错。
as_user pactl set-card-profile alsa_card.platform-sound output:stereo-fallback >/dev/null 2>&1 \
  || as_user pactl set-card-profile alsa_card.platform-sound HiFi >/dev/null 2>&1
sleep 2

apply   # 后续由 raphael-audio-routing.timer 每 20 秒兜底
echo "raphael-audio: $(amixer -c 0 cget "name=SLIMBUS_0_RX Audio Mixer MultiMedia1" 2>/dev/null | tail -1)"
exit 0
AEOF
sed -i "s/@USER@/$USERNAME/g" "$ROOT/usr/local/sbin/raphael-audio-init.sh"
chmod 755 "$ROOT/usr/local/sbin/raphael-audio-init.sh"
cat > "$ROOT/etc/systemd/system/raphael-audio-init.service" <<'AEOF'
[Unit]
Description=Raphael audio init (slim-ngd late load + PipeWire profile + Q6 mixers)
After=pd-mapper.service
Wants=pd-mapper.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-audio-init.sh
RemainAfterExit=yes
TimeoutStartSec=300
AEOF
# ★ 不能挂在 multi-user.target 上: 它要等声卡 (ADSP/codec 就绪) 再等会话的
#   PipeWire, 实测占 1 分 46 秒, 会把开头拖到 2 分钟。
#   改成开机 12 秒后由 timer 拉起, 桌面立刻可用, 音频随后就位。
cat > "$ROOT/etc/systemd/system/raphael-audio-init.timer" <<'AEOF'
[Unit]
Description=Run Raphael audio init 12s after boot (off the boot critical path)

[Timer]
OnBootSec=12s
AccuracySec=2s
Persistent=false

[Install]
WantedBy=timers.target
AEOF
enable_unit raphael-audio-init.timer

# ---------------------------------------------------------------------------
# 11b-3. 路由 keep-alive: PipeWire/ACP 激活 profile 时会把上面这些 switch 复位成 off,
#   而 sink 能不能出声完全取决于对应路由:
#     MultiMedia1 (SLIMBUS_0_RX) -> hw:0,0 -> WCD9340 -> 耳机口 ("内置音频 Pro")
#     MultiMedia2 (QUAT_MI2S_RX) -> hw:0,1 -> TFA9874 -> 底部扬声器 ("内置音频 Pro 1")
#   实测 ACP 之后 MultiMedia1 会变回 off (症状: 扬声器有声音, 耳机那个 sink 全哑)。
#   用一个 20 秒周期的 timer 兜住, 谁被复位就立刻纠正。
# ---------------------------------------------------------------------------
cat > "$ROOT/usr/local/sbin/raphael-audio-routing.sh" <<'REOF'
#!/bin/bash
set +u
aplay -l 2>/dev/null | grep -q '^card 0' || exit 0

# ---------------------------------------------------------------------------
# 声卡 profile 兜底 (2026-10-15 真机定位到"没声音"的真凶)
#   pro-audio profile 打开 PCM 时的参数让 Q6 AFE 端口使能失败:
#     qcom-q6afe: AFE enable for port 0x1006 failed -110/-22
#   结果完全没声音 (连裸 aplay 都失败)。实测换成普通的立体声 profile 后:
#     PCM state=RUNNING, dmesg 零报错, 有声音。
#   这里每 20 秒检查一次, 发现是 pro-audio 就切回来 (幂等, 卡没插好也不影响)。
# ---------------------------------------------------------------------------
as_user() { sudo -u @USER@ env XDG_RUNTIME_DIR=/run/user/1000 "$@"; }
CARD=alsa_card.platform-sound
if as_user pactl list cards >/dev/null 2>&1; then
  CUR="$(as_user pactl list cards 2>/dev/null | awk -v c="$CARD" '$0 ~ c {f=1} f && /Active Profile/ {print $NF; exit}')"
  if [ "$CUR" = "pro-audio" ]; then
    # 优先 UCM 的 HiFi; 没有就用 ACP 的立体声兜底 profile
    for p in HiFi output:stereo-fallback; do
      if as_user pactl set-card-profile "$CARD" "$p" 2>/dev/null; then
        echo "raphael-audio: 已把声卡 profile 从 pro-audio 切到 $p"
        break
      fi
    done
  fi
fi
# MultiMedia1 就是 ALSA 的 hw:0,0, 也是裸 aplay 的默认设备; 不给它接后端就会报
# "ASoC: no backend DAIs enabled for MultiMedia1" 而且一点声音都没有。
# 下面 SLIMBUS_0_RX 那条是历史遗留 (slim-*-dai-link 已从 DTB 删掉, 控件不存在),
# 真正干活的是两条 QUAT_MI2S_RX (底部扬声器 TFA9874):
#   MultiMedia1 -> QUAT_MI2S_RX  (aplay / 原生 ALSA, 即 hw:0,0)
#   MultiMedia2 -> QUAT_MI2S_RX  (PipeWire 的 pro-output-1, KDE 走这条)
amixer -c 0 cset "name=SLIMBUS_0_RX Audio Mixer MultiMedia1" 1 >/dev/null 2>&1
amixer -c 0 cset "name=QUAT_MI2S_RX Audio Mixer MultiMedia1" 1 >/dev/null 2>&1
amixer -c 0 cset "name=QUAT_MI2S_RX Audio Mixer MultiMedia2" 1 >/dev/null 2>&1
amixer -c 0 cset "name=SLIM RX0 MUX" AIF1_PB >/dev/null 2>&1
amixer -c 0 cset "name=SLIM RX1 MUX" AIF1_PB >/dev/null 2>&1
amixer -c 0 cset "name=RX INT1_1 MIX1 INP0" RX0 >/dev/null 2>&1
amixer -c 0 cset "name=RX INT2_1 MIX1 INP0" RX1 >/dev/null 2>&1
amixer -c 0 cset "name=COMP1 Switch" 1 >/dev/null 2>&1
amixer -c 0 cset "name=COMP2 Switch" 1 >/dev/null 2>&1
amixer -c 0 cset "name=RX INT1 DEM MUX" CLSH_DSM_OUT >/dev/null 2>&1
amixer -c 0 cset "name=RX INT2 DEM MUX" CLSH_DSM_OUT >/dev/null 2>&1
amixer -c 0 cset "name=RX1 Digital Volume" 68 >/dev/null 2>&1
amixer -c 0 cset "name=RX2 Digital Volume" 68 >/dev/null 2>&1
exit 0
REOF
chmod 755 "$ROOT/usr/local/sbin/raphael-audio-routing.sh"
cat > "$ROOT/etc/systemd/system/raphael-audio-routing.service" <<'REOF'
[Unit]
Description=Re-assert Raphael Q6 audio routing (ACP 会把它复位)
After=raphael-audio-init.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-audio-routing.sh
REOF
cat > "$ROOT/etc/systemd/system/raphael-audio-routing.timer" <<'REOF'
[Unit]
Description=Keep Raphael audio routing asserted every 20s

[Timer]
OnBootSec=25s
OnUnitActiveSec=20s
AccuracySec=5s

[Install]
WantedBy=timers.target
REOF
enable_unit raphael-audio-routing.timer

# ---------------------------------------------------------------------------
# 11c. 蓝牙原厂固件/NVM: linux-firmware 里的 qca/crnv21.bin 与 raphael 的板级
#      校准不匹配 -> 控制器上报全零 BD_ADDR -> 内核 hci_power_on() 立即关闭设备,
#      不发 mgmt Index Added, 表现为 btmgmt "Invalid Index"。
#      设备自带的 bluetooth 分区 (FAT16, image/ 目录) 里是原厂 NVM+固件, 用它替换。
#      注意: 不做 unbind/bind 重新探测 (实测有概率把设备卡在关机流程),
#      首次装入后重启一次即可生效。
# ---------------------------------------------------------------------------
cat > "$ROOT/usr/local/sbin/raphael-bt-firmware.sh" <<'EOF'
#!/bin/bash
# 从设备自带的 bluetooth 分区安装原厂蓝牙 NVM/固件 (幂等)
part=/dev/disk/by-partlabel/bluetooth
[ -b "$part" ] || exit 0
mnt=$(mktemp -d)
if mount -o ro "$part" "$mnt" 2>/dev/null; then
  changed=0
  for f in crnv21.bin crbtfw21.tlv; do
    if [ -f "$mnt/image/$f" ] && ! cmp -s "$mnt/image/$f" "/lib/firmware/qca/$f"; then
      cp -f "$mnt/image/$f" "/lib/firmware/qca/$f" && changed=1
      echo "installed /lib/firmware/qca/$f from bluetooth partition"
    fi
  done
  umount "$mnt"
  rmdir "$mnt" 2>/dev/null || true
  if [ "$changed" = 1 ]; then
    echo "raphael: 蓝牙固件已更新, 需要重启一次才会重新下载 NVM"
    # 只在明显没有控制器时提示 (hci0 存在但没有 address 属性 = 内核把设备关掉了)
    if [ -d /sys/class/bluetooth/hci0 ] && [ ! -e /sys/class/bluetooth/hci0/address ]; then
      echo "raphael: 当前蓝牙不可用 -> systemctl reboot 后恢复"
    fi
  fi
fi
EOF
chmod 755 "$ROOT/usr/local/sbin/raphael-bt-firmware.sh"
cat > "$ROOT/etc/systemd/system/raphael-bt-firmware.service" <<'EOF'
[Unit]
Description=Install factory Bluetooth firmware/NVM from the bluetooth partition
After=local-fs.target
Before=bluetooth.service
ConditionPathExists=/dev/disk/by-partlabel/bluetooth

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/raphael-bt-firmware.sh

[Install]
WantedBy=multi-user.target
EOF
enable_unit raphael-bt-firmware.service

# ---------------------------------------------------------------------------
# 12. SSH 会话使用中文 (上游脚本 07 的 profile.d 片段, 原样可用)
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/etc/profile.d"
cat > "$ROOT/etc/profile.d/99-locale-fix.sh" <<'EOF'
# SSH 连接时强制中文, 本地 TTY 保持英文 (TTY 无中文字体)
if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
    export LANG=zh_CN.UTF-8
    export LANGUAGE=zh_CN:zh
    export LC_ALL=zh_CN.UTF-8
fi
EOF
chmod 644 "$ROOT/etc/profile.d/99-locale-fix.sh"

# ---------------------------------------------------------------------------
# 13. WirePlumber 音频参数 (上游脚本 16; 注意 0.5 已改为 SPA-JSON 语法)
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/etc/wireplumber/wireplumber.conf.d"
cat > "$ROOT/etc/wireplumber/wireplumber.conf.d/51-raphael-alsa.conf" <<'EOF'
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_input.*" }
      { node.name = "~alsa_output.*" }
    ]
    actions = {
      update-props = {
        audio.format         = "S16LE"
        audio.rate           = 48000
        api.alsa.period-size = 4096
        api.alsa.period-num  = 6
        api.alsa.headroom    = 512
      }
    }
  }
]
EOF

# ---------------------------------------------------------------------------
# 14. machine-id (USB gadget 序列号依赖它; Arch 镜像里是空的)
# ---------------------------------------------------------------------------
rm -f "$ROOT/etc/machine-id"
if ! gq /usr/bin/systemd-machine-id-setup >/dev/null 2>&1; then
  python3 -c 'import uuid;print(uuid.uuid4().hex)' > "$ROOT/etc/machine-id"
fi
log "machine-id: $(cat "$ROOT/etc/machine-id")"

# ---------------------------------------------------------------------------
# 15. 便捷命令 (对应上游 server 版的 leijun / jinfan 熄屏/亮屏)
# ---------------------------------------------------------------------------
if [ -x "$ROOT/usr/bin/kscreen-doctor" ]; then
  printf '#!/bin/sh\n# 关闭屏幕 (KDE Wayland)\nexec kscreen-doctor --dpms off\n' > "$ROOT/usr/local/bin/leijun"
  printf '#!/bin/sh\n# 点亮屏幕 (KDE Wayland)\nexec kscreen-doctor --dpms on\n' > "$ROOT/usr/local/bin/jinfan"
  chmod 755 "$ROOT/usr/local/bin/leijun" "$ROOT/usr/local/bin/jinfan"
  log "已安装 leijun (熄屏) / jinfan (亮屏) 命令"
fi

# ---------------------------------------------------------------------------
# 16. 属主修正 (构建时 userns 只映射了 uid 0, 无法 chown 到 1000)
#     ★ 这里必须【无条件】写: 之前写在"创建用户"分支里, 用户已存在时被跳过,
#       结果 /home/<user> 一直是 root:root, KDE 写不了配置 ->
#       初始化向导每次开机都弹、向导里改的设置不生效、证书/私钥保存失败。
# ---------------------------------------------------------------------------
USER_UID="$(grep "^$USERNAME:" "$ROOT/etc/passwd" | cut -d: -f3)"
USER_GID="$(grep "^$USERNAME:" "$ROOT/etc/passwd" | cut -d: -f4)"
mkdir -p "$ROOT/etc/tmpfiles.d"
cat > "$ROOT/etc/tmpfiles.d/raphael-home.conf" <<TFEOF
# 修正用户家目录属主 (镜像构建时无法设置非 root 属主, 首次开机由 tmpfiles 修正)
Z /home/$USERNAME - $USER_UID $USER_GID -
d /var/lib/sddm 0750 sddm sddm -
d /var/lib/NetworkManager 0755 root root -
d /var/lib/bluetooth 0700 root root -
d /var/lib/ModemManager 0755 root root -
d /var/lib/rmtfs 0755 root root -
d /var/lib/tqftpserv 0755 root root -
TFEOF
if [ -x "$ROOT/usr/local/sbin/raphael-firstboot.sh" ]; then
  # 兜底: 首次开机再 chown 一次 (tmpfiles 万一没跑到)
  sed -i "2i chown -R $USER_UID:$USER_GID /home/$USERNAME 2>/dev/null || true" \
      "$ROOT/usr/local/sbin/raphael-firstboot.sh"
fi

# ---------------------------------------------------------------------------
# 16b. 输入法环境变量 + 默认编辑器
#  ★ 真机踩坑 (2026-10-01), 三种写法只有一种对:
#    1) QT_IM_MODULE=fcitx (Shorin 指南) -> 键盘弹得出来, 点按键输入框毫无反应
#    2) QT_IM_MODULE=qtvirtualkeyboard (单数) -> 还是不行; plasma-keyboard 自己
#       在日志里说: "qtvirtualkeyboard currently is not supported at client-side,
#       use QT_IM_MODULES=qtvirtualkeyboard at compositor-side."
#    3) QT_IM_MODULES=qtvirtualkeyboard (复数) -> 这才是对的方向, 但**只能给
#       合成器** (kwin_wayland) 用: 放全局会让键盘自己闪退。做法见 07 阶段
#       (kwin 的 systemd user drop-in + 键盘 desktop 文件 Exec 里 env -u)。
#    中文/英文都靠 Plasma 键盘自带的 Pinyin 插件, 不需要 fcitx5。
# ---------------------------------------------------------------------------
#  注意: QT_IM_MODULES 千万不要写进 /etc/environment!
#  那会让每个 Qt 程序 (包括 plasma-keyboard 自己) 都去加载虚拟键盘输入上下文
#  -> 键盘窗口弹出来就闪退/不显示。它只应该给合成器 kwin_wayland 用,
#  见 07 阶段的 plasma-kwin_wayland.service.d/im.conf。
cat > "$ROOT/etc/environment" <<'EOF'
EDITOR=nvim
VISUAL=nvim
EOF

# ---------------------------------------------------------------------------
# 16c. faillock 放宽 (手机常走 SSH 调试, 默认 deny=3 很容易把自己锁在外面)
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/etc/security"
cat > "$ROOT/etc/security/faillock.conf" <<'EOF'
deny = 10
unlock_time = 300
EOF

# ---------------------------------------------------------------------------
# 17. 闪光灯 / 手电筒 (pm8150l_flash, 内核模块 leds-qcom-flash)
#     这是目前唯一"能用的相机相关硬件": R/B 双色温闪光灯
# ---------------------------------------------------------------------------
log "配置手电筒 (闪光灯 LED)"
cat > "$ROOT/etc/modules-load.d/raphael-leds.conf" <<'EOF'
# PM8150L 闪光灯 LED 控制器 (设备树里 &pm8150l_flash 已是 okay)
leds-qcom-flash
EOF
cat > "$ROOT/usr/local/bin/shoudian" <<'EOF'
#!/bin/bash
# 手电筒开关: shoudian on|off|toggle|status
# 硬件: PM8150L 闪光灯 (双色温), 内核驱动 leds-qcom-flash
set -u
find_led() {
  local d
  for d in /sys/class/leds/*flash*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      white:flash|*:flash|*flash*) echo "$d"; return 0 ;;
    esac
  done
  for d in /sys/class/leds/*; do
    [ -d "$d" ] || continue
    [ -w "$d/brightness" ] && [ -n "$(ls "$d" 2>/dev/null | grep -x 'flash_strobe')" ] && { echo "$d"; return 0; }
  done
  return 1
}
LED="$(find_led)" || {
  echo "找不到闪光灯 LED 设备。" >&2
  echo "检查: lsmod | grep leds_qcom_flash ; dmesg | grep -i 'leds.*flash'" >&2
  echo "设备树节点应为 &pm8150l_flash (status okay)" >&2
  exit 1
}
TORCH="$LED/brightness"
STROBE="$LED/flash_strobe"
get_max() { cat "$LED/max_brightness" 2>/dev/null || echo 255; }
is_on() {
  local v=0
  [ -w "$TORCH" ] && v=$(cat "$TORCH" 2>/dev/null || echo 0)
  [ "${v:-0}" -gt 0 ] 2>/dev/null && return 0
  [ -w "$STROBE" ] && [ "$(cat "$STROBE" 2>/dev/null || echo 0)" = "1" ] && return 0
  return 1
}
turn_on() {
  local mx; mx=$(get_max)
  # 优先用 torch 模式 (brightness); 不支持则退回闪光灯触发
  if [ -w "$TORCH" ]; then
    echo "$mx" > "$TORCH" 2>/dev/null && { echo "手电筒已打开 ($(basename "$LED"), 亮度 $mx)"; return 0; }
  fi
  if [ -w "$STROBE" ]; then
    echo 1 > "$STROBE" 2>/dev/null && { echo "手电筒已打开 (闪光灯触发模式, 约 1.2 秒后自动熄灭)"; return 0; }
  fi
  echo "写入 LED 失败 (权限? 试试 sudo)" >&2; exit 1
}
turn_off() {
  [ -w "$TORCH" ] && echo 0 > "$TORCH" 2>/dev/null
  [ -w "$STROBE" ] && echo 0 > "$STROBE" 2>/dev/null
  echo "手电筒已关闭"
}
case "${1:-toggle}" in
  on)     turn_on ;;
  off)    turn_off ;;
  toggle) if is_on; then turn_off; else turn_on; fi ;;
  status) if is_on; then echo "手电筒: 开"; else echo "手电筒: 关"; fi
          echo "LED: $LED"; ls "$LED" 2>/dev/null | tr '\n' ' '; echo ;;
  *)      echo "用法: shoudian on|off|toggle|status"; exit 2 ;;
esac
EOF
chmod 755 "$ROOT/usr/local/bin/shoudian"
echo 'shoudian  ALL=(ALL) NOPASSWD: /usr/local/bin/shoudian' > "$ROOT/etc/sudoers.d/20-shoudian"
chmod 440 "$ROOT/etc/sudoers.d/20-shoudian"

# KDE 应用菜单里也能点
mkdir -p "$ROOT/usr/share/applications"
cat > "$ROOT/usr/share/applications/shoudian.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=手电筒
Name[en]=Flashlight
Comment=切换 K20 Pro 闪光灯手电筒
Exec=sudo /usr/local/bin/shoudian toggle
Icon=flashlight-on
Terminal=true
Categories=Utility;
EOF

# ---------------------------------------------------------------------------
# 18. 摄像头诊断工具: 一条命令看清相机到底卡在哪一层
# ---------------------------------------------------------------------------
cat > "$ROOT/usr/local/bin/camera-check" <<'EOF'
#!/bin/bash
# K20 Pro 摄像头可行性诊断: 逐层检查 (内核→总线→设备树→用户态)
echo "===== 1. 内核驱动 ====="
for m in qcom_camss i2c_qcom_cci v4l2_cci leds_qcom_flash; do
  if lsmod | grep -q "^$m "; then echo "  ✓ 已加载: $m"
  elif modinfo "$m" >/dev/null 2>&1; then echo "  · 存在未加载: $m"
  else echo "  ✗ 内核里没有: $m"; fi
done
echo
echo "===== 2. 设备树里有没有摄像头节点 ====="
for n in camss csiphy csid cci; do
  c=$(find /proc/device-tree -maxdepth 3 -name "*$n*" 2>/dev/null | wc -l)
  echo "  $n 相关节点: $c"
done
echo "  (若为 0: 内核设备树里根本没有相机硬件描述 → 需要移植 CAMSS/CCI 节点)"
echo
echo "===== 3. CCI (摄像头 I2C 总线) 上挂了什么 ====="
for b in /sys/bus/i2c/devices/i2c-*; do
  [ -e "$b/name" ] || continue
  n=$(cat "$b/name" 2>/dev/null)
  case "$n" in *CCI*|*cci*) echo "  $b = $n"; ls "$b" | grep -E '^[0-9]+-[0-9a-f]{4}$' | sed 's/^/      子设备: /' ;; esac
done
echo
echo "===== 4. 有没有 V4L2 采集设备 ====="
ls -l /dev/video* 2>/dev/null || echo "  /dev/video* 不存在 (没有可用摄像头)"
command -v v4l2-ctl >/dev/null && v4l2-ctl --list-devices 2>/dev/null
echo
echo "===== 5. 闪光灯 ====="
ls /sys/class/leds/ 2>/dev/null | sed 's/^/  /' || echo "  无 LED"
echo
echo "===== 6. USB 摄像头 (可用的替代方案) ====="
lsusb 2>/dev/null | grep -iE 'cam|video|webcam|uvc' || echo "  未插 USB 摄像头"
lsmod | grep -q uvcvideo && echo "  ✓ uvcvideo 已加载" || echo "  · uvcvideo 未加载 (插上 USB 摄像头会自动加载)"
echo
echo "===== 7. 最近的内核相机相关日志 ====="
dmesg 2>/dev/null | grep -iE 'camss|csiphy|csid|cci|camera|imx[0-9]|s5k' | tail -15 || echo "  (需要 root)"
EOF
chmod 755 "$ROOT/usr/local/bin/camera-check"

# ---------------------------------------------------------------------------
# 19. USB 摄像头 (uvcvideo) 与视频硬解 (Venus) 相关模块自加载
# ---------------------------------------------------------------------------
cat > "$ROOT/etc/modules-load.d/raphael-video.conf" <<'EOF'
# USB 视频类设备 (USB 摄像头/采集卡)
uvcvideo
# Qualcomm Venus 视频编解码由设备树 modalias 自动加载 (venus-core/-dec/-enc)
EOF

# ---------------------------------------------------------------------------
# 20. 关掉 systemd 的看门狗 (真机验证: 否则重启会卡死在关机流程)
#     PM8150 硬件看门狗不支持 10 分钟超时, systemd 重启时设置失败会卡住,
#     表现为屏幕显示 "Fail to set watchdog hardware timeout to 10 minutes:
#     Invalid argument" 且设备无法重启 (sshd 已停但 USB gadget 还在)。
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/etc/systemd/system.conf.d"
cat > "$ROOT/etc/systemd/system.conf.d/10-raphael-watchdog.conf" <<'EOF'
[Manager]
RuntimeWatchdogSec=off
RebootWatchdogSec=off
KExecWatchdogSec=off
EOF

log "系统基础配置完成"

# ---------------------------------------------------------------------------
# 13. Shorin 指南对齐 (准备篇 + 快照篇)
# ---------------------------------------------------------------------------
# 13.1 默认编辑器: 只要 neovim / vim, 不要 nano (指南用 EDITOR 环境变量)
[ -f "$ROOT/etc/environment" ] && sed -i '/^EDITOR=/d;/^VISUAL=/d' "$ROOT/etc/environment"
printf 'EDITOR=nvim\nVISUAL=nvim\n' >> "$ROOT/etc/environment"
log "EDITOR/VISUAL = nvim"

# 13.2 faillock: 指南是 deny=0 (完全不锁), 手机上折中为 5 次
sed -i 's/^deny *= *[0-9]*/deny = 5/' "$ROOT/etc/security/faillock.conf" 2>/dev/null || true
grep -q '^deny' "$ROOT/etc/security/faillock.conf" 2>/dev/null && \
  log "faillock: $(grep '^deny' "$ROOT/etc/security/faillock.conf")"

# 13.3 霞鹜文楷 (用户指定: github.com/lxgw/LxgwWenkai) — 终端用 Mono 变体
#      纯命令行构建没有桌面, 也用不到这两份 CJK 字体 (50 MB), 直接跳过
if [ "$HAVE_ANY_DE" = 1 ]; then
  LXGW_VER="${LXGW_WENKAI_VERSION:-v1.522}"
  install -d "$ROOT/usr/share/fonts/TTF"
  for f in LXGWWenKai-Regular.ttf LXGWWenKaiMono-Regular.ttf; do
    [ -s "$DL/$f" ] || fetch "https://github.com/lxgw/LxgwWenkai/releases/download/$LXGW_VER/$f" "$DL/$f"
    cp -f "$DL/$f" "$ROOT/usr/share/fonts/TTF/$f"
  done
  log "字体: 霞鹜文楷 Regular + Mono ($LXGW_VER)"
else
  log "纯命令行: 跳过霞鹜文楷字体 (无桌面)"
fi

# 13.3b 这几个挂载单元**不 mask**: 内核其实都支持
#   (configfs=y debugfs=y posix_mqueue=y hugetlbfs=y; binfmt_misc=m fuse=m 需加载模块),
#   挂不上应当查模块是否加载/启动是否正常, 而不是屏蔽掉标准单元。
# 13.4 性能模式: power-profiles-daemon (无 cpufreq 的设备自动跳过)
if [ -d "$ROOT/sys/devices/system/cpu/cpufreq" ] || [ -d "/sys/devices/system/cpu/cpufreq" ]; then
  enable_unit power-profiles-daemon.service 2>/dev/null || \
    mask_unit power-profiles-daemon.service 2>/dev/null || true
  log "性能模式: power-profiles-daemon 已 enable (内核有 cpufreq)"
else
  log "性能模式: 无 cpufreq, 跳过 power-profiles-daemon"
fi

# 13.5 Flatpak + flathub (指南可选; 国内用上交大镜像)
if [ -x "$ROOT/usr/bin/flatpak" ]; then
  gq /usr/bin/flatpak remote-add --if-not-exists --system flathub \
     https://mirror.sjtu.edu.cn/flathub/flathub.flatpakrepo >/dev/null 2>&1 || \
  gq /usr/bin/flatpak remote-add --if-not-exists --system flathub \
     https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
  log "flatpak: flathub remote 已配置"
fi

# 13.6 ~~wheel 免密使用 pacman~~ — 已移除 (2026-10-10)
#   这条指南可选步骤只是为了"非交互跑 paru"给 AUR 自动安装用的; AUR 自动安装
#   整段已经删掉 (见下面 13.8 的说明), 免密也就没有存在理由了, 一并去掉。
#   paru / yay 仍然预装, 手动 `paru -S <包名>` 时会正常提示输入密码。

# 13.7 snapper (指南: 快照和系统维护) — 首启动自动配置, 幂等
cat > "$ROOT/usr/local/sbin/raphael-snapper-setup.sh" <<'EOF'
#!/bin/bash
# 按 Shorin 指南配置 snapper; 非 btrfs 或单子卷布局会自动跳过并说明原因
set -u
if [ "$(findmnt -no FSTYPE / 2>/dev/null)" != "btrfs" ]; then
  echo "根文件系统不是 btrfs, 跳过 snapper"; exit 0
fi
if ! btrfs subvolume show / >/dev/null 2>&1; then
  echo "根不是 btrfs 子卷 (单子卷布局) -> snapper 需要 @ 子卷, 已跳过。"
  echo "要用快照请刷 CI 构建的镜像 (有 @/@home 子卷)。"
  exit 0
fi
command -v snapper >/dev/null 2>&1 || { echo "未安装 snapper"; exit 0; }
snapper -c root get-config >/dev/null 2>&1 || snapper -c root create-config /
if findmnt -no FSTYPE /home 2>/dev/null | grep -q btrfs; then
  snapper -c home get-config >/dev/null 2>&1 || snapper -c home create-config /home
fi
for c in root home; do
  f="/etc/snapper/configs/$c"; [ -f "$f" ] || continue
  sed -i 's/^ALLOW_GROUPS=.*/ALLOW_GROUPS="wheel"/'   "$f"
  sed -i 's/^NUMBER_LIMIT=.*/NUMBER_LIMIT="10"/'      "$f"
  sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="3"/' "$f"
  sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="1"/'   "$f"
  for k in WEEKLY MONTHLY YEARLY; do
    sed -i "s/^TIMELINE_LIMIT_$k=.*/TIMELINE_LIMIT_$k=\"0\"/" "$f"
  done
done
systemctl enable --now snapper-timeline.timer snapper-cleanup.timer >/dev/null 2>&1 || true
snapper -c root create -d "initial" >/dev/null 2>&1 || true
echo "snapper 配置完成: root(+home) 保留 10 个, 每小时 3 个 / 每天 1 个; 定时器已启用"
echo "回档请看 README 的「系统维护」一节 (btrfs-assistant / snapper list)"
EOF
chmod 755 "$ROOT/usr/local/sbin/raphael-snapper-setup.sh"
cat > "$ROOT/etc/systemd/system/raphael-snapper-setup.service" <<'EOF'
[Unit]
Description=Configure snapper snapshots (Shorin guide layout)
After=local-fs.target
ConditionPathExists=/usr/bin/snapper

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/raphael-snapper-setup.sh

[Install]
WantedBy=multi-user.target
EOF
enable_unit raphael-snapper-setup.service

# 13.8 ~~AUR 包首启动自动安装~~ — 已整段移除 (2026-10-10, 用户要求)
#   原来的实现: /usr/local/sbin/raphael-aur-setup.sh + raphael-aur-setup.service
#   + raphael-aur-setup.timer, 开机 90 秒后用 paru 装一批 AUR 包
#   (btrfs-assistant / snap-pac / downgrade / kwin 圆角与几何特效 / rime-ice-git ...),
#   失败时往 /etc/motd 和 ~/AUR-安装失败-请看这里.txt 写"没装上"的提示, 且**不写完成标记**。
#
#   删掉的两个原因:
#     1) 「镜像不要自己装 AUR 包」——装什么由用户自己决定, 系统不代劳;
#     2) 原来的清单里 kwin-effect-rounded-corners-git 的 PKGBUILD 只声明
#        arch=x86_64, 在 aarch64 上**永远构建不出来** -> 失败 -> 不写完成标记 ->
#        每次开机重试, 并往 /etc/motd 刷"AUR 安装失败"。用户一登录 SSH 就看到这行,
#        属于纯粹的噪声 (2026-10-03 真机日志: "不具备 'aarch64' 架构")。
#
#   paru / yay / archlinuxcn 源都还在 (见 config/build.conf), 想装什么手动来:
#     paru -S <包名>        # AUR
#     sudo pacman -S <包名>  # 官方仓库 / archlinuxcn
#   手动装需要输入密码 (13.6 的 wheel 免密 pacman 已一并去掉)。
#
#   下面这段是"拆弹"用的: 增量重建 (work/root 还在) 时, 上一版生成的脚本/单元/
#   软链/免密文件仍留在 rootfs 里 -> 定时器照样会跑、motd 照样会被刷。显式清掉。
for f in usr/local/sbin/raphael-aur-setup.sh \
         etc/systemd/system/raphael-aur-setup.service \
         etc/systemd/system/raphael-aur-setup.timer \
         etc/systemd/system/multi-user.target.wants/raphael-aur-setup.service \
         etc/systemd/system/timers.target.wants/raphael-aur-setup.timer \
         etc/sudoers.d/10-pacman-nopasswd; do
  rm -f "$ROOT/$f"
done
if [ -f "$ROOT/etc/motd" ] && grep -q 'AUR' "$ROOT/etc/motd" 2>/dev/null; then
  sed -i -e '/^raphael: .*AUR/d' -e '/raphael-aur-setup\.sh/d' -e '/^ 或逐个: paru -S/d' "$ROOT/etc/motd"
  log "  /etc/motd: 清掉遗留的 AUR 提示"
fi

# ---------------------------------------------------------------------------
# 14b. 花屏缓解: 不让 msm 显示控制器/DSI 进 runtime suspend
#   现象: 息屏/亮屏、以及自动变暗那一下会花屏一闪。内核是预编译的 vendor 内核,
#   先从 PM 侧缓解 (让显示控制器保持 resume)。
# ---------------------------------------------------------------------------
cat > "$ROOT/usr/local/sbin/raphael-display-nopm.sh" <<'DEOF'
#!/bin/bash
set +u
for d in /sys/bus/platform/devices/ae01000.display-controller \
         /sys/bus/platform/devices/ae94000.dsi \
         /sys/bus/platform/devices/ae00000.display-subsystem; do
  [ -e "$d/power/control" ] && echo on > "$d/power/control" 2>/dev/null
done
exit 0
DEOF
chmod 755 "$ROOT/usr/local/sbin/raphael-display-nopm.sh"
cat > "$ROOT/etc/systemd/system/raphael-display-nopm.service" <<'DEOF'
[Unit]
Description=Raphael: keep display controller runtime-resumed (花屏缓解)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raphael-display-nopm.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DEOF
enable_unit raphael-display-nopm.service
log "Shorin 对齐 (准备篇/快照篇) 完成"
