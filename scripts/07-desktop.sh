#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 07 — 桌面环境配置 (可多选; 一个都不选 = 纯命令行)
#  装哪些桌面由 config/build.conf 的 DESKTOPS 决定:
#    plasma-mobile / plasma-desktop / phosh / gnome   (顺序 = 自动登录优先级)
#  本阶段做四件事:
#    1) 选了桌面: 字体优先级 + SDDM 登录界面 (自动登录进 DESKTOPS 第一个会话)
#    2) 每个桌面的用户级预置 (Plasma / Phosh / GNOME 各自一段)
#    3) 与桌面无关的: 音频用户服务 / 蓝牙 / 调制解调器 / 电源键
#    4) 纯命令行: 不装不启用登录器, 默认 multi-user.target, 清掉增量重建的旧残留
#  登录界面统一用 SDDM: 装了哪个桌面它就列出哪个会话, 登录时可随便切。
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount
setup_qemu_shim

confirm_stage "07 配置桌面环境 ($DE_SUMMARY)"
HOME_DIR="/home/$USERNAME"
USERDIR="$ROOT$HOME_DIR"

if [ "$HAVE_ANY_DE" = 1 ]; then
# ---------------------------------------------------------------------------
# 1. 中文字体优先级 (fontconfig) — 否则中文会掉进无 CJK 的字体里
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/etc/fonts"
cat > "$ROOT/etc/fonts/local.conf" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias><family>sans-serif</family><prefer>
    <family>Noto Sans</family><family>Noto Sans CJK SC</family>
    <family>Source Han Sans CN</family><family>WenQuanYi Micro Hei</family>
  </prefer></alias>
  <alias><family>serif</family><prefer>
    <family>Noto Serif</family><family>Noto Serif CJK SC</family>
  </prefer></alias>
  <alias><family>monospace</family><prefer>
    <family>Noto Sans Mono</family><family>Noto Sans Mono CJK SC</family>
  </prefer></alias>
  <match target="pattern"><test name="lang" compare="contains"><string>zh</string></test>
    <edit name="family" mode="prepend" binding="strong"><string>Noto Sans CJK SC</string></edit>
  </match>
</fontconfig>
EOF
gq /usr/bin/fc-cache -f >/dev/null 2>&1 && log "字体缓存已重建"

# ---------------------------------------------------------------------------
# 2. SDDM: 登录界面列出所有已装会话, 自动登录进 DESKTOPS 里的第一个
#   ★ 装了哪个桌面, /usr/share/wayland-sessions/ 里就有哪个 .desktop:
#       plasma-mobile.desktop (startplasmamobile) / plasma.desktop / phosh.desktop
#       (phosh-session) / gnome.desktop (gnome-session) —— SDDM 会自动列出来,
#     所以"多选桌面"不需要额外配置, 登录时选一次即可 (RememberLastSession)。
# ---------------------------------------------------------------------------
log "配置 SDDM (会话: $DE_SUMMARY)"
mkdir -p "$ROOT/etc/sddm.conf.d"
cat > "$ROOT/etc/sddm.conf.d/10-raphael.conf" <<EOF
[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
Numlock=none
# 手机没有实体键盘: 登录界面必须自带触摸键盘 (qt6-virtualkeyboard),
# 否则一旦自动登录失败 (例如 pam_shells 拒绝 zsh) 就彻底进不去系统。
InputMethod=qtvirtualkeyboard

[Wayland]
DisplayServer=wayland
EOF
# 登录界面自己的 Wayland 合成器: KDE 形态用 kwin_wayland, 没有 KDE 就用 weston
if [ "$HAVE_KDE" = 1 ] && [ -x "$ROOT/usr/bin/kwin_wayland" ]; then
  echo "CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1" \
    >> "$ROOT/etc/sddm.conf.d/10-raphael.conf"
else
  # SDDM 的默认值就是它; 这里显式写出来, 免得以后默认变了没人发现
  echo "CompositorCommand=weston --shell=kiosk" >> "$ROOT/etc/sddm.conf.d/10-raphael.conf"
fi
# 主题/光标: breeze 是 KDE 带的, 没有 KDE 就用 SDDM 自带主题 (写不存在的主题会黑屏)
if [ -d "$ROOT/usr/share/sddm/themes/breeze" ]; then
  cat >> "$ROOT/etc/sddm.conf.d/10-raphael.conf" <<'EOF'

[Theme]
Current=breeze
CursorTheme=breeze_cursors
EOF
else
  log "  未装 KDE 的 breeze 主题 -> SDDM 用自带主题 (elarun)"
fi
cat >> "$ROOT/etc/sddm.conf.d/10-raphael.conf" <<'EOF'

[Users]
MaximumUid=60000
RememberLastSession=true
RememberLastUser=true
EOF
if [ "$AUTOLOGIN" = "true" ] && [ -n "$PRIMARY_SESSION" ]; then
  cat >> "$ROOT/etc/sddm.conf.d/10-raphael.conf" <<EOF

[Autologin]
User=$USERNAME
Session=$PRIMARY_SESSION
Relogin=false
EOF
  log "  已启用自动登录 -> $USERNAME / $DE_SUMMARY (第一个: $PRIMARY_SESSION)"
fi
mkdir -p "$ROOT/var/lib/sddm"
chown 0:0 "$ROOT/var/lib/sddm" 2>/dev/null || true
enable_unit sddm.service
gq /usr/bin/systemctl --root=/ set-default graphical.target >/dev/null 2>&1 \
  && log "  默认启动目标: graphical.target" || warn "  set-default graphical 失败"

# 多装几个桌面时提示一下自动登录进哪个 (用户可能想换顺序)
case "$DESKTOPS" in *" "*)
  log "  提示: 装了多个桌面 (${DESKTOPS// /, }), 自动登录用第一个 ($PRIMARY_SESSION);"
  log "        换顺序就改 config/build.conf 的 DESKTOPS, 或登录界面里手动选一次 (会记住)"
  ;;
esac

# ---------------------------------------------------------------------------
# 3. Plasma (KDE) 用户级默认配置 —— 只有选了 plasma-mobile / plasma-desktop 才做
# ---------------------------------------------------------------------------
if [ "$HAVE_KDE" = 1 ]; then
log "写入 Plasma 默认配置 ($HOME_DIR)"
mkdir -p "$USERDIR/.config"
# 锁屏策略按形态区分:
#   * 手机形态: 不自动锁屏 (没物理键盘时会把自己锁在外面, 真机踩过)
#   * 桌面形态: **开启**自动锁屏 (当电脑用需要), 10 分钟无操作锁屏
#   注: Timeout 的单位是**分钟** (KDE「安全 -> 屏幕锁定」里的那个)
if [ "$HAVE_PLASMA_DESKTOP" = 1 ]; then
  cat > "$USERDIR/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=true
