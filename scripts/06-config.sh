#!/bin/bash
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
log "写 /etc/fstab"
cat > "$ROOT/etc/fstab" <<'EOF'
# <device>                     <dir>   <type>  <options>                                   <dump> <pass>
PARTLABEL=userdata             /       ext4    rw,errors=remount-ro,x-systemd.growfs       0      1
PARTLABEL=cache                /boot   vfat    umask=0077,nofail,noatime                   0      2
EOF
if [ ! -e "$ROOT/usr/lib/systemd/system/systemd-growfs@.service" ]; then
  warn "systemd 未提供 systemd-growfs@, 改用自建扩容服务"
  cat > "$ROOT/etc/systemd/system/raphael-growfs.service" <<'EOF'
[Unit]
Description=Grow root filesystem to fill userdata partition
DefaultDependencies=no
After=local-fs.target
Requires=local-fs.target
Before=sysinit.target shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/bin/resize2fs -f /dev/disk/by-partlabel/userdata
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
  # 构建时无法 chown 到非 0 uid (userns 只映射了 uid 0), 交给首次开机的 tmpfiles
  mkdir -p "$ROOT/etc/tmpfiles.d"
  cat > "$ROOT/etc/tmpfiles.d/raphael-home.conf" <<TFEOF
# 修正用户家目录属主 (镜像构建时无法设置非 root 属主)
Z $HOME_DIR - $UID_N $UID_N -
TFEOF
  log "  已创建 $USERNAME (uid $UID_N, 组: wheel video audio input storage power rfkill)"
fi

# root 密码 + 允许密码登录 SSH (与上游一致, 方便首次调试)
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

[device]
wifi.scan-rand-mac-address=no
EOF
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
# ALARM 基础镜像默认启用 systemd-networkd + systemd-resolved, 会和
# NetworkManager 抢网卡/DNS, 必须关掉
for u in systemd-networkd.service systemd-networkd.socket \
         systemd-networkd-resolve-hook.socket systemd-networkd-varlink.socket \
         systemd-networkd-varlink-metrics.socket systemd-resolved.service \
         systemd-resolved-monitor.socket systemd-resolved-varlink.socket; do
  if [ -e "$ROOT/usr/lib/systemd/system/$u" ]; then
    gq /usr/bin/systemctl --root=/ disable "$u" >/dev/null 2>&1 || true
    rm -f "$ROOT/etc/systemd/system"/*.wants/"$u"
    log "  disable: $u (改用 NetworkManager)"
  fi
done
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
set -e
modprobe libcomposite
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
G=/sys/kernel/config/usb_gadget/g1
mkdir -p $G
echo 0x1d6b > $G/idVendor
echo 0x0104 > $G/idProduct
echo 0x0200 > $G/bcdUSB
mkdir -p $G/strings/0x409
echo raphael > $G/strings/0x409/manufacturer
echo "Arch Linux ARM" > $G/strings/0x409/product
echo "$(cat /etc/machine-id)" > $G/strings/0x409/serialnumber
mkdir -p $G/configs/c.1/strings/0x409
echo NCM > $G/configs/c.1/strings/0x409/configuration
mkdir -p $G/functions/ncm.usb0
ln -sfn $G/functions/ncm.usb0 $G/configs/c.1/
UDC=$(ls /sys/class/udc | head -n 1)
echo "$UDC" > $G/UDC
ip link set usb0 up
ip addr add 172.16.42.1/24 dev usb0 || true
systemctl restart dnsmasq || true
EOF
chmod 755 "$ROOT/usr/local/sbin/setup-usb-ncm.sh"
cat > "$ROOT/etc/systemd/system/usb-ncm.service" <<'EOF'
[Unit]
Description=USB CDC-NCM gadget networking
After=network.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-usb-ncm.sh
RemainAfterExit=yes

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
# 16. 服务状态目录属主 (构建时无法 chown 到非 0 uid, 由 tmpfiles 兜底)
# ---------------------------------------------------------------------------
cat >> "$ROOT/etc/tmpfiles.d/raphael-home.conf" <<'TFEOF'
d /var/lib/sddm 0750 sddm sddm -
d /var/lib/NetworkManager 0755 root root -
d /var/lib/bluetooth 0700 root root -
d /var/lib/ModemManager 0755 root root -
d /var/lib/rmtfs 0755 root root -
TFEOF

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

log "系统基础配置完成"
