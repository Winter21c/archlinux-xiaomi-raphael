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
# 手机没有实体键盘: 登录界面必须自带触摸键盘 (qt6-virtualkeyboard),
# 否则一旦自动登录失败 (例如 pam_shells 拒绝 zsh) 就彻底进不去系统。
InputMethod=qtvirtualkeyboard

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

# ---------------------------------------------------------------------------
# 13. Shorin 指南对齐 (终端美化 + 中文输入法 + KDE 自定义)
# ---------------------------------------------------------------------------
H="$ROOT/home/winter"
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
  gq /usr/bin/chsh -s /usr/bin/zsh winter >/dev/null 2>&1 && log "默认 shell: zsh" || warn "chsh 失败"
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
InputMethod=fcitx
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
#    fcitx5 仍然装着, 想要物理键盘 + 中州韵时手动开即可。
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
# 中英文都要: Qt 虚拟键盘启用 en_US + zh_CN (自带 Pinyin 插件,
# 触屏键盘上有个语言键可以切; 中文直接打拼音出候选词)
install -d "$H/.config/qtvirtualkeyboard"
cat > "$H/.config/qtvirtualkeyboard/settings.conf" <<'EOF'
[VirtualKeyboard]
activeLocales=en_US,zh_CN
locale=en_US
EOF
log "  Qt 虚拟键盘语言: en_US + zh_CN (拼音)" 
# fcitx5 随会话自启 (虚拟键盘 + 拼音都需要它在跑)
install -d "$H/.config/autostart"
cat > "$H/.config/autostart/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Exec=fcitx5 -d
Icon=fcitx
X-GNOME-Autostart-Phase=Applications
X-KDE-autostart-after=panel
EOF
install -d "$H/.config/fcitx5/conf"
cat > "$H/.config/fcitx5/conf/virtualkeyboard.conf" <<'EOF'
# 触屏虚拟键盘
Enable=True
AutoShow=True
EOF
rm -f "$H/.gtkrc-2.0"
for v in 3.0 4.0; do
  rm -f "$H/.config/gtk-$v/settings.ini"
done
# fcitx5: 左右 Shift 都交给 Rime 处理 (指南: 右 Shift 切不回中文的修法)
install -d "$H/.config/fcitx5"
cat > "$H/.config/fcitx5/config" <<'EOF'
[Hotkey/AltTriggerKeys]
0=Shift_L
1=Shift_R
EOF
# Rime: 默认方案 = 雾凇拼音; F4 可切换多方案
install -d "$H/.local/share/fcitx5/rime"
cat > "$H/.local/share/fcitx5/rime/default.custom.yaml" <<'EOF'
patch:
  # rime_ice_suggestion 是雾凇方案的默认预设 (指南写法)
  __include: rime_ice_suggestion:/
  schema_list:
    - schema: rime_ice
    - schema: luna_pinyin_simp
    - schema: double_pinyin_flypy
    - schema: wubi86
EOF
cat > "$H/.local/share/fcitx5/rime/rime_ice.custom.yaml" <<'EOF'
patch:
  # 默认英文标点 (指南可选): switches/@1/reset=1 -> 第二个开关「中英标点」默认英文
  "switches/@1/reset": 1
EOF
cat > "$H/.local/share/fcitx5/rime/custom_phrase.txt" <<'EOF'
# encoding: utf-8
# 自定义词库: 词语<TAB>拼音<TAB>可选权重(越大越靠前)
# 示例: 异环	yihuan	100
EOF
# 输入法自启 (KDE 虚拟键盘在系统设置里选 fcitx5, 这里保证进程一定起来)
install -d "$H/.config/autostart"
cat > "$H/.config/autostart/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Exec=fcitx5 -d
Icon=fcitx
X-GNOME-Autostart-Phase=Applications
X-KDE-autostart-after=panel
EOF

# 13.9 修复 home 属主 (07 阶段新建的文件)
chown -R 1000:1000 "$H" 2>/dev/null || true
log "Shorin 对齐 (终端/输入法/KDE) 完成"

# ---------------------------------------------------------------------------
# 13.10 ★ 去掉 Shorin 指南带来的"个性化"覆盖 (2026-10-01 用户要求)
#   用户反馈: 加了这套个性化之后开机变慢、而且和触屏键盘打架。
#   这里只做"把个性化配置撤掉、回到 KDE/系统默认", **不卸载任何包**
#   (字体 / zsh / fcitx5 / konsole 都还在, 想用随时手动开)。
#   要恢复个性化: 删掉本段即可 (上面的生成逻辑仍然完整保留)。
# ---------------------------------------------------------------------------
log "撤销 Shorin 个性化覆盖 (保留包本身)"
# 1) 字体/光标/快捷键/截图/星舰提示符/Konsole 覆盖 -> 回默认
for f in kdeglobals kcminputrc kglobalshortcutsrc spectaclerc starship.toml konsolerc; do
  rm -f "$H/.config/$f"
done
rm -rf "$H/.local/share/konsole"
# 2) kwin 特效 (wobbly / geometry change) + InputMethod=fcitx
#    触屏键盘靠 KCM 写的 [Wayland] InputMethod[$e]=...plasma.keyboard.desktop,
#    不要同时写 VirtualKeyboard= (两个都在会抢输入: 键盘弹得出来但字进不了输入框)
rm -f "$H/.config/kwinrc"
mkdir -p "$H/.config"
cat > "$H/.config/kwinrc" <<'KEOF'
[Wayland]
InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop
KEOF
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
# 4) fcitx5 自启: 关掉 (它会抢 Wayland 输入法, 也让触屏键盘输不进字)
if [ -e "$H/.config/autostart/fcitx5.desktop" ]; then
  mv "$H/.config/autostart/fcitx5.desktop" "$H/.config/autostart/fcitx5.desktop.disabled"
fi
# 5) 息屏自动变暗也关掉 (花屏最容易复现的路径), 见 raphael-display-nopm.service
kwriteconfig6 --file powerdevilrc --group AC --group DimDisplay --key idleTime --delete 2>/dev/null || true
# 6) GTK/fcitx 那套输入法环境 (会和触屏键盘抢输入)
rm -f "$H/.gtkrc-2.0" "$H/.config/gtk-3.0/settings.ini" "$H/.config/gtk-4.0/settings.ini"
chown -R 1000:1000 "$H/.config" "$H/.local" 2>/dev/null || true
log "Shorin 个性化已撤销 (包未卸载)"