Timeout=10
LockOnResume=true
EOF
  log "  锁屏: 桌面形态已开启自动锁屏 (10 分钟)"
else
  cat > "$USERDIR/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
fi
# 关闭 PowerDevil 的自动挂起 (sm8150 主线只有 s2idle, 挂起不可靠);
# 键名取自 PowerDevilProfileSettings.kcfg (6.7.5):
#   [<Profile>][SuspendAndShutdown] AutoSuspendAction / AutoSuspendIdleTimeoutSec / PowerButtonAction
#   PowerButtonAction: 0=NoAction 1=Sleep 8=Shutdown 16=PromptLogoutDialog 32=LockScreen
#                      64=TurnOffScreen 128=ToggleScreenOnOff
cat > "$USERDIR/.config/powerdevilrc" <<'EOF'
[AC][SuspendAndShutdown]
AutoSuspendAction=0
AutoSuspendIdleTimeoutSec=0
PowerButtonAction=128

[AC][Display]
TurnOffDisplayWhenIdle=true
TurnOffDisplayIdleTimeoutSec=120
DimDisplayWhenIdle=false

[Battery][SuspendAndShutdown]
AutoSuspendAction=0
AutoSuspendIdleTimeoutSec=0
PowerButtonAction=128

[Battery][Display]
TurnOffDisplayWhenIdle=true
TurnOffDisplayIdleTimeoutSec=120
EOF
# Plasma Mobile 缩放: 1080x2340 的 6.39 寸屏幕, 1.0 已经偏小
cat > "$USERDIR/.config/kdeglobals" <<'EOF'
[General]
font=Noto Sans,10,-1,5,50,0,0,0,0,0
fixed=Noto Sans Mono,10,-1,5,50,0,0,0,0,0
menuFont=Noto Sans,10,-1,5,50,0,0,0,0,0
toolBarFont=Noto Sans,10,-1,5,50,0,0,0,0,0
[KDE]
SingleClick=true

[Icons]
Theme=breeze
EOF
# 手机形态专属 (选了 plasma-mobile 才有意义)
if [ "$HAVE_PLASMA_MOBILE" = 1 ]; then
  # 移动端主屏缩放 (Plasma Mobile 读这个键)
  cat > "$USERDIR/.config/plasmamobile" <<'EOF'
[general]
mobileTaskSwitcher=true
EOF
fi

# 触摸屏上的虚拟键盘 (plasma-keyboard)。
# ★ 只写 InputMethod[$e] 一个键, 不要同时写 [Wayland] VirtualKeyboardEnabled/
#   VirtualKeyboardMode —— 两个都在会互相抢输入: 键盘弹得出来但字进不了输入框
#   (真机实测, 见 HANDOVER §5.5)。InputMethod[$e] 才是 KWin 认的那个。
cat > "$USERDIR/.config/kwinrc" <<'EOF'
[Wayland]
InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop
EOF
log "  已把 KWin 的虚拟键盘指向 plasma-keyboard"

# 关掉 Plasma Mobile 的"初始设置向导" (plasma-mobile-initial-start)。
# 它的开关在 ~/.config/plasmamobilerc 的 [InitialStart] wizardRun。
# 不清掉它的话每次登录都会弹一次; 想看可以手动跑:
#   plasma-mobile-initial-start --test-wizard
if [ "$HAVE_PLASMA_MOBILE" = 1 ]; then
  cat > "$USERDIR/.config/plasmamobilerc" <<'EOF'
[InitialStart]
wizardRun=true
EOF
  log "  已关闭 Plasma Mobile 初始设置向导"
fi

# (不装 fcitx5 / Rime: 触摸屏输入交给 plasma-keyboard, 见 config/build.conf 的说明)
fi   # ← HAVE_KDE

# ---------------------------------------------------------------------------
# 4. GNOME 系桌面 (Phosh / GNOME) 的系统级默认值
#   ★ 为什么用 dconf 系统库而不是 gsettings: 构建期没有用户会话/dbus,
#     gsettings 写不进用户库; dconf 的 system-db 是"系统默认值", 用户登录后生效
#     (用户自己改过的键以用户的为准)。
#   ★ /etc/dconf/profile/user 必须自己建: dconf 包只带 /etc/dconf/db/ 占位,
#     没有 profile 文件时 system-db:local 根本不会被读取。
# ---------------------------------------------------------------------------
if [ "$HAVE_PHOSH" = 1 ] || [ "$HAVE_GNOME" = 1 ]; then
  install -d "$ROOT/etc/dconf/db/local.d" "$ROOT/etc/dconf/profile"
  cat > "$ROOT/etc/dconf/profile/user" <<'EOF'
user-db:user
system-db:local
EOF
  # 触摸屏: 聚焦输入框时自动弹屏幕键盘 (GNOME Shell 用自带 OSK, Phosh 用 squeekboard)
  cat > "$ROOT/etc/dconf/db/local.d/00-raphael" <<'EOF'
[org/gnome/desktop/a11y/applications]
screen-keyboard-enabled=true
EOF
  if [ "$HAVE_GNOME" = 1 ]; then
    # 1080x2340 的 6.39 寸屏: 1 倍缩放偏小。打开分数缩放的实验特性后,
    # 用户能在「设置 → 显示器」里选 125%/150% (这里不预设, 免得猜错比例)
    cat >> "$ROOT/etc/dconf/db/local.d/00-raphael" <<'EOF'

