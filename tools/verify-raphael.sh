#!/bin/bash
# Raphael 真机全项回归验证 (33 项)
#
# 用途: 在设备上以 root 跑一次, 逐项检查系统/桌面/播放/麦克风/服务/GPU/Wi-Fi/存储。
#   sudo bash verify-raphael.sh
# 只做读取与一次**静音**录音/播放测试 (全零 WAV, 3% 音量), 不会出声。
# 退出码: 0 = 全部通过, 1 = 有失败项。

PASS=0; FAIL=0
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
HOSTN=$(cat /etc/hostname)
ck() { # ck <名称> <期望描述> <实际值> <判定表达式...>
  local name="$1" want="$2" got="$3"; shift 3
  if "$@"; then printf "    ✓ %-34s %s\n" "$name" "$got"; PASS=$((PASS+1))
  else printf "    ✗ %-34s %s (期望: %s)\n" "$name" "$got" "$want"; FAIL=$((FAIL+1)); fi
}
AU="sudo -u winter env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"
echo "═══════ Raphael 全项回归 $(date '+%F %T') ═══════"
echo "【系统】"
ck "内核" "7.2.0-sm8150-*" "$(uname -r)" test "$(uname -r)" = "7.2.0-sm8150-ga1573649db08"
ck "系统失败单元" "0" "$(systemctl --failed --no-legend 2>/dev/null | wc -l)" test "$(systemctl --failed --no-legend 2>/dev/null | wc -l)" -eq 0
UFAIL=$(systemctl --user -M winter@ --failed --no-legend 2>/dev/null | wc -l)
ck "用户失败单元" "0" "$UFAIL" test "$UFAIL" -eq 0
ck "普通用户 winter 存在" "uid=1000" "$(id winter 2>/dev/null | cut -d' ' -f1)" test "$(id winter 2>/dev/null | grep -c 'uid=1000')" -eq 1
ck "sudo 密码" "可用" "$(echo 031210 | sudo -S -k true 2>/dev/null && echo 0 || echo 1)" test "$(echo 031210 | sudo -S -k true 2>/dev/null && echo 0 || echo 1)" -eq 0
ck "hostname" "raphael" "$HOSTN" test "$HOSTN" = "raphael"
echo "【桌面】"
KS=$(systemctl --user -M winter@ is-active plasma-plasmashell.service 2>/dev/null)
ck "plasmashell" "active" "$KS" test "$KS" = "active"
DB=$(sudo -u winter $AU dbus-send --session --dest=org.freedesktop.DBus --print-reply /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:org.kde.plasmashell 2>/dev/null | grep -c true)
ck "plasmashell D-Bus" "1" "$DB" test "$DB" -ge 1
echo "【声音 - 播放】"
CARDN=$(cat /proc/asound/cards 2>/dev/null | grep -c "Raphael")
ck "声卡 Raphael 存在" "1" "$CARDN" test "$CARDN" -eq 1
CODEC=$(lsmod | grep -c snd_soc_wcd934x)
ck "wcd934x codec 加载" "1" "$CODEC" test "$CODEC" -ge 1
PROF=$(sudo -u winter $AU pactl list cards 2>/dev/null | awk '/Active Profile/{print $NF}')
ck "profile 非 pro-audio/off" "HiFi*" "$PROF" test "$PROF" != "off" -a "$PROF" != "pro-audio" -a -n "$PROF"
SINK=$(sudo -u winter $AU pactl list short sinks 2>/dev/null | grep -c "HiFi__Speaker__sink")
ck "扬声器 sink 存在" "1" "$SINK" test "$SINK" -ge 1
DSN=$(sudo -u winter $AU pactl get-default-sink 2>/dev/null)
ck "默认 sink 非 auto_null" "HiFi*" "$DSN" bash -c '[[ "$0" != *auto_null* && -n "$0" ]]' "$DSN"
echo "【声音 - 麦克风 (本轮修复重点)】"
SRC=$(sudo -u winter $AU pactl list short sources 2>/dev/null | grep -c "HiFi__Mic__source")
ck "麦克风 source 存在" "1" "$SRC" test "$SRC" -ge 1
TX=$(amixer -c 0 cget "name=MultiMedia2 Mixer SLIMBUS_0_TX" 2>/dev/null | tail -1 | grep -c on)
ck "Q6 TX 路由 (MM2)" "1" "$TX" test "$TX" -ge 1
# 设备上没有 dtc, 用已知的 patched DTB md5 判定 (补丁后的字节数固定)
DTBMD5=$(md5sum /boot/dtbs/qcom/raphael-redmi-k20pro.dtb | cut -d' ' -f1)
DTBMD5E=$(md5sum /boot/dtbs/qcom/raphael-redmi-k20pro.dtb.micbak 2>/dev/null | cut -d' ' -f1)
if [ "$DTBMD5" != "$DTBMD5E" ]; then DTBR=1; else DTBR=0; fi
ck "DTB 采集路由已打补丁" "已改" "$DTBMD5" test "$DTBR" -eq 1
echo "【声音 - 实测录音 (静音测试, 1% 音量)】"
rm -f /tmp/reg.wav
sudo -u winter $AU bash -c 'nohup pw-record --target=alsa_input.platform-sound.HiFi__Mic__source /tmp/reg.wav >/dev/null 2>&1 &'
sleep 8; pkill -f pw-record 2>/dev/null; sleep 1
RES=$(python3 -c "
import wave,array
try:
    w=wave.open('/tmp/reg.wav','rb'); d=w.readframes(w.getnframes())
    a=array.array('h'); a.frombytes(d)
    nz=sum(1 for x in a if x); pk=max(abs(x) for x in a) if a else 0
    print('%d %d %d' % (w.getnframes(), nz*100//max(len(a),1), pk))
except Exception: print('0 0 0')
" 2>/dev/null)
FR=$(echo "$RES" | cut -d' ' -f1); PCTV=$(echo "$RES" | cut -d' ' -f2); PK=$(echo "$RES" | cut -d' ' -f3)
ck "录音帧数" ">30000" "$FR" test "$FR" -gt 30000
ck "非零采样占比" ">50%" "$PCTV%" test "$PCTV" -gt 50
ck "峰值" ">50" "$PK" test "$PK" -gt 50
dmesg -C >/dev/null 2>&1
python3 -c "
import wave
w=wave.open('/tmp/z.wav','w'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b'\x00'*48000*2*2*3); w.close()"
chmod 644 /tmp/z.wav
sudo -u winter $AU pactl set-sink-volume @DEFAULT_SINK@ 3% >/dev/null 2>&1
sudo -u winter $AU timeout 12 pw-play /tmp/z.wav >/dev/null 2>&1
ck "扬声器静音播放" "0" "$?" test "$?" -eq 0
AFE=$(dmesg | grep -ciE "AFE enable|ASoC error")
ck "AFE 报错" "0" "$AFE" test "$AFE" -eq 0
UNF=$(dmesg | grep -c underrun)
ck "underrun" "0" "$UNF" test "$UNF" -eq 0
echo "【服务】"
AI=$(systemctl show raphael-audio-init.service -p Result --value 2>/dev/null)
ck "audio-init 结果" "success" "$AI" test "$AI" = "success"
RT=$(systemctl is-active raphael-audio-routing.timer 2>/dev/null)
ck "routing timer" "active" "$RT" test "$RT" = "active"
RR=$(systemctl show raphael-audio-routing.service -p Result --value 2>/dev/null)
ck "routing service 结果" "success" "$RR" test "$RR" = "success"
ck "健康采样 timer" "active" "$(systemctl is-active raphael-health.timer 2>/dev/null)" test "$(systemctl is-active raphael-health.timer 2>/dev/null)" = "active"
echo "【输入法 fcitx5 + Rime】"
F5=$(pacman -Q fcitx5 >/dev/null 2>&1 && echo yes || echo no)
ck "fcitx5 已安装" "yes" "$F5" test "$F5" = "yes"
FR=$(pacman -Q fcitx5-rime >/dev/null 2>&1 && echo yes || echo no)
ck "fcitx5-rime 已安装" "yes" "$FR" test "$FR" = "yes"
RIMEDATA=$(ls /usr/share/rime-data/*.schema.yaml 2>/dev/null | wc -l)
ck "Rime 方案文件" ">0" "$RIMEDATA" test "$RIMEDATA" -gt 0
DIM=$(grep -h '^DefaultIM' /home/winter/.config/fcitx5/profile 2>/dev/null | head -1 | cut -d= -f2)
ck "默认输入法 = rime" "rime" "${DIM:-无}" test "$DIM" = "rime"
IME=$(grep -c 'GTK_IM_MODULE=fcitx' /etc/environment 2>/dev/null)
ck "GTK_IM_MODULE=fcitx" ">=1" "$IME" test "$IME" -ge 1
echo "【USB 外接显示器 (MS91xx)】"
UD=$(ls /lib/modules/"$(uname -r)"/updates/msdisp/usbdisp_drm.ko* >/dev/null 2>&1 && echo yes || echo no)
ck "usbdisp_drm 模块已装" "yes" "$UD" test "$UD" = "yes"
UDL=$(lsmod | grep -c usbdisp_drm)
ck "usbdisp_drm 已加载" ">=1" "$UDL" test "$UDL" -ge 1
MSD=$(readlink -f /sys/class/drm/card1/device/driver 2>/dev/null | xargs -r basename)
ck "DRM card1 驱动" "msdisp_plat" "${MSD:-无}" test "$MSD" = "msdisp_plat"
HDMI=$(ls -d /sys/class/drm/card1-HDMI-A-* 2>/dev/null | wc -l)
ck "HDMI 输出连接器" ">=1" "$HDMI" test "$HDMI" -ge 1
UDC=$(ls /etc/modules-load.d/raphael-msdisp.conf >/dev/null 2>&1 && echo yes || echo no)
ck "开机自动加载已配置" "yes" "$UDC" test "$UDC" = "yes"
echo "【GPU】"
# drop-in 在用户级且单元名是 plasma-* (KDE 6 的单元名), 不是系统级 kwin_wayland
NOB=$(grep -rh FD_MESA_DEBUG /etc/systemd/user/ /etc/environment /home/*/.config/systemd/user/ 2>/dev/null | grep -c noubwc)
ck "FD_MESA_DEBUG=noubwc (全局+KWin)" ">=2 处" "$NOB" test "$NOB" -ge 2
KWIN=$(sudo -u winter env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
      systemctl --user show-environment 2>/dev/null | grep -c "FD_MESA_DEBUG=noubwc")
ck "KWin 运行环境已继承" "1" "$KWIN" test "$KWIN" -ge 1
echo "【Wi-Fi】"
IF=$(ip -br link show wld0 2>/dev/null | wc -l)
ck "wld0 存在" "1" "$IF" test "$IF" -ge 1
IP=$(ip -4 addr show wld0 2>/dev/null | grep -oE "inet [0-9.]+" | head -1 | cut -d' ' -f2)
ck "wld0 已获取 IP" "非空" "${IP:-无}" test -n "$IP"
echo "【存储/软件】"
# findmnt -o SUBVOL 在这台机器上返回空, 直接看 fstab / 挂载来源更可靠
FSTAB=$(grep -c "subvol=/@" /etc/fstab 2>/dev/null)
ck "btrfs @/@home/@swap 三子卷" "3" "$FSTAB" test "$FSTAB" -ge 3
MNT=$(findmnt -n / | grep -c "btrfs")
ck "根挂载是 btrfs" "1" "$MNT" test "$MNT" -ge 1
ck "swap 已启用" "1" "$(swapon --show --noheadings 2>/dev/null | wc -l)" test "$(swapon --show --noheadings 2>/dev/null | wc -l)" -ge 1
echo ""
echo "═══════ 结果: 通过 $PASS, 失败 $FAIL ═══════"
exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
