#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Copyright (C) 2026 Winter21c <https://github.com/Winter21c>
# ============================================================================
#  阶段 07 — KDE Plasma 桌面 + Plasma Mobile 配置
#  两个会话同时安装, 登录界面可切换:
#    plasma-mobile.desktop -> startplasmamobile   (手机形态, 默认)
#    plasma.desktop        -> startplasma-wayland (桌面形态)
# ============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_ns
ns_mount
setup_qemu_shim

confirm_stage "07 配置 KDE Plasma / Plasma Mobile"
HOME_DIR="/home/$USERNAME"
USERDIR="$ROOT$HOME_DIR"

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
# 2. SDDM: 自动登录到 Plasma Mobile (手机形态), 桌面会话可手动切换
# ---------------------------------------------------------------------------
log "配置 SDDM"
mkdir -p "$ROOT/etc/sddm.conf.d"
cat > "$ROOT/etc/sddm.conf.d/10-raphael.conf" <<EOF
[General]
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
Numlock=none

[Theme]
Current=breeze
CursorTheme=breeze_cursors

[Wayland]
DisplayServer=wayland
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1

[Users]
MaximumUid=60000
RememberLastSession=true
RememberLastUser=true
EOF
if [ "$AUTOLOGIN" = "true" ]; then
  cat >> "$ROOT/etc/sddm.conf.d/10-raphael.conf" <<EOF

[Autologin]
User=$USERNAME
Session=plasma-mobile
Relogin=false
EOF
  log "  已启用自动登录 -> $USERNAME / Plasma Mobile"
fi
mkdir -p "$ROOT/var/lib/sddm"
chown 0:0 "$ROOT/var/lib/sddm" 2>/dev/null || true
enable_unit sddm.service

# ---------------------------------------------------------------------------
# 3. 用户级 Plasma 默认配置 (手机场景)
# ---------------------------------------------------------------------------
log "写入 Plasma 默认配置 ($HOME_DIR)"
mkdir -p "$USERDIR/.config"
# 不自动锁屏 (手机上没有密码键盘时会很尴尬)
cat > "$USERDIR/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
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
# 移动端主屏缩放 (Plasma Mobile 读这个键)
cat > "$USERDIR/.config/plasmamobile" <<'EOF'
[general]
mobileTaskSwitcher=true
EOF

# 触摸设备上桌面会话也要能弹出虚拟键盘
# (KWin 6.7 的键名是 [Wayland] VirtualKeyboardEnabled / VirtualKeyboardMode,
#  0=Never 1=NonMouseInput 2=AnyInput; 网上流传的 kwinrc InputMethod= 是错的,
#  InputMethod= 其实是 SDDM 的键)
cat > "$USERDIR/.config/kwinrc" <<'EOF'
[Wayland]
VirtualKeyboardEnabled=true
VirtualKeyboardMode=1
EOF
log "  已为桌面会话启用虚拟键盘 (plasma-keyboard, 非鼠标输入时弹出)"

# 关掉 Plasma Mobile 的"初始设置向导" (plasma-mobile-initial-start)。
# 它的开关在 ~/.config/plasmamobilerc 的 [InitialStart] wizardRun。
# 不清掉它的话每次登录都会弹一次; 想看可以手动跑:
#   plasma-mobile-initial-start --test-wizard
cat > "$USERDIR/.config/plasmamobilerc" <<'EOF'
[InitialStart]
wizardRun=true
EOF

# Rime 输入法配置 (取自 Shorin 指南: Shift 交给 fcitx5 切中英)
mkdir -p "$USERDIR/.local/share/fcitx5/rime"
cat > "$USERDIR/.local/share/fcitx5/rime/default.custom.yaml" <<'EOF'
patch:
  # Shift 交给 fcitx5 的 AltTriggerKeys（rime/mozd ↔ keyboard-us），Rime 内部不再用 Shift 切中英
  "ascii_composer/switch_key/Shift_L": noop
  "ascii_composer/switch_key/Shift_R": noop
EOF
log "  已关闭初始设置向导 + 写入 Rime 配置"

# ---------------------------------------------------------------------------
# 启用用户会话的音频服务 (PipeWire / WirePlumber)
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

# 让 Plasma 首启动不弹向导/欢迎页
mkdir -p "$ROOT/etc/xdg"
cat > "$ROOT/etc/xdg/plasmashellrc" <<'EOF'
[General]
ShowedWelcomeScreen=true
EOF
cat > "$ROOT/etc/xdg/plasma-welcomerc" <<'EOF'
[General]
published=false
EOF

# ---------------------------------------------------------------------------
# 4. 其它服务
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
# 5. 电源键守护 (上游 GNOME 版无法在 KDE 上工作, 这里换成 freedesktop 版)
# ---------------------------------------------------------------------------
log "安装电源键守护进程"
cat > "$ROOT/usr/local/sbin/raphael-power-key.py" <<'PYEOF'
#!/usr/bin/env python3
"""电源键处理: 短按熄屏/亮屏, 长按 1.5 秒关机。
上游 Debian 版依赖 GNOME 的 org.gnome.ScreenSaver / SessionManager, 在 KDE 上
完全无效, 这里改用 freedesktop 标准接口 (kscreenlocker 实现了
org.freedesktop.ScreenSaver)。logind 已设 HandlePowerKey=ignore, 由本进程接管。
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


def toggle_screen():
    env = user_env()
    if env is None:
        return
    cur = saver_active(env)
    if cur is None:
        # 会话还没起来 / 没有 ScreenSaver -> 用 kscreen-doctor 直接切 DPMS
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
# 默认不启用: PowerDevil 6.7 自己会处理电源键 (PowerButtonAction=128 切换屏幕)。
# 如果发现电源键没反应, 用 systemctl enable --now raphael-power-key 启用本守护,
# 同时建议把 powerdevilrc 的 PowerButtonAction 改成 0 以免重复触发。
log "已安装电源键守护 (默认未启用): raphael-power-key.service"

log "KDE 配置完成"