[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']
EOF
  fi
  if [ -x "$ROOT/usr/bin/dconf" ]; then
    gq /usr/bin/dconf update >/dev/null 2>&1 && log "  dconf 系统默认值已编译" \
      || warn "  dconf update 失败 (登录后 dconf 会自己生成, 影响不大)"
  else
    warn "  没找到 dconf, 跳过系统默认值编译"
  fi
  log "  $DE_SUMMARY: 屏幕键盘自动弹出 + 系统默认值已写入 /etc/dconf"
fi

# ---------------------------------------------------------------------------
# 4b. Phosh 专用修复 (2026-10-11 真机逐层定位, 三处缺一不可)
#   ① 内核: 这台设备的 msm/dpu 在 wlroots 的 atomic 提交路径上会失败
#      (phoc: connector DSI-1: Atomic commit failed) -> 会话包装里走 legacy 路径
#   ② 环境: squeekboard / xdg-desktop-portal-* 是 systemd **用户服务**, 拿不到
#      WAYLAND_DISPLAY 就 "无法打开显示" 然后 abort -> 包装脚本里 import-environment
#   ③ wlroots: layer-shell 的"高度 0 必须同时锚 TOP+BOTTOM"校验挡住了 phosh 的
#      home bar (详见 lib.sh 里 patch_wlroots_layer_shell 的注释) -> 二进制补丁
#   三处都做完之后, 真机上 phosh 能正常起来: 会话 active、squeekboard 不崩、
#   0 个失败单元 (2026-10-11 用户确认屏幕可用)。
#   ★ 想让 Phosh 当默认会话: DESKTOPS 里把它写在第一个 (顺序 = 自动登录优先级)
# ---------------------------------------------------------------------------
if [ "$HAVE_PHOSH" = 1 ]; then
  install -d "$ROOT/usr/local/bin"
  cat > "$ROOT/usr/local/bin/phosh-session-wrapper" <<'PSEOF'
#!/bin/bash
# Phosh 会话包装 (raphael):
#   * WLR_DRM_NO_ATOMIC=1 —— 本机内核的 atomic 提交会让 phoc 起不来
#   * 等 phoc 建好 wayland socket 后, 把 WAYLAND_DISPLAY 导入 systemd 用户管理器,
#     否则 squeekboard / 各 portal 会 "无法打开显示" 直接 abort
export WLR_DRM_NO_ATOMIC=1
rt="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
(
  for _ in $(seq 1 300); do
    s="$(ls "$rt"/wayland-[0-9] 2>/dev/null | head -1)"
    if [ -n "$s" ]; then
      systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR >/dev/null 2>&1
      systemctl --user reset-failed >/dev/null 2>&1
      break
    fi
    sleep 0.1
  done
) &
exec /usr/bin/phosh-session
PSEOF
  chmod 755 "$ROOT/usr/local/bin/phosh-session-wrapper"
  if [ -f "$ROOT/usr/share/wayland-sessions/phosh.desktop" ]; then
    sed -i 's|^Exec=.*|Exec=/usr/local/bin/phosh-session-wrapper|'         "$ROOT/usr/share/wayland-sessions/phosh.desktop"
    log "  phosh 会话已包装 (NO_ATOMIC + 导入 WAYLAND_DISPLAY)"
  else
    warn "  没找到 phosh.desktop (phosh 包装未生效)"
  fi
  patch_wlroots_layer_shell "$ROOT" && log "  wlroots layer-shell 补丁已应用" \
    || warn "  wlroots 补丁未应用 —— phosh 的 home bar 会被判协议错误, 会话起不来"
fi

else   # ← HAVE_ANY_DE = 0: 纯命令行 (DESKTOPS 为空)
# ---------------------------------------------------------------------------
# 4'. 纯命令行: 不装显示管理器、不开图形目标
#   增量重建 (work/root 还在) 时, 上一版可能留下 SDDM 的 enable 软链和配置:
#   必须显式清掉 —— 否则开机时 systemd 会去拉一个已经不存在的单元, 直接多一个
#   failed, 而且会停在"等待图形界面"上。
# ---------------------------------------------------------------------------
log "纯命令行模式 (DESKTOPS 为空): 不启用任何显示管理器"
for f in etc/systemd/system/display-manager.service \
         etc/systemd/system/multi-user.target.wants/sddm.service \
         etc/systemd/system/graphical.target.wants/sddm.service \
         etc/systemd/system/sddm.service; do
  rm -f "$ROOT/$f"
done
rm -f "$ROOT/etc/sddm.conf.d/10-raphael.conf"
gq /usr/bin/systemctl --root=/ set-default multi-user.target >/dev/null 2>&1 \
  && log "  默认启动目标: multi-user.target (文本控制台)" \
  || warn "  set-default multi-user 失败 (Arch 默认图形目标, 手动改一下)"
log "  登录方式: SSH (sshd 已启用) 或接 OTG 键盘用控制台; 想要桌面就重新构建时选桌面"
fi   # ← HAVE_ANY_DE

# ---------------------------------------------------------------------------
# 5. 用户会话的音频服务 (PipeWire / WirePlumber) — 与桌面选择无关
# ★ 必须显式 enable: 构建时 pacman 跳过了 scriptlet/hook, 发行版的 user preset
#   没有执行, 用户家目录里没有任何 systemd 用户单元 -> 三个服务全不启动 ->
#   表现为 "系统里有声音选项, 但一个声音设备都没有" (真机踩过)。
#   这几条软链等价于 systemctl --user enable --now pipewire.socket \
#   pipewire-pulse.socket wireplumber.service
# ---------------------------------------------------------------------------
mkdir -p "$USERDIR/.config/systemd/user/sockets.target.wants" \
         "$USERDIR/.config/systemd/user/pipewire.service.wants"
ln -sfn /usr/lib/systemd/user/pipewire.socket \
        "$USERDIR/.config/systemd/user/sockets.target.wants/pipewire.socket"
ln -sfn /usr/lib/systemd/user/pipewire-pulse.socket \
        "$USERDIR/.config/systemd/user/sockets.target.wants/pipewire-pulse.socket"
ln -sfn /usr/lib/systemd/user/wireplumber.service \
        "$USERDIR/.config/systemd/user/pipewire.service.wants/wireplumber.service"
ln -sfn /usr/lib/systemd/user/wireplumber.service \
        "$USERDIR/.config/systemd/user/pipewire-session-manager.service"
log "  已启用音频用户服务 (pipewire / pipewire-pulse / wireplumber)"

chown -R 1000:1000 "$USERDIR" 2>/dev/null || true

# 让 Plasma 首启动不弹向导/欢迎页 (只在装了 Plasma 时有意义)
if [ "$HAVE_KDE" = 1 ]; then
  mkdir -p "$ROOT/etc/xdg"
  cat > "$ROOT/etc/xdg/plasmashellrc" <<'EOF'
[General]
ShowedWelcomeScreen=true
EOF
  cat > "$ROOT/etc/xdg/plasma-welcomerc" <<'EOF'
[General]
published=false
EOF
fi

# ---------------------------------------------------------------------------
# 6. 其它服务
# ---------------------------------------------------------------------------
log "启用蓝牙 / 调制解调器 / 传感器 / 时间同步"
enable_unit bluetooth.service
enable_unit ModemManager.service
if [ -f "$ROOT/usr/lib/systemd/system/iio-sensor-proxy.service" ]; then
  enable_unit iio-sensor-proxy.service
fi
enable_unit chronyd.service
if [ -f "$ROOT/usr/lib/systemd/system/systemd-timesyncd.service" ]; then
  mask_unit systemd-timesyncd.service
fi

# ---------------------------------------------------------------------------
# 7. 电源键守护 (短按熄屏 / 长按关机) —— 与桌面选择无关, 但启用策略有关
# ---------------------------------------------------------------------------
log "安装电源键守护进程"
cat > "$ROOT/usr/local/sbin/raphael-power-key.py" <<'PYEOF'
#!/usr/bin/env python3
"""电源键处理: 短按熄屏/亮屏, 长按 1.5 秒关机。

三条通路, 按可用性依次回退:
  1. org.freedesktop.ScreenSaver (KDE 的 kscreenlocker / GNOME Shell 都实现) —— 最省事
  2. logind 的 Lock/Unlock (GNOME / Phosh 一定支持) —— 会话锁屏即熄屏
  3. kscreen-doctor --dpms (只有在 KDE 且上面都不可用时兜底)
logind 已设 HandlePowerKey=ignore, 由本进程接管电源键。
"""
import logging, os, select, struct, subprocess, sys, threading, time

EV_KEY, KEY_POWER = 0x01, 116
FMT = "llHHi"
SIZE = struct.calcsize(FMT)
LONG_PRESS = 1.5
USER = os.environ.get("RAPHAEL_USER", "USERNAME_PLACEHOLDER")

logging.basicConfig(level=logging.INFO, format="power-key: %(message)s", stream=sys.stdout)
log = logging.getLogger("power-key")


def user_env():
    import pwd
    try:
        uid = pwd.getpwnam(USER).pw_uid
    except KeyError:
        return None
    runtime = f"/run/user/{uid}"
    if not os.path.exists(runtime):
        return None
    env = os.environ.copy()
    env.update({"HOME": f"/home/{USER}", "USER": USER, "LOGNAME": USER,
                "XDG_RUNTIME_DIR": runtime,
                "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/bus"})
    return env


def find_device():
    from pathlib import Path
    for name_path in sorted(Path("/sys/class/input").glob("input*/name")):
        try:
            if name_path.read_text().strip() == "pm8941_pwrkey":
                num = name_path.parent.name.replace("input", "")
                dev = Path(f"/dev/input/event{num}")
                if dev.exists():
                    return str(dev)
        except OSError:
            continue
    return None


def saver_active(env):
    try:
        r = subprocess.run(["gdbus", "call", "--session", "--dest",
                            "org.freedesktop.ScreenSaver", "--object-path", "/ScreenSaver",
                            "--method", "org.freedesktop.ScreenSaver.GetActive"],
                           env=env, capture_output=True, text=True, timeout=3)
        return "(true" in r.stdout
    except Exception:
        return None


def set_active(active, env):
    subprocess.run(["gdbus", "call", "--session", "--dest",
                    "org.freedesktop.ScreenSaver", "--object-path", "/ScreenSaver",
                    "--method", "org.freedesktop.ScreenSaver.SetActive",
                    "true" if active else "false"],
                   env=env, timeout=5, check=False)


def user_sessions():
    """当前用户的 logind 会话 id 列表 (本进程是 root, 不能用 loginctl 的 self)"""
    try:
        r = subprocess.run(["loginctl", "show-user", USER, "-p", "Display", "--value"],
                           capture_output=True, text=True, timeout=3)
        return [s for s in r.stdout.split() if s]
    except Exception:
        return []


def locked_hint(sid):
    try:
        r = subprocess.run(["loginctl", "show-session", sid, "-p", "LockedHint", "--value"],
                           capture_output=True, text=True, timeout=3)
        return r.stdout.strip() == "yes"
    except Exception:
        return None


def toggle_screen():
    env = user_env()
    if env is None:
        return
    cur = saver_active(env)
    if cur is None:
        # 没有 freedesktop ScreenSaver 接口 (GNOME/Phosh 常见) -> 用 logind:
        # 锁屏就是熄屏, 解锁就是亮屏 (两者都实现了 Session.Lock/Unlock)
        sessions = user_sessions()
        if sessions:
            sid = sessions[0]
            locked = locked_hint(sid)
            if locked is not None:
                action = "unlock-session" if locked else "lock-session"
                subprocess.run(["loginctl", action, sid], timeout=5, check=False)
                return
        # 最后的兜底: KDE 直接切 DPMS
        if os.path.exists("/usr/bin/kscreen-doctor"):
            subprocess.run(["kscreen-doctor", "--dpms", "off"], env=env, timeout=5, check=False)
        return
    set_active(not cur, env)


def power_off():
    log.info("long press -> poweroff")
    subprocess.run(["systemctl", "poweroff"], check=False)


def main():
    dev = find_device()
    if not dev:
        log.error("找不到 pm8941_pwrkey 设备, 退出 (不影响开机)")
        return 0
    log.info("监听 %s (短按熄屏, 长按 %.1fs 关机)", dev, LONG_PRESS)
    ev = open(dev, "rb", buffering=0)
    pressed_at = None
    while True:
        data = ev.read(SIZE)
        if not data or len(data) < SIZE:
            time.sleep(0.2)
            continue
        _, _, etype, code, value = struct.unpack(FMT, data)
        if etype != EV_KEY or code != KEY_POWER:
            continue
        if value == 1:            # 按下
            pressed_at = time.monotonic()
        elif value == 0 and pressed_at is not None:   # 抬起
            held = time.monotonic() - pressed_at
            pressed_at = None
            if held >= LONG_PRESS:
                power_off()
            else:
                toggle_screen()


if __name__ == "__main__":
    sys.exit(main())
PYEOF
sed -i "s/USERNAME_PLACEHOLDER/$USERNAME/" "$ROOT/usr/local/sbin/raphael-power-key.py"
chmod 755 "$ROOT/usr/local/sbin/raphael-power-key.py"

cat > "$ROOT/etc/systemd/system/raphael-power-key.service" <<EOF
[Unit]
Description=raphael power key handler (short press = screen off, long press = poweroff)
After=multi-user.target

[Service]
Type=simple
Environment=RAPHAEL_USER=$USERNAME
ExecStart=/usr/local/sbin/raphael-power-key.py
# 找不到电源键设备时正常退出, 不要疯狂重启
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
if [ "$HAVE_KDE" = 1 ]; then
  # KDE 有 PowerDevil 自己处理电源键 (powerdevilrc 里 PowerButtonAction=128 切屏),
  # 两个一起接管会重复触发 -> 默认不启用本守护。
  # 要用就 systemctl enable --now raphael-power-key, 同时把 powerdevilrc 的
  # PowerButtonAction 改成 0。
  log "已安装电源键守护 (KDE 的 PowerDevil 已接管电源键, 默认不启用)"
else
  # GNOME / Phosh / 纯命令行 都没有 PowerDevil: 不启用的话电源键完全没反应
  # (06 阶段把 logind 的 HandlePowerKey 设成了 ignore)
  enable_unit raphael-power-key.service
  log "已安装并启用电源键守护 (短按熄屏, 长按 1.5 秒关机)"
fi

log "桌面环境配置完成 ($DE_SUMMARY)"

# ---------------------------------------------------------------------------
# 13. Shorin 指南对齐 (终端美化 + 中文输入法 + KDE 自定义)
#   ★ 2026-10-10: 这一整段是 KDE/Plasma 专属 (Konsole/kdeglobals/kwin/plasma-keyboard),
#     而且 13.10 紧接着又把它撤掉了。为了不让 phosh/GNOME/纯命令行 的构建白跑一遍
#     (git clone oh-my-zsh、下 Catppuccin 配色、写一堆马上就删的 KDE 配置),
#     整段只在选了 KDE 桌面时执行。代码保留, 想恢复个性化删掉这个 if 即可。
# ---------------------------------------------------------------------------
if [ "$HAVE_KDE" = 1 ]; then
H="$ROOT/home/$USERNAME"
install -d "$H/.config" "$H/.local/share" "$H/.local/state"

# 13.1 32 位源 multilib (准备篇: 玩 Windows 软件/Steam 需要)
if [ -f "$ROOT/etc/pacman.conf" ] && ! grep -q '^\[multilib\]' "$ROOT/etc/pacman.conf"; then
  sed -i 's/^#\[multilib\]/[multilib]/; s/^#Include = \/etc\/pacman.d\/mirrorlist/Include = \/etc\/pacman.d\/mirrorlist/' "$ROOT/etc/pacman.conf"
  log "pacman: 已开启 multilib (32 位源)"
fi

# 13.2 oh-my-zsh / oh-my-bash (构建期 clone, 离线可用)
for pair in "ohmyzsh/ohmyzsh:/usr/share/oh-my-zsh" "ohmybash/oh-my-bash:/usr/share/oh-my-bash"; do
  repo="${pair%%:*}"; dest="$ROOT${pair##*:}"
  if [ ! -d "$dest" ]; then
    log "克隆 $repo -> ${pair##*:}"
    git clone --depth=1 "https://github.com/$repo.git" "$dest" >/dev/null 2>&1 \
      || warn "克隆 $repo 失败 (网络?), 跳过"
  fi
done

# 13.3 ~/.zshrc (~/.bashrc): 历史记录 + 插件 + oh-my-* + starship
cat > "$H/.zshrc" <<'EOF'
# ---- Shorin 指南: zsh 历史记录与补全 ----
HISTFILE=~/.zsh_history
HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_DUPS HIST_IGNORE_SPACE SHARE_HISTORY APPEND_HISTORY EXTENDED_HISTORY
zstyle ':completion:*' menu select

# ---- oh-my-zsh (本地克隆, 不联网) ----
export ZSH=/usr/share/oh-my-zsh
ZSH_THEME=""                      # 提示符交给 starship, 避免与主题打架
plugins=(git z sudo extract)
[ -f "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"

# ---- 插件: 语法高亮 + 自动建议 (指南) ----
[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ] && \
  source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
[ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && \
  source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# ---- starship 提示符 ----
command -v starship >/dev/null && eval "$(starship init zsh)"

# ---- 常用别名 ----
alias ls='ls --color=auto' ll='ls -lah' grep='grep --color=auto'
alias 更新='sudo pacman -Syu' 快照='sudo snapper -c root create -d "手动快照"'
alias 回档='btrfs-assistant-launcher' 电池='upower -i $(upower -e | grep BAT)'
EOF
cat > "$H/.bashrc" <<'EOF'
# ---- oh-my-bash (本地克隆, 不联网) ----
export OSH=/usr/share/oh-my-bash
[ -f "$OSH/oh-my-bash.sh" ] && source "$OSH/oh-my-bash.sh"
command -v starship >/dev/null && eval "$(starship init bash)"
alias ls='ls --color=auto' ll='ls -lah'
alias 更新='sudo pacman -Syu' 快照='sudo snapper -c root create -d "手动快照"'
EOF

# 13.4 starship 预设 (Nerd 图标风格)
cat > "$H/.config/starship.toml" <<'EOF'
# 简洁 + Nerd 图标; 预设参考 https://starship.rs/presets/
add_newline = true
[character]
success_symbol = "[\$](bold green)"
error_symbol = "[\$](bold red)"
[directory]
truncation_length = 3
truncate_to_repo = true
style = "bold cyan"
[git_branch]
symbol = " "
[cmd_duration]
min_time = 500
format = "took [$duration]($style) "
[os]
disabled = true
EOF

# 13.5 默认 shell 改成 zsh (bash 仍完整可用)
if [ -x "$ROOT/usr/bin/zsh" ]; then
  gq /usr/bin/chsh -s /usr/bin/zsh "$USERNAME" >/dev/null 2>&1 && log "默认 shell: zsh" || warn "chsh 失败"
fi
# ★ 必须把 zsh 写进 /etc/shells: pam_shells (SDDM 自动登录走 sddm-autologin 栈)
#   会检查登录 shell 是否合法, 不在 /etc/shells 里就直接 "User has an invalid shell"
#   -> Autologin failed -> 只能停在登录界面 (而手机没有实体键盘, 等于进不去系统)。
if ! grep -qx '/usr/bin/zsh' "$ROOT/etc/shells" 2>/dev/null; then
  echo '/usr/bin/zsh' >> "$ROOT/etc/shells"
  log "  /etc/shells += /usr/bin/zsh (自动登录需要)"
fi

# 13.6 Konsole 美化 (指南: 隐藏标题栏/工具栏 + Catppuccin Frappe + 20% 透明 + WenKai Mono 15pt)
KS="$H/.local/share/konsole"; install -d "$KS"
CS="$KS/CatppuccinFrappe.colorscheme"
if [ ! -s "$CS" ]; then
  for u in "https://raw.githubusercontent.com/catppuccin/konsole/main/themes/catppuccin-frappe.colorscheme" \
           "https://raw.githubusercontent.com/catppuccin/konsole/main/catppuccin-frappe.colorscheme"; do
    fetch "$u" "$DL/catppuccin-frappe.colorscheme" 2>/dev/null && break
  done
  [ -s "$DL/catppuccin-frappe.colorscheme" ] && cp -f "$DL/catppuccin-frappe.colorscheme" "$CS"
fi
cat > "$KS/Shorin.profile" <<'EOF'
[Appearance]
ColorScheme=CatppuccinFrappe
Font=LXGW WenKai Mono,15,-1,5,50,0,0,0,0,0
[General]
Name=Shorin
Parent=Default.profile
TerminalColumns=100
TerminalRows=30
[Interaction Options]
AutoCopySelectedText=true
[Scrolling]
ScrollBarPosition=2
HighlightScrolledLines=false
[Terminal Features]
BlinkingCursorEnabled=true
EOF
cat > "$H/.config/konsolerc" <<'EOF'
[Desktop Entry]
DefaultProfile=Shorin.profile
[TabBar]
NewTabButtonVisibility=2
[MainWindow]
MenuBar=Disabled
ToolBarsMovable=Disabled
EOF

# 13.7 KDE 自定义 (指南: 我的 KDE 自定义设置) — 能落文件的都预置
cat > "$H/.config/kdeglobals" <<'EOF'
[General]
Font=LXGW WenKai,11,-1,5,50,0,0,0,0,0
FixedFont=JetBrainsMono Nerd Font,10,-1,5,50,0,0,0,0,0
ToolbarFont=LXGW WenKai,10,-1,5,50,0,0,0,0,0
MenuFont=LXGW WenKai,11,-1,5,50,0,0,0,0,0
[KDE]
SingleClick=false
[Icons]
Theme=breeze-dark
EOF
cat > "$H/.config/kcminputrc" <<'EOF'
[Mouse]
cursorSize=30
cursorTheme=breeze_cursors
EOF
cat > "$H/.config/kwinrc" <<'EOF'
[Plugins]
wobblywindowsEnabled=true
translucencyEnabled=true
kwin4_effect_geometry_changeEnabled=true
[Effect-wobblywindows]
Stiffness=25
Drag=70
MoveFactor=15
[Compositing]
AnimationSpeed=3
[Wayland]
# ★ 必须是 plasma-keyboard: 写 fcitx 会让 KWin 去拉 fcitx5 当输入法
#   (而镜像里已经不装 fcitx5 了 -> 键盘会反复闪退)
InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop
EOF
cat > "$H/.config/kglobalshortcutsrc" <<'EOF'
[krunner.desktop]
_run=Meta+Z,none,KRunner
[org.kde.konsole.desktop]
_newWindow=Meta+T,none,Konsole
[systemsettings.desktop]
_launch=Ctrl+Alt+S,none,系统设置
[kwin]
Window Close=Meta+Q,none,关闭窗口
Window Kill=Meta+Ctrl+Q,none,强制终止窗口
Window Maximize=Meta+F,none,最大化窗口
Window Minimize=Meta+H,none,最小化窗口
Window Fullscreen=Meta+Alt+F,none,全屏显示窗口
Window Quick Tile Left=Meta+A,none,快速铺放: 左
Window Quick Tile Right=Meta+D,none,快速铺放: 右
Window Quick Tile Top=Meta+W,none,快速铺放: 上
Window Quick Tile Bottom=Meta+S,none,快速铺放: 下
Window Move Center=Meta+C,none,移动窗口到中央
Show Desktop=Meta+M,none,暂时显示桌面
Overview=Meta,none,显示桌面总览
EOF
cat > "$H/.config/spectaclerc" <<'EOF'
[General]
autoSaveImage=true
clipboardGroup=PostScreenshotCopyImage
launchOnStartup=false
EOF

# 13.8 中文输入法
#  ★ 2026-10-01 真机踩坑: 手机只有触屏键盘。正确做法是给合成器设
#    QT_IM_MODULES=qtvirtualkeyboard (见 06 阶段的 /etc/environment 与注释),
#    而不是给应用设单数 QT_IM_MODULE —— plasma-keyboard 明确说客户端侧不支持。
#    镜像里**不装 fcitx5** (会和触屏键盘抢输入法, 真机实测会闪退); 外接物理
#    键盘想用中州韵的用户自己装 fcitx5 即可。
# 输入法环境: 不要把 QT_IM_MODULES 写进全局 (06 阶段的 /etc/environment 里没有它),
# 否则每个 Qt 程序都去加载虚拟键盘上下文 -> plasma-keyboard 弹出来就闪退。
# 正确做法是只给合成器:
#   1) kwin_wayland 用 systemd user drop-in 单独带上 QT_IM_MODULES
#   2) plasma-keyboard 是 kwin 的子进程会继承该变量, 启动时用 env -u 清掉
#      (带着它会走 "client-side" 那条 plasma-keyboard 自己声明不支持的路径)
rm -f "$H/.config/environment.d/ime.conf"
rmdir "$H/.config/environment.d" 2>/dev/null || true
install -d "$H/.config/systemd/user/plasma-kwin_wayland.service.d"
cat > "$H/.config/systemd/user/plasma-kwin_wayland.service.d/im.conf" <<'EOF'
# plasma-keyboard: "use QT_IM_MODULES=qtvirtualkeyboard at compositor-side"
# 只作用于 kwin_wayland 自己
[Service]
Environment=QT_IM_MODULES=qtvirtualkeyboard
EOF
KBD_DESKTOP="$ROOT/usr/share/applications/org.kde.plasma.keyboard.desktop"
if [ -f "$KBD_DESKTOP" ]; then
  [ -f "$KBD_DESKTOP.orig" ] || cp -n "$KBD_DESKTOP" "$KBD_DESKTOP.orig"
  sed -i 's|^Exec=plasma-keyboard$|Exec=env -u QT_IM_MODULES plasma-keyboard|' "$KBD_DESKTOP"
  grep -q 'env -u QT_IM_MODULES' "$KBD_DESKTOP" && log "  plasma-keyboard: Exec 已改为 env -u QT_IM_MODULES"
fi
# ★ 真机验证过的可用组合 (2026-10-01, 用户实测能打字):
#     InputMethod[$e] = org.kde.plasma.keyboard.desktop   (Plasma 键盘)
#   + kwin_wayland 单独带 QT_IM_MODULES=qtvirtualkeyboard  (合成器托管虚拟键盘)
#   + plasma-keyboard 启动时 env -u QT_IM_MODULES          (清掉继承值)
#   三者齐了才不闪退、字才进得了输入框。fcitx5 那条路在真机上不弹键盘。
#   换键盘实现: 系统设置 -> 虚拟键盘 (KCM 会改 kwinrc)。
KWINRC="$H/.config/kwinrc"
if [ -f "$ROOT/usr/share/applications/org.kde.plasma.keyboard.desktop" ] && [ -f "$KWINRC" ]; then
  if grep -q '^InputMethod\[\$e\]=' "$KWINRC"; then
    sed -i 's|^InputMethod\[\$e\]=.*|InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop|' "$KWINRC"
  else
    sed -i '/^\[Wayland\]/a InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop' "$KWINRC"
  fi
  log "  虚拟键盘: Plasma 键盘 (真机验证可用)"
fi

# ---------------------------------------------------------------------------
# 13.8b 桌面形态的中文输入法: fcitx5 + Rime (中州韵)
#   手机形态继续用 plasma-keyboard (上面那套, 真机验证可用); **桌面形态有物理
#   键盘**, 按用户要求换成 fcitx5 + Rime。
#   两者不能并存: 镜像里有 fcitx5 时 KWin 会去拉它当虚拟键盘, 和 plasma-keyboard
#   抢输入法 (真机实测触屏键盘闪退), 所以桌面形态把 KWin 的虚拟键盘关掉。
# ---------------------------------------------------------------------------
if [ "$HAVE_PLASMA_DESKTOP" = 1 ]; then
  # 1) KWin 不再托管虚拟键盘
  KWINRC="$H/.config/kwinrc"
  if [ -f "$KWINRC" ]; then
    if grep -q '^InputMethod\[\$e\]=' "$KWINRC"; then
      sed -i 's|^InputMethod\[\$e\]=.*|InputMethod[$e]=|' "$KWINRC"
    else
      sed -i '/^\[Wayland\]/a InputMethod[$e]=' "$KWINRC"
    fi
    log "  虚拟键盘: 桌面形态已关闭 KWin 虚拟键盘 (改用 fcitx5)"
  fi
  # plasma-keyboard 的 kwin_wayland drop-in 只给手机形态用
  rm -rf "$H/.config/systemd/user/plasma-kwin_wayland.service.d"
  # 2) 应用侧输入法环境 (fcitx5)
  if [ -f "$ROOT/etc/environment" ]; then
    sed -i '/^\(GTK_IM_MODULE\|QT_IM_MODULE\|XMODIFIERS\|SDL_IM_MODULE\)=/d' "$ROOT/etc/environment"
    cat >> "$ROOT/etc/environment" <<'ENVEOF'
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
SDL_IM_MODULE=fcitx
ENVEOF
    log "  输入法环境: GTK_IM_MODULE/QT_IM_MODULE/XMODIFIERS/SDL_IM_MODULE = fcitx"
  fi
  # 3) 默认输入法 = Rime (中州韵): 写进 skel + 现有用户家目录
  RIME_PROFILE='[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[GroupOrder]
0=Default'
  install -d "$ROOT/etc/skel/.config/fcitx5"
  printf '%s\n' "$RIME_PROFILE" > "$ROOT/etc/skel/.config/fcitx5/profile"
  if [ -d "$H" ]; then
    install -d "$H/.config/fcitx5"
    printf '%s\n' "$RIME_PROFILE" > "$H/.config/fcitx5/profile"
    chown -R "$(stat -c %u:%g "$H")" "$H/.config/fcitx5" 2>/dev/null || true
  fi
  log "  默认输入法: Rime (中州韵), 首次登录自动部署词库"
  # 4) 自启动 (fcitx5 包自带 autostart 就不重复写)
  if [ ! -f "$ROOT/etc/xdg/autostart/org.fcitx.Fcitx5.desktop" ]; then
    install -d "$ROOT/etc/xdg/autostart"
    cat > "$ROOT/etc/xdg/autostart/org.fcitx.Fcitx5.desktop" <<'DEOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Comment=Start fcitx5 input method
Exec=fcitx5 -d
Icon=fcitx
Terminal=false
Categories=System;Utility;
DEOF
    log "  已补 fcitx5 自启动项"
  fi
fi
# 中英文都要, 两个地方都得设:
#  (a) plasma-keyboard 自己的语言列表 —— 它在 QML 里用
#        VirtualKeyboardSettings.activeLocales = PlasmaKeyboardSettings.enabledLocales
#      直接**覆盖** Qt VK 的设置, 所以这个才是真正生效的 (语言键灰不灰就看它)。
#      配置文件名按 KDE 惯例 = 应用名 + rc -> plasma-keyboardrc。
#  (b) Qt 虚拟键盘自己的 settings.conf 作为兜底:
#      注意 QSettings 的 INI **等号两边不能有空格**, 否则整个键被忽略
#      (踩过: 写成 "activeLocales = en_US,zh_CN" 结果只剩系统默认的 zh_CN)
# ★★ 真机结论 (2026-10-02, 折腾了一整轮):
#   1) 语言列表的实际来源是 PlasmaKeyboardSettings.enabledLocales, 那是 KCM
#      (kcm_plasmakeyboard) 用 C++ API 写的; 手写 ~/.config/plasma-keyboardrc
#      **不生效** (strace 证明文件被打开过, 但值进不去);
#      Qt VK 自己的 ~/.config/qtvirtualkeyboard/settings.conf 它根本不读。
#      => 想加语言请走 GUI: 系统设置 -> 屏幕键盘 (On-Screen Keyboard) -> Languages
#         中英都勾上, 地球键才会变可点。
#   2) KConfig 的 QStringList 逗号分隔且 **不 trim 空格**:
#      "zh_CN, en_US" -> ["zh_CN", " en_US"] -> 第二个无效被丢掉
#      => 只剩一种语言 = 地球键变灰 (这就是之前"只能英文/只能中文"的原因)。
#      所以逗号后面绝对不能有空格。
cat > "$H/.config/plasma-keyboardrc" <<'EOF'
[General]
enabledLocales=zh_CN,en_US
EOF
# KDE 界面语言: 只写 [Formats] 不够, [Translations] 的 LANGUAGE 才决定界面语言
# (zh_CN 优先, 没中文翻译的界面回落到英文, 这是正常的)
cat > "$H/.config/plasma-localerc" <<'EOF'
[Formats]
LANG=zh_CN.UTF-8

[Translations]
LANGUAGE=zh_CN:en_US
EOF

# ---------------------------------------------------------------------------
# 音频格式固定 (2026-10-02 真机): 扬声器走 QUAT_MI2S -> TFA9874, 只有 2 声道;
# pro-audio profile 下 PipeWire 默认会按 8 声道打开, DSP 侧
#   qcom-q6afe: AFE enable for port 0x1006 failed -110   (ETIMEDOUT)
#   q6afe-dai: ASoC error (-110): at snd_soc_dai_prepare() on QUAT_MI2S_RX
# 每 3 秒刷一次, 表现就是"调音量就卡掉、扬声器没声音"。
# 固定成 2ch/S16LE/48k 并关闭节点挂起 (每次重开 PCM 都会重建 Q6 会话) 后就正常了。
install -d "$H/.config/wireplumber/wireplumber.conf.d"
cat > "$H/.config/wireplumber/wireplumber.conf.d/51-raphael-alsa.conf" <<'EOF'
monitor.alsa.rules = [
  {
    matches = [
      { node.name = "~alsa_output.*" }
    ]
    actions = {
      update-props = {
        audio.format = "S16LE"
        audio.rate = 48000
        audio.channels = 2
        session.suspend-timeout-seconds = 0
      }
    }
  }
]
EOF
log "  WirePlumber: 固定 2ch/S16LE/48k + 不挂起 (QUAT_MI2S 不吃 8 声道)"
log "  语言: 界面 zh_CN 优先 (英文兜底); 触屏键盘 zh_CN 默认 + 可切 en_US" 
rm -f "$H/.gtkrc-2.0"
for v in 3.0 4.0; do
  rm -f "$H/.config/gtk-$v/settings.ini"
done
# ★ 这里原本会写 fcitx5/Rime 的一堆配置 + fcitx5 自启。
#   现在镜像**不装 fcitx5** (见 config/build.conf), 这些东西写出来只会让 KWin
#   误以为有 fcitx5 可用而反复切过去 -> 屏幕键盘闪退, 所以整段去掉。
#   想用中州韵的用户自己装 fcitx5 后, 这些配置可以按上游文档重新加。
# 桌面形态装了 fcitx5+Rime, 这些"清残留"的动作必须跳过
if [ "$HAVE_PLASMA_DESKTOP" != 1 ]; then
  rm -f "$H/.config/autostart/fcitx5.desktop" 2>/dev/null || true
  rm -rf "$H/.config/fcitx5" "$H/.local/share/fcitx5" 2>/dev/null || true
fi

# 13.9 修复 home 属主 (07 阶段新建的文件)
chown -R 1000:1000 "$H" 2>/dev/null || true
log "Shorin 对齐 (终端/输入法/KDE) 完成"
fi   # ← HAVE_KDE (13.1~13.9)

# ---------------------------------------------------------------------------
# 13.10 ★ 去掉 Shorin 指南带来的"个性化"覆盖 (2026-10-01 用户要求)
#   用户反馈: 加了这套个性化之后开机变慢、而且和触屏键盘打架。
#   这里只做"把个性化配置撤掉、回到 KDE/系统默认", **不卸载任何包**
#   (字体 / zsh / fcitx5 / konsole 都还在, 想用随时手动开)。
#   要恢复个性化: 删掉本段即可 (上面的生成逻辑仍然完整保留)。
#   ★ 本段对所有形态都跑 (纯命令行 / phosh / GNOME 也一样): 它的作用是清理
#     增量重建时上一版留下的个性化文件, 属于卫生工作, 不是"配置桌面"。
# ---------------------------------------------------------------------------
H="$USERDIR"          # 13.1~13.9 被跳过时 H 没定义过
log "撤销 Shorin 个性化覆盖 (保留包本身)"
# 1) 字体/光标/快捷键/截图/星舰提示符/Konsole 覆盖 -> 回默认
for f in kdeglobals kcminputrc kglobalshortcutsrc spectaclerc starship.toml konsolerc; do
  rm -f "$H/.config/$f"
done
rm -rf "$H/.local/share/konsole"
# 2) kwin 特效 (wobbly / geometry change) + fcitx 输入法
#    ★ 13.7 又写过一遍带特效的 kwinrc, 这里必须覆盖回来: 只留 InputMethod[$e]。
#      两个都在 (VirtualKeyboard= + InputMethod=) 会互相抢输入 —— 键盘弹得出来
#      但字进不了输入框; 特效那段也是"个性化", 用户明确要求撤掉。
rm -f "$H/.config/kwineffectsrc" 2>/dev/null || true
rm -f "$H/.config/kwinrc"
if [ "$HAVE_KDE" = 1 ]; then
  mkdir -p "$H/.config"
  # 桌面形态用 fcitx5 -> KWin 不托管虚拟键盘 (留空); 手机形态仍指向 plasma-keyboard
  if [ "$HAVE_PLASMA_DESKTOP" = 1 ]; then
    _ime_line='InputMethod[$e]='
  else
    _ime_line='InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop'
  fi
  printf '[Wayland]\n%s\n' "$_ime_line" > "$H/.config/kwinrc"
fi
# 3) oh-my-zsh / oh-my-bash 主题: 换朴素 rc (先备份成 .shorin-bak 便于用户自己找回来)
for rc in .zshrc .bashrc; do
  [ -e "$H/$rc" ] && mv "$H/$rc" "$H/$rc.shorin-bak" 2>/dev/null
done
cat > "$H/.zshrc" <<'ZEOF'
# 朴素配置 (Shorin 的 oh-my-zsh 主题已移除; 旧文件见 .zshrc.shorin-bak)
export EDITOR=nvim
export VISUAL=nvim
alias ls='ls --color=auto'
alias ll='ls -lh'
ZEOF
cat > "$H/.bashrc" <<'BEOF'
# 朴素配置 (Shorin 的 oh-my-bash 主题已移除; 旧文件见 .bashrc.shorin-bak)
export EDITOR=nvim
export VISUAL=nvim
alias ls='ls --color=auto'
alias ll='ls -lh'
BEOF
# 4) fcitx5: 镜像里已经不装了, 这里只做残留清理 (老镜像升级上来的情况)
if [ "$HAVE_PLASMA_DESKTOP" != 1 ]; then
  rm -f "$H/.config/autostart/fcitx5.desktop" 2>/dev/null || true
  rm -f "$H/.config/autostart/fcitx5.desktop.disabled" 2>/dev/null || true
fi
# 5) 息屏自动变暗也关掉 (花屏最容易复现的路径), 见 raphael-display-nopm.service
kwriteconfig6 --file powerdevilrc --group AC --group DimDisplay --key idleTime --delete 2>/dev/null || true
# 6) GTK/fcitx 那套输入法环境 (会和触屏键盘抢输入)
rm -f "$H/.gtkrc-2.0" "$H/.config/gtk-3.0/settings.ini" "$H/.config/gtk-4.0/settings.ini"
chown -R 1000:1000 "$H/.config" "$H/.local" 2>/dev/null || true
log "Shorin 个性化已撤销 (包未卸载)"

# ---------------------------------------------------------------------------
# 13.11 收尾: 桌面形态的 fcitx5 + Rime 必须放在**所有"撤销个性化"动作之后**
#   (13.10 会 rm -rf 家目录里的 fcitx5 配置、重写 kwinrc —— 之前踩过: 写在前面
#    会被它清掉, 镜像里只剩 /etc/skel 那份)
# ---------------------------------------------------------------------------
if [ "$HAVE_PLASMA_DESKTOP" = 1 ]; then
  _rime='[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[GroupOrder]
0=Default'
  install -d "$ROOT/etc/skel/.config/fcitx5"
  printf '%s\n' "$_rime" > "$ROOT/etc/skel/.config/fcitx5/profile"
  if [ -d "$H" ]; then
    install -d "$H/.config/fcitx5"
    printf '%s\n' "$_rime" > "$H/.config/fcitx5/profile"
  fi
  # KWin 虚拟键盘留空 (fcitx5 接管)
  if [ "$HAVE_KDE" = 1 ] && [ -d "$H" ]; then
    mkdir -p "$H/.config"
    printf '[Wayland]\nInputMethod[$e]=\n' > "$H/.config/kwinrc"
  fi
  # fcitx5 自启动 (包自带就跳过)
  if [ ! -f "$ROOT/etc/xdg/autostart/org.fcitx.Fcitx5.desktop" ]; then
    install -d "$ROOT/etc/xdg/autostart"
    cat > "$ROOT/etc/xdg/autostart/org.fcitx.Fcitx5.desktop" <<'FEOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Comment=Start fcitx5 input method
Exec=fcitx5 -d
Icon=fcitx
Terminal=false
Categories=System;Utility;
FEOF
  fi
  chown -R 1000:1000 "$H/.config" 2>/dev/null || true
  log "  收尾: Rime 配置 + KWin 虚拟键盘留空 + fcitx5 自启动 已就位"
fi
