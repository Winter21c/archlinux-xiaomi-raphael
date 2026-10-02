# Plasma 6 Desktop + Plasma Mobile on Arch Linux ARM aarch64 — Xiaomi Redmi K20 Pro (`raphael`, SM8150)

Target: extract ALARM aarch64 rootfs, install packages with `pacman` into a **foreign root** (no chroot execution on the build host).
Scope of this document: the KDE/Plasma + phone-integration layer only.

## 0. Provenance / how every claim below was verified

| Claim type | How it was verified |
|---|---|
| Package exists + which repo + version | Recursive walk of `/tmp/alarm-core.db` + `/tmp/alarm-extra.db` (`desc` `%NAME%`/`%VERSION%`, `depends` `%DEPENDS%`/`%PROVIDES%`/`%OPTDEPENDS%`) |
| Full dependency closure resolvable | Custom resolver: every `%DEPENDS%` entry of every reachable package resolved against core+extra, including `%PROVIDES%` virtuals |
| Files a package installs (session `.desktop`, units, scripts) | **Real aarch64 packages downloaded from `http://mirror.archlinuxarm.org/aarch64/extra/` and `tar tf`-ed** |
| SDDM config keys/defaults | `usr/share/man/man5/sddm.conf.5.gz` **from the ALARM `sddm` package** |
| `kwinrc` / env-var behaviour | KWin upstream source (`raw.githubusercontent.com/KDE/kwin/master`) + `strings` on ALARM `kwin`/`libkwin.so.6.7.5` |
| PowerDevil keys/enums | `raw.githubusercontent.com/KDE/powerdevil/master` + `strings` on ALARM `powerdevil` binaries |
| logind keys/defaults | Local `/usr/share/man/man5/logind.conf.5.gz` (systemd 262) |
| Device facts (panel, touch, sensors, modem, idle states) | **`sm8150-xiaomi-raphael.dts` + `sm8150.dtsi` from the postmarketOS SM8150 kernel fork** — see §5.0 |

Legend used below: **[VERIFIED]** = read out of a package/db/source. **[V] PROVIDED-BY** = virtual name resolved via `%PROVIDES%`. **[MISSING]** = absent from core **and** extra. **[EXPECTED]** = upstream default, must be confirmed on device.

---

## 1. Exact package list (top-level names only)

`pacman` resolves the rest. **Closure of the list in §1.4 = 946 packages, all dependencies resolved within core+extra** (no unresolved dep). Install the *names*, not the closure.

### 1.1 Shared base

| Package | Repo | Version | Note |
|---|---|---|---|
| `plasma-workspace` | extra | 6.7.5-1 | session core, `startplasma-wayland` |
| `kwin` | extra | 6.7.5-1 | Wayland compositor (`kwin_wayland` **only**; no `kwin_x11`) |
| `plasma-integration` | extra | 6.7.5-1 | Qt platform theme |
| `kscreen` | extra | 6.7.5-1 | display/output config; **optdep** of both shells → must be explicit |
| `kde-cli-tools` | extra | 6.7.5-1 | `kstart`, `kwriteconfig6`, `kioclient` |
| `kwayland-integration` | extra | 6.7.5-1 | |
| `polkit-kde-agent` | extra | 6.7.5-1 | |
| `xdg-desktop-portal` | extra | 1.22.1-2 | |
| `xdg-desktop-portal-kde` | extra | 6.7.5-1 | |
| `breeze` | extra | 6.7.5-1 | icons/cursor/Plasma style |
| `plasma-workspace-wallpapers` | extra | 6.7.5-1 | |
| `qt6-wayland` | extra | 6.11.2-1 | |
| `qt6-svg` | extra | 6.11.2-1 | |
| `xorg-xwayland` | extra | 24.1.13-1 | needed to run any X11-only app under the Wayland session |
| `sddm` | extra | 0.21.0-7 | **or** `plasma-login-manager` — pick one (§3) |
| `sddm-kcm` | extra | 6.7.5-1 | KCM for SDDM; optional |
| `plasma-login-manager` | extra | 6.7.5-1 | **or** `sddm` — pick one (§3) |

Audio:

| Package | Repo | Version |
|---|---|---|
| `pipewire` | extra | 1:1.6.9-1 |
| `pipewire-pulse` | extra | 1:1.6.9-1 |
| `pipewire-alsa` | extra | 1:1.6.9-1 |
| `wireplumber` | extra | 0.5.17-2 |
| `alsa-utils` | extra | 1.2.16-1 |
| `plasma-pa` | extra | 6.7.5-1 | (also a hard dep of `plasma-mobile`) |

Network (Wi-Fi only — no ethernet on this device):

| Package | Repo | Version |
|---|---|---|
| `networkmanager` | extra | 1.58.1-1 |
| `plasma-nm` | extra | 6.7.5-1 |

Bluetooth (`raphael` uses a WCN3998 combo chip — see §5.0):

| Package | Repo | Version |
|---|---|---|
| `bluez` | extra | 5.87-2 |
| `bluez-utils` | extra | 5.87-2 |
| `bluedevil` | extra | 1:6.7.5-1 |

Power:

| Package | Repo | Version |
|---|---|---|
| `powerdevil` | extra | 6.7.5-2 |
| `upower` | extra | 1.91.4-1 |
| `power-profiles-daemon` | extra | 0.30-1 |

On-screen keyboard (**see §5.3 — this is the load-bearing choice**):

| Package | Repo | Version | Note |
|---|---|---|---|
| `plasma-keyboard` | extra | 6.7.5-1 | KDE Plasma 6 OSK, Qt6. **This is the one to use.** |
| `qt6-virtualkeyboard` | extra | 6.11.2-1 | pulled in as a hard dep of `plasma-keyboard` |
| `maliit-keyboard` | — | — | **[MISSING]** not in core or extra. Do not reference it. |
| `maliit-framework` | — | — | **[MISSING]** |
| `maliit-framework-gtk` | — | — | **[MISSING]** |
| `plasma-maliit-framework` | extra | 0.99.0.20150710-4 | **Do NOT install.** Depends on `qt5-declarative`, `kwayland`, `karchive` → Qt5/KF5-era Plasma Mobile 1 stack, incompatible with Plasma 6 |
| `plasma-maliit-plugins` | extra | 0.99.0.20150710-2 | **Do NOT install.** Same reason |

Closest existing alternatives for "maliit": **`plasma-keyboard`** (native Plasma 6, what upstream uses now) or **`qt6-virtualkeyboard`** standalone. `plasma-maliit-*` exist but are 2015-era Qt5 packages and are not usable with Plasma 6.

Fonts (incl. CJK):

| Package | Repo | Version |
|---|---|---|
| `noto-fonts` | extra | 1:2026.09.01-1 |
| `noto-fonts-cjk` | extra | 20240730-1 |
| `noto-fonts-emoji` | extra | 1:2.051-1 |
| `ttf-dejavu` | extra | 2.37+18+g9b5d1b2f-8 |
| `wqy-zenhei` | extra | 0.9.45-10 |

> **Trap avoided:** `plasma-desktop` hard-depends on `emoji-font`. There is **no** package named `emoji-font` **[MISSING]** — it is a virtual name **[V] PROVIDED-BY `noto-fonts-emoji`**. So `noto-fonts-emoji` is *mandatory*, not optional, or `plasma-desktop` will not resolve.
> Alternative CJK font (pick per taste, both exist): `adobe-source-han-sans-cn-fonts` extra 2.005-2, `ttf-arphic-uming` extra 0.2.20080216.2-3. `ttf-hanazono` **[MISSING]**.

CJK **input method** (fonts are not enough to type Chinese):

| Package | Repo | Version |
|---|---|---|
| `fcitx5` | extra | 5.1.23-1 |
| `fcitx5-qt` | extra | 5.1.16-1 |
| `fcitx5-chinese-addons` | extra | 5.1.15-1 |
| `fcitx5-configtool` | extra | 5.1.16-2 |

(`fcitx5-mozc` extra 3.34.6239.2-1 for Japanese; `ibus` extra 1.5.34-1 as an alternative framework.)

File manager + terminal:

| Package | Repo | Version | Fits |
|---|---|---|---|
| `dolphin` | extra | 26.08.1-1 | desktop |
| `kio-extras` | extra | 26.08.1-2 | thumbnails, mtp, sftp for Dolphin |
| `konsole` | extra | 26.08.1-1 | desktop |
| `qmlkonsole` | extra | 26.08.1-1 | **mobile touch terminal** |
| `index-fm` | extra | 4.0.2-2 | **mobile touch file manager** |
| `ark` | extra | 26.08.1-1 | archives |

Secrets / misc:

| Package | Repo | Version |
|---|---|---|
| `kwallet` | extra | 6.30.0-1 |
| `kwallet-pam` | extra | 6.7.5-1 |
| `ksshaskpass` | extra | 6.7.5-1 |

Graphics:

| Package | Repo | Version | Note |
|---|---|---|---|
| `mesa` | extra | 1:26.2.3-1 | provides the `msm`/freedreno driver for Adreno 640 |
| `mesa-utils` | extra | 9.0.0-7 | `eglinfo`, `glxinfo` — your debug tools |
| `vulkan-freedreno` | extra | 1:26.2.3-1 | Turnip (Vulkan 1.3 on Adreno 6xx) |

Sensor helper — include only if you want the daemon present; **it will not produce any sensor on this device** (§4.3):

| Package | Repo | Version |
|---|---|---|
| `iio-sensor-proxy` | extra | 3.9-1 |

### 1.2 Plasma Desktop session (usable on a phone screen)

| Package | Repo | Version | Note |
|---|---|---|---|
| `plasma-desktop` | extra | 6.7.5-1 | pulls `plasma-workspace`, `kmenuedit`, `xdg-user-dirs`, `libwacom`, `polkit-kde-agent`, `systemsettings`(no) etc. |
| `systemsettings` | extra | 6.7.5-1 | |
| `kinfocenter` | extra | 6.7.5-1 | |
| `plasma-systemmonitor` | extra | 6.7.5-1 | |
| `kde-gtk-config` | extra | 6.7.5-1 | GTK theme sync |
| `breeze-gtk` | extra | 6.7.5-1 | GTK counterpart to Breeze |
| `gwenview` | extra | 26.08.1-1 | image viewer |
| `okular` | extra | 26.08.1-1 | document viewer |
| `kdeconnect` | extra | 26.08.1-1 | |

`plasma-desktop`'s **optdepends** `bluedevil`, `kscreen`, `plasma-nm`, `plasma-pa` are *not* pulled automatically — they are already in §1.1, which is why §1.1 must be installed too.

**X11 desktop session is optional and you almost certainly do not want it:**

| Package | Repo | Version | Note |
|---|---|---|---|
| `plasma-x11-session` | extra | 6.7.5-1 | ships `usr/share/xsessions/plasmax11.desktop` |
| `kwin-x11` | extra | 6.7.5-1 | provides `kwin_x11` |

Without those two there is **no X11 session at all** — `plasma-workspace` ships `usr/share/xsessions/` as an **empty directory** [VERIFIED]. KDE removed X11 from the default session; see §5.4.

### 1.3 Plasma Mobile session

| Package | Repo | Version | Note |
|---|---|---|---|
| `plasma-mobile` | extra | 6.7.5-1 | the mobile shell; hard-deps pull `plasma-nano`, `plasma-keyboard`, `plasma-nm`, `plasma-pa`, `powerdevil`, `milou`, `modemmanager-qt`, `kpipewire` |
| `plasma-settings` | extra | 26.08.1-1 | **optdep** of `plasma-mobile` → must be explicit |
| `plasma-nano` | extra | 6.7.5-1 | pulled as a hard dep; listed for clarity |
| `milou` | extra | 6.7.5-1 | pulled as a hard dep (search) |
| `modemmanager` | extra | 1.24.2-1 | |
| `modemmanager-qt` | extra | 6.30.0-1 | pulled as a hard dep |
| `koko` | extra | 26.08.1-1 | mobile image gallery |
| `angelfish` | extra | 26.08.1-1 | mobile web browser |
| `kclock` | extra | 26.08.1-1 | alarms/clocks |
| `kalk` | extra | 26.08.1-1 | calculator |
| `kweather` | extra | 26.08.1-1 | weather |
| `neochat` | extra | 26.08.1-1 | Matrix client (optional) |
| `kasts` | extra | 26.08.1-1 | podcasts (optional) |

**Mobile packages that do NOT exist [MISSING]** — do not put these in a package list:

| Wanted | Status | Closest alternative |
|---|---|---|
| `plasma-camera` | **exists** (extra 26.08.1-1) but is **UNINSTALLABLE** — see §1.5 | none in these repos |
| `spacebar` | **[MISSING]** | no SMS app available in core/extra |
| `plasma-dialer` | **[MISSING]** | no dialer available |
| `ofono` | **[MISSING]** | `modemmanager` extra 1.24.2-1 is the only telephony stack present |
| `megapixels` | **[MISSING]** | camera app is AUR/pmOS-only |

### 1.4 Install command (foreign root, no chroot)

The list is exactly §1.1 + §1.2 + §1.3 minus the two "pick one" DM duplicates and minus `plasma-camera`.

```bash
ROOT=/mnt/alarm            # extracted ALARM aarch64 rootfs
CONF=$ROOT/etc/pacman.conf

# --noscriptlet is REQUIRED: install scriptlets cannot run without chroot.
# --arch aarch64 is REQUIRED on an x86_64 build host.
# --dbpath must be the TARGET's pacman db, not the host's.
pacman --root "$ROOT" \
       --dbpath "$ROOT/var/lib/pacman" \
       --cachedir "$ROOT/var/cache/pacman/pkg" \
       --config "$CONF" \
       --arch aarch64 \
       --noscriptlet \
       -Sy --needed --noconfirm \
       plasma-workspace kwin plasma-integration kscreen kde-cli-tools \
       kwayland-integration polkit-kde-agent xdg-desktop-portal xdg-desktop-portal-kde \
       breeze plasma-workspace-wallpapers qt6-wayland qt6-svg xorg-xwayland \
       plasma-login-manager \
       pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils plasma-pa \
       networkmanager plasma-nm \
       bluez bluez-utils bluedevil \
       powerdevil upower power-profiles-daemon \
       plasma-keyboard \
       noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-dejavu wqy-zenhei \
       fcitx5 fcitx5-qt fcitx5-chinese-addons fcitx5-configtool \
       dolphin kio-extras konsole qmlkonsole index-fm ark \
       kwallet kwallet-pam ksshaskpass \
       mesa mesa-utils vulkan-freedreno iio-sensor-proxy \
       plasma-desktop systemsettings kinfocenter plasma-systemmonitor \
       kde-gtk-config breeze-gtk gwenview okular kdeconnect \
       plasma-mobile plasma-settings koko angelfish kclock kalk kweather
```

Because `--noscriptlet` skips `systemd-sysusers`/`tmpfiles`/`gtk-update-icon-cache`/`update-desktop-database`, do these **after first boot** (chrooted or booted):

```bash
systemd-sysusers                 # creates the plasmalogin system user, etc.
systemd-tmpfiles --create
gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
update-desktop-database -q /usr/share/applications || true
ldconfig
```

### 1.5 Blocker found during validation: `libcamera` is uninstallable

- `libcamera` extra 0.7.2-4 has `%DEPENDS%` on **`libpisp`**.
- **`libpisp` does not exist in core or extra** [MISSING].
- Therefore `libcamera`, and everything that hard-depends on it, **cannot be installed**: `plasma-camera`, `libcamera-ipa`, `libcamera-tools`, `gst-plugin-libcamera`.
- `pipewire` is **not** affected: for pipewire, libcamera is only `%OPTDEPENDS%` (`pipewire-libcamera`). Audio installs fine.

Consequence: **no camera application.** Re-check the ALARM `extra` db for `libpisp` before shipping; if it appears, `plasma-camera` becomes installable.

---

## 2. Session files and exact `Exec=` lines

All paths and `Exec` values below were **read out of the real ALARM aarch64 packages** [VERIFIED].

### `/usr/share/wayland-sessions/`

| File | Owning package | `Exec=` |
|---|---|---|
| `plasma.desktop` | `plasma-workspace` | `/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland` |
| `plasma-mobile.desktop` | `plasma-mobile` | `/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasmamobile` |

`plasma.desktop` also sets `TryExec=/usr/bin/startplasma-wayland`, `DesktopNames=KDE`, `Name=Plasma (Wayland)`.
`plasma-mobile.desktop` also sets `TryExec=/usr/bin/startplasmamobile`, `DesktopNames=KDE`, `Name=Plasma Mobile`, `X-KDE-PluginInfo-Version=6.7.5`.

> **Answer to "startplasma-wayland vs `plasmashell --shell=org.kde.plasma.mobile`": neither of those two literally.** The mobile session entry point is **`/usr/bin/startplasmamobile`**, which `export`s the mobile environment and then **calls `startplasma-wayland`**. Do not hand-write a `plasmashell --shell=…` session file. `startplasmamobile` is a shell script [VERIFIED] that does, in order:

```sh
[ -f /etc/profile ] && . /etc/profile
export QT_QPA_PLATFORMTHEME=KDE
export EGL_PLATFORM=wayland
export QT_QUICK_CONTROLS_STYLE=org.kde.breeze
export QT_ENABLE_GLYPH_CACHE_WORKAROUND=1
export QT_QUICK_CONTROLS_MOBILE=true
export PLASMA_INTEGRATION_USE_PORTAL=1
export PLASMA_PLATFORM=phone:handset
export XDG_CONFIG_DIRS="$HOME/.config/plasma-mobile:/etc/xdg:$XDG_CONFIG_DIRS"
grep -q '/systemd-coredump' /proc/sys/kernel/core_pattern && export KDE_COREDUMP_NOTIFY=1
QT_QPA_PLATFORM=offscreen plasma-mobile-envmanager --apply-settings
export PLASMA_DEFAULT_SHELL=org.kde.plasma.mobileshell
startplasma-wayland
```

Consequences worth designing around:
- **`PLASMA_PLATFORM=phone:handset`** and **`QT_QUICK_CONTROLS_MOBILE=true`** are the actual "make it a phone" switches — you do **not** need to set them yourself for the mobile session; but you *do* need them if you ever launch mobile apps from the desktop session.
- **`EGL_PLATFORM=wayland`** is forced.
- **`XDG_CONFIG_DIRS` prepends `$HOME/.config/plasma-mobile`** → drop mobile-era config overrides in `~/.config/plasma-mobile/`.
- The shell is selected by **`PLASMA_DEFAULT_SHELL=org.kde.plasma.mobileshell`**; the matching shell package lives at `/usr/share/plasma/shells/org.kde.plasma.mobileshell/` [VERIFIED, shipped by `plasma-mobile`]. Therefore **`plasma-mobile` is required** for the mobile shell; `plasma-nano` alone is not the shell.

### `/usr/share/xsessions/`

| File | Owning package | `Exec=` |
|---|---|---|
| `plasmax11.desktop` | `plasma-x11-session` | `/usr/bin/startplasma-x11` |
| *(none)* | `plasma-workspace` | ships `usr/share/xsessions/` **empty** [VERIFIED] |

Note the filename is **`plasmax11.desktop`**, *not* `plasma.desktop`. `plasma-x11-session` is a separate 8 KB package; it is not installed unless you ask for it.

### Display managers ship no session files

Neither `sddm` 0.21.0-7 nor `plasma-login-manager` 6.7.5-1 ships anything under `wayland-sessions/`/`xsessions/` [VERIFIED]. Both **enumerate** the system dirs (paths in §3).

---

## 3. Switching between Desktop and Mobile at login

### 3.1 Recommendation for a touch-only phone

**Use `plasma-login-manager` (`plasmalogin`), not SDDM** — but note the prerequisite in §3.4.

Reasoning, grounded in what the packages actually contain:

| Criterion | `sddm` 0.21.0-7 | `plasma-login-manager` 6.7.5-1 |
|---|---|---|
| Written for Plasma 6 / Qt6 | Partly — fork predates Plasma 6; themes are Qt6-port era | Yes, forked from SDDM by KDE specifically for Plasma 6 |
| On-screen keyboard on the greeter | `[General] InputMethod=qtvirtualkeyboard` (greeter is Qt, so `qt6-virtualkeyboard` works) | Upstream goal is first-class **virtual keyboards** and **CJK input** at the greeter (stated in its README) |
| HiDPI / phone-sized greeter | `EnableHiDPI=true`; themes are desktop-shaped | Greeter is a Plasma/QML surface; scales with Plasma |
| Session picker lists both Plasma + Plasma Mobile | Yes (reads `wayland-sessions/`) | Yes (reads `wayland-sessions/`) |
| Autologin | `[Autologin] User=/Session=/Relogin=` | Same keys (SDDM fork) + `/etc/plasmalogin.conf` |
| systemd integration | `sddm.service` (`Alias=display-manager.service`) | `plasmalogin.service` (`Alias=display-manager.service`) |
| Depends on `plasma-workspace` | No | **Yes** |
| Needs X server | **Yes** — `%DEPENDS%` includes `xorg-server`, `xorg-xauth` | No X dependency; pure Wayland greeter |

SDDM pulling `xorg-server` + `xorg-xauth` and defaulting to `DisplayServer=x11` is exactly what you do not want on this device.

**However — for a first bring-up, prefer `sddm` if you want maximum familiarity/debuggability**; both are validated installable. The switching mechanism is identical for both because both read the same `/usr/share/wayland-sessions/`.

### 3.2 `/etc/sddm.conf.d/` — exact contents

Config precedence [VERIFIED from `sddm.conf.5`]: `/usr/lib/sddm/sddm.conf.d` → **`/etc/sddm.conf.d`** → `/etc/sddm.conf` (highest). SDDM ships **no** `/etc/sddm.conf`, so you create it.

`/etc/sddm.conf.d/10-raphael.conf`:

```ini
[General]
# CRITICAL: SDDM defaults to "x11". Valid: x11 | x11-user | wayland
DisplayServer=wayland
# On-screen keyboard on the GREETER (the greeter is Qt -> qt6-virtualkeyboard).
# NOTE: the real key is InputMethod=, NOT VirtualKeyboard=.
InputMethod=qtvirtualkeyboard
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot

[Wayland]
# CRITICAL: the default is "weston --shell=kiosk" -- weston is not installed here.
# The greeter needs its own Wayland compositor; use kwin (installed with plasma-workspace).
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
SessionDir=/usr/local/share/wayland-sessions,/usr/share/wayland-sessions
SessionCommand=/usr/share/sddm/scripts/wayland-session
SessionLogFile=.local/share/sddm/wayland-session.log
EnableHiDPI=true

[Theme]
Current=
CursorTheme=breeze_cursors
EnableAvatars=false

[Users]
MinimumUid=1000
HideUsers=plasmalogin
RememberLastUser=true
RememberLastSession=true
```

`/etc/sddm.conf.d/20-autologin.conf` (start the mobile session without touching the screen):

```ini
[Autologin]
User=user
# Value = basename of the .desktop file in wayland-sessions/, WITHOUT the .desktop suffix
Session=plasma-mobile
Relogin=false
```

Switching sessions later is then just editing that one `Session=` value to `plasma` (desktop) or `plasma-mobile`, or picking it in the greeter's session menu.

### 3.3 `/etc/plasmalogin.conf` — exact contents

Upstream [VERIFIED from the plasma-login-manager README]: "/etc/plasmalogin.conf, which overrides distro-provided defaults at /usr/lib/plasmalogin/defaults.conf".

```ini
# /etc/plasmalogin.conf
[Autologin]
User=user
Session=plasma-mobile
Relogin=false

[General]
# plasmalogin is a Wayland-native greeter; no DisplayServer key is needed.
InputMethod=qtvirtualkeyboard

[Theme]
CursorTheme=breeze_cursors
EnableAvatars=false
```

Enable one and only one (see §3.4):

```bash
systemctl disable sddm.service
systemctl enable plasmalogin.service
systemd-sysusers            # REQUIRED: creates the plasmalogin system user
```

### 3.4 Gotcha: both managers alias `display-manager.service`

```ini
# sddm.service / plasmalogin.service both contain:
[Install]
Alias=display-manager.service
```

**Neither package declares `%CONFLICTS%`** [VERIFIED from both `desc` files], so pacman will happily install both *and* both can be "enabled" — the second enable overwrites the `display-manager.service` symlink. Always `systemctl disable` the one you are leaving. Use `systemctl status display-manager` to see which one actually owns the alias.

Also note `plasma-login-manager` installs PAM files into **`/usr/lib/pam.d/`** (not `/etc/pam.d/`) [VERIFIED]; if your rootfs has an `/etc/pam.d` that is not overlaid, confirm plasmalogin's PAM stack resolves before relying on it.

---

## 4. Phone-specific configuration

### 4.0 The panel is 1080×2340

Read straight out of the device tree [VERIFIED]: `simple-framebuffer` is `1080x2340`, `stride = 1080*4`, `format = "a8r8g8b8"`, and the Goodix touch node declares `touchscreen-size-x = <1080>; touchscreen-size-y = <2340>;`. Build all scaling decisions on **1080×2340**.

### 4.1 Scaling and touch for Plasma Mobile

The mobile shell does its own layout; you mostly need to make Qt/fonts readable.

`~/.config/plasma-mobile/` is prepended to `XDG_CONFIG_DIRS` by `startplasmamobile` [VERIFIED] — this is the correct place for mobile-session-only overrides, because it does not leak into the desktop session.

Set the compositor output scale properly (do **not** hand-edit the output JSON; Plasma 6 rewrites it):

```bash
# Preferred: let the compositor scale. Use the GUI:
#   System Settings -> Display and Monitor -> Scale: 200%
# Equivalent CLI (desktop session), output name from `kscreen-doctor -o`:
kscreen-doctor output.DSI-1.scale.2.0
```

If a *specific* app or the whole session still renders too small, use environment overrides — these are the portable, verify-on-device mechanism, put in `~/.config/plasma-workspace/env/` (sourced by `startplasma-wayland`; the directory is created by `plasma-workspace`):

```sh
# ~/.config/plasma-workspace/env/10-raphael-scale.sh
# Qt-wide integer/float scaling for Qt apps that ignore compositor scale
export QT_SCALE_FACTOR=2
# Font DPI for GTK/Qt apps that read it (1080x2340 @ ~6.39" is ~403 ppi -> 2x of 96 dpi)
export QT_FONT_DPI=192
export GDK_SCALE=2
export GDK_DPI_SCALE=0.5
# Keep the mobile look when launching Kirigami apps from the DESKTOP session
export QT_QUICK_CONTROLS_MOBILE=true
```

> **[EXPECTED / verify on device]** `~/.config/plasma-workspace/env/*.sh` is the documented Plasma 5/6 hook for session environment. Confirm the directory is honoured on your build by adding a script that writes to a file and checking it appears after login.

Font DPI inside Plasma (persistent, applies to both sessions):

```bash
kwriteconfig6 --file kdeglobals --group General --key forceFontDPI 192
```

Mobile device preset — **`plasma-mobile` ships presets but none for raphael/SM8150** [VERIFIED]. Present: `default.conf`, `fairphone,fp5.conf`, `google,sargo.conf`, `nothing,spacewar.conf`, `oneplus,enchilada.conf`. The file format is [VERIFIED]:

```ini
# /usr/share/plasma-mobile-device-presets/xiaomi,raphael.conf   (packaging-owned path)
# Device-local override goes in ~/.config/plasma-mobile/ instead.
[Device]
name=Xiaomi Redmi K20 Pro

[Panels]
# 1080x2340, no notch/curved edges on raphael -> modest padding
statusBarHeight=80
leftPadding=6
rightPadding=6

[Panels][Top]
centerSpacing=64
```

> The preset **schema** (`[Device] name=`, `[Panels] statusBarHeight/leftPadding/rightPadding`, `[Panels][Top] centerSpacing`) is [VERIFIED] from the shipped `oneplus,enchilada.conf` / `fairphone,fp5.conf`. The *values* above are a sensible starting point — **[EXPECTED / verify on device]**.

### 4.2 On-screen keyboard on a touch device

**Use `plasma-keyboard`.** It is the Plasma 6 OSK, built on `qt6-virtualkeyboard`, and it is what `plasma-mobile` hard-depends on.

Mechanism [VERIFIED from KWin source `src/inputmethod.cpp` and the `plasma-keyboard` package]:

- KWin finds OSKs by scanning `.desktop` files for **`X-KDE-Wayland-VirtualKeyboard=true`**. `plasma-keyboard`'s `/usr/share/applications/org.kde.plasma.keyboard.desktop` has exactly that, with `Exec=plasma-keyboard` and `NoDisplay=true` [VERIFIED].
- KWin reads its OSK settings from the **`[Wayland]`** group of `kwinrc`:
  - **`VirtualKeyboardEnabled`** (bool, default `true`)
  - **`VirtualKeyboardMode`** (int) — enum `VirtualKeyboardVisibility`: **`Never = 0`**, **`NonMouseInput = 1`** (default), **`AnyInput = 2`** [VERIFIED enum from `src/inputmethod.h`]
- **There is no `InputMethod=` key in `kwinrc` in this version.** `InputMethod=` is an **SDDM** key (`[General] InputMethod=qtvirtualkeyboard`), not a KWin key. The commonly-copied `kwinrc [Wayland] InputMethod=` advice is wrong for Plasma 6.7.
- KWin injects `QT_QPA_PLATFORM=wayland` into the OSK process and launches the command itself [VERIFIED], so you do **not** need an autostart entry.

`~/.config/kwinrc`:

```ini
[Wayland]
# Show the OSK whenever a text field is focused by touch/stylus (not by mouse)
VirtualKeyboardEnabled=true
VirtualKeyboardMode=1
```

The same setting is exposed in the GUI as the **Virtual Keyboard** KCM (`systemsettings kcm_virtualkeyboard`), which is marked `X-KDE-OnlyShowOnQtPlatforms=wayland` [VERIFIED].

For CJK typing through the OSK you additionally need the input-method engine with an on-screen-friendly frontend; `plasma-keyboard`'s KCM is `kcm_plasmakeyboard`, and the keyboard layouts come from `/usr/share/plasma/keyboard/` [VERIFIED]. `fcitx5` (§1.1) provides the desktop input method; note that `plasma-keyboard` and `fcitx5` are separate mechanisms — pick one per session.

> **Reality check:** on this device the OSK is currently moot — **the touchscreen has no driver** (§5.1). Plan for USB-OTG keyboard/mouse or SSH.

### 4.3 Auto-rotation / `iio-sensor-proxy`: **not possible on `raphael`**

This is a definitive negative result, read from the device tree:

- `sm8150-xiaomi-raphael.dts` contains **no accelerometer, gyroscope, magnetometer, ambient-light or proximity device node** — no `iio` node, no `bmi160`/`lsm6ds*`/`icm*` binding anywhere [VERIFIED].
- The only trace of the hardware is two *pin-name strings* in the TLMM pinctrl label list:
  ```
  "ACCEL_INT",            /* GPIO_132 */
  "GYRO_INT",             /* GPIO_133 */
  ```
  These are just label text for GPIO lines — they bind no driver and create no IIO device [VERIFIED].
- Therefore `iio-sensor-proxy` will find **no sensors**, and Plasma's automatic rotation will not function.

So: **do not configure auto-rotation; there is nothing to configure.** Verify on device (should print nothing):

```bash
ls /sys/bus/iio/devices/
monitor-sensor            # from iio-sensor-proxy; will report no sensors
```

If you want rotation anyway, your only options are (a) add the IMU node + a driver to the kernel yourself, or (b) a manual rotate hook. Manual rotation via KWin's DBus is available and needs no sensor:

```bash
# List outputs and rotate manually
kscreen-doctor -o
kscreen-doctor output.DSI-1.rotation.right    # or .left / .inverted / .normal
```

> Note: the SM8150 kernel tree does have an active `andrew/6.16-sensors` branch, i.e. sensors are being worked on upstream in the pmOS fork — re-check periodically.

### 4.4 Network: `plasma-nm` + NetworkManager, Wi-Fi only

`raphael` is Wi-Fi + BT (WCN3998 combo, `qcom,wcn3998-bt` in the DTS [VERIFIED]) with **no ethernet**. The modem exists in the DT (`remoteproc_mpss`, firmware `qcom/sm8150/Xiaomi/raphael/modem.mbn` [VERIFIED]) but mobile data/calls are only partially supported — treat the device as Wi-Fi-only for a first bring-up.

`/etc/NetworkManager/conf.d/10-raphael.conf`:

```ini
[main]
# Wi-Fi only; do not wait for a wired carrier
no-auto-default=*
plugins=keyfile

[connectivity]
# Avoid a long stall when there is no internet route yet at boot
enabled=false

[device]
# Phones roam between APs a lot; keep Wi-Fi aggressive
wifi.scan-rand-mac-address=no
```

`/etc/NetworkManager/NetworkManager.conf` stays at distro default; the drop-in above is enough.

Enable the daemons:

```bash
systemctl enable --now NetworkManager
systemctl enable --now bluetooth
```

`plasma-nm` is the applet — it is pulled by both `plasma-desktop` (optdep, so explicit) and `plasma-mobile` (hard dep). **Do not run `wpa_supplicant.service` and NetworkManager's internal supplicant at the same time**; NetworkManager uses `wpa_supplicant` itself. Leave `wpa_supplicant.service` disabled.

Headless Wi-Fi bring-up before the display works:

```bash
nmcli device wifi list
nmcli device wifi connect "SSID" password "…"
nmcli connection modify "SSID" connection.autoconnect yes
```

For the partially-supported modem, keep ModemManager enabled but expect it to be flaky; it is a hard dep of `plasma-mobile` so it will be present anyway.

### 4.5 Disabling suspend (SM8150 cannot suspend reliably)

Rationale from the device tree [VERIFIED]: `sm8150.dtsi` defines only CPU idle states (`cpu-sleep-0-0`, `cpu-sleep-1-0`) and a cluster idle state (`cluster-sleep-0`). The `psci` node is `compatible = "arm,psci-1.0"` **with no `system-suspend` capability advertised**, so a real system-suspend (`deep`) is not expected to be available; what remains is `s2idle`, which is not reliable here. Confirm on device — it should show only `s2idle`:

```bash
cat /sys/power/mem_sleep        # expect: [s2idle]   (no "deep")
cat /sys/power/state            # expect: freeze mem   (mem will fail if only s2idle)
```

Belt-and-braces: mask the targets so nothing (PowerDevil, logind, a stray `systemctl suspend`) can put the device to sleep.

```bash
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
systemctl mask suspend-then-hibernate.target
```

Verify:

```bash
systemctl status sleep.target      # masked
systemctl list-unit-files 'sleep.target' 'suspend.target'
```

PowerDevil config — **exact schema**. The rc group is `<ProfileId>` + one of the action subgroups, and the keys are **PascalCase** (no `key=` override exists in the kcfg, so the entry name *is* the config key). Schema [VERIFIED from `PowerDevilProfileSettings.kcfg` in `plasma/powerdevil`]:

| Group | Keys |
|---|---|
| `[<Profile>][Display]` | `UseProfileSpecificDisplayBrightness`, `DisplayBrightness`, `DimDisplayWhenIdle`, `DimDisplayIdleTimeoutSec`, `TurnOffDisplayWhenIdle`, `TurnOffDisplayIdleTimeoutSec`, `TurnOffDisplayIdleTimeoutWhenLockedSec`, `LockBeforeTurnOffDisplay` |
| `[<Profile>][SuspendAndShutdown]` | `AutoSuspendAction`, `AutoSuspendIdleTimeoutSec`, `PowerButtonAction`, `PowerDownAction`, `LidAction`, `InhibitLidActionWhenExternalMonitorPresent`, `SleepMode` |
| `[<Profile>][Keyboard]` | `UseProfileSpecificKeyboardBrightness`, `KeyboardBrightness` |
| `[<Profile>][Performance]` | `PowerProfile` |
| `[<Profile>][RunScript]` | `ProfileLoadCommand`, `ProfileUnloadCommand`, `IdleTimeoutCommand`, `RunScriptIdleTimeoutSec` |

`<Profile>` is one of **`AC`**, **`Battery`**, **`LowBattery`** [VERIFIED]. Note the group is **`SuspendAndShutdown`** — *not* `SuspendSession`, which is the old Plasma 5 name. There is **no** `[PowerButton]` subgroup; `PowerButtonAction` lives in `SuspendAndShutdown`.

`~/.config/powerdevilrc`:

```ini
[AC][SuspendAndShutdown]
# 0 = NoAction -> never auto-suspend. THIS is the key that stops suspend-on-idle.
AutoSuspendAction=0
# 0 disables the idle timer entirely
AutoSuspendIdleTimeoutSec=0
# 64 = TurnOffScreen, 128 = ToggleScreenOnOff (enum below)
PowerButtonAction=64

[Battery][SuspendAndShutdown]
AutoSuspendAction=0
AutoSuspendIdleTimeoutSec=0
PowerButtonAction=64

[LowBattery][SuspendAndShutdown]
AutoSuspendAction=0
AutoSuspendIdleTimeoutSec=0
PowerButtonAction=64

# Screen-off on idle is FINE (it is just DPMS), only *suspend* is poison.
[AC][Display]
TurnOffDisplayWhenIdle=true
TurnOffDisplayIdleTimeoutSec=300
DimDisplayWhenIdle=true
DimDisplayIdleTimeoutSec=60
LockBeforeTurnOffDisplay=false
UseProfileSpecificDisplayBrightness=false

[Battery][Display]
TurnOffDisplayWhenIdle=true
TurnOffDisplayIdleTimeoutSec=120
DimDisplayWhenIdle=true
DimDisplayIdleTimeoutSec=60
LockBeforeTurnOffDisplay=false
UseProfileSpecificDisplayBrightness=false

[LowBattery][Display]
TurnOffDisplayWhenIdle=true
TurnOffDisplayIdleTimeoutSec=60
DimDisplayWhenIdle=true
DimDisplayIdleTimeoutSec=30
LockBeforeTurnOffDisplay=true
UseProfileSpecificDisplayBrightness=true
```

Defaults for reference [VERIFIED from `powerdevilsettingsdefaults.cpp`]: `DimDisplayIdleTimeoutSec` is 300 s (`AC`/desktop) / 60 s (`Battery`/mobile); `TurnOffDisplayIdleTimeoutSec` is 600 s (`AC`) / 300 s (`Battery`) / 120 s (`LowBattery`); `TurnOffDisplayIdleTimeoutWhenLockedSec` default is `60`; `SleepMode` defaults to `SuspendToRam`.

**Does PowerDevil already handle this?** Partly, and helpfully [VERIFIED from `powerdevilsettingsdefaults.cpp`]:

- `ProfileDefaults::defaultAutoSuspendAction(isVM, canSuspend)` returns `canSuspend ? Sleep : TurnOffScreen` — **PowerDevil already probes suspend capability and falls back to "turn the screen off" when the system cannot suspend.** So on a correctly-brought-up `raphael` it should not try to suspend by itself.
- `ProfileDefaults::defaultPowerButtonAction(isMobile)` returns **`ToggleScreenOnOff` (128) on mobile** and `PromptLogoutDialog` (16) on desktop. PowerDevil detects "mobile" (it keys off the same `PLASMA_PLATFORM=phone:handset` style signals), so on the Plasma Mobile session the power button already toggles the screen by default.
- Nevertheless **mask the systemd targets anyway** — `canSuspend` detection depends on `/sys/power/state` and can be optimistic, and `systemctl suspend` from any tool would otherwise still be attempted.

PowerDevil `PowerButtonAction` enum (uint) [VERIFIED from `powerdevilenums.h`]:

| Value | Action |
|---|---|
| 0 | `NoAction` |
| 1 | `Sleep` |
| 2 | `Hibernate` |
| 8 | `Shutdown` |
| 16 | `PromptLogoutDialog` |
| 32 | `LockScreen` |
| 64 | `TurnOffScreen` |
| 128 | `ToggleScreenOnOff` |

### 4.6 Power button: short press = blank screen, long press = shutdown

`/etc/systemd/logind.conf.d/10-raphael-power.conf`:

```ini
[Login]
# logind's default is poweroff. Let userspace own the key instead.
HandlePowerKey=ignore
# Long press: logind CANNOT open a menu; it can only perform one action.
# "poweroff" is the closest achievable to "show the shutdown menu".
HandlePowerKeyLongPress=poweroff
# MUST be yes, otherwise PowerDevil's power-key inhibitor means logind
# never sees the key at all and HandlePowerKeyLongPress= never fires.
PowerKeyIgnoreInhibited=yes
# Belt and braces: no suspend/hibernate from keys either.
HandleSuspendKey=ignore
HandleSuspendKeyLongPress=ignore
HandleHibernateKey=ignore
# No lid on a phone, but make it explicit.
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
IdleAction=ignore
```

Verified facts and defaults behind these keys (local `logind.conf.5`, systemd 262) [VERIFIED]:

- `HandlePowerKey=` **defaults to `poweroff`**; `HandlePowerKeyLongPress=` **defaults to `ignore`**.
- `HandleRebootKeyLongPress=` defaults to `poweroff`; `HandleSuspendKeyLongPress=` defaults to `hibernate`; `HandleHibernateKeyLongPress=` defaults to `ignore`.
- `LidSwitchIgnoreInhibited=` defaults to `yes`, and the man page states this means "the lid switch does not respect suspend blockers by default, **but the power and sleep keys do**" — i.e. `PowerKeyIgnoreInhibited` effectively defaults to **no**.
- Valid values for `HandlePowerKey*`: `poweroff`, `reboot`, `halt`, `kexec`, `suspend`, `hibernate`, `hybrid-sleep`, `suspend-then-hibernate`, `lock`, `ignore`, `factory-reset`.

**Whether PowerDevil already handles this — the important nuance:**

- On Plasma Wayland, **PowerDevil takes a logind power-key inhibitor** and handles the button itself. With the default `PowerKeyIgnoreInhibited=no`, **logind never sees the power key at all** and any `HandlePowerKey*` setting is dead code while a Plasma session is running.
- **PowerDevil 6.7.5 has no long-press support.** Its config surface is only `PowerButtonAction` (in `[<Profile>][SuspendAndShutdown]`) — there is no `PowerButtonActionLongPress` entry in `PowerDevilProfileSettings.kcfg`, and no `longpress`/`LongPress` string exists anywhere in the ALARM `powerdevil` 6.7.5-2 binaries [VERIFIED]. So **long press cannot be handled by PowerDevil in this version.**
- Therefore the only way to get long-press behaviour is to set **`PowerKeyIgnoreInhibited=yes`** so logind keeps ownership of the long press, while PowerDevil continues to own the short press via its inhibitor… but with `PowerKeyIgnoreInhibited=yes`, logind also handles the *short* press. Resolve the conflict by setting `HandlePowerKey=ignore` (short press does nothing in logind) and letting PowerDevil's `PowerButtonAction` blank the screen.
- If you would rather have the **shutdown menu** on the power button than a blank screen, set `PowerButtonAction=16` (`PromptLogoutDialog`) under `[AC][SuspendAndShutdown]` in `powerdevilrc` — that dialog contains the shutdown/restart options, and it works on Wayland. (`PowerButtonAction` only takes one action, so short-press-blanks and long-press-menu cannot both be delivered by PowerDevil; the split above — PowerDevil short, logind long — is the only way.)

Apply and verify:

```bash
systemctl restart systemd-logind     # WARNING: restarts the session; do it over a VT, not SSH
loginctl show-session $XDG_SESSION_ID
journalctl -b -u systemd-logind | tail -20
```

---

## 5. Known risks / gotchas: Plasma on aarch64 + freedreno (Adreno 640)

### 5.0 First, the biggest risk: this device is NOT mainline

**[VERIFIED]** `arch/arm64/boot/dts/qcom/` in **mainline Linux contains no `sm8150-xiaomi-raphael.dts`**. The mainline SM8150 devices are only: `sm8150-hdk`, `sm8150-mtp`, `sm8150-microsoft-surface-duo`, and the Sony Xperia Kumano family.

The `raphael` device tree exists in a **postmarketOS-managed fork**: `gitlab.postmarketos.org/soc/qualcomm-sm8150/linux`, file `arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dts` (28,546 bytes), present on branches `sm8150/6.17` (**default**) and `sm8150/6.18`. The fork also has `sm8150/7.0-wip`, `andrew/6.16-sensors`, `andrew/6.16-cameras`, `andrew/6.16-ipa`.

Practical consequences:
- **Do not assume a vanilla `linux` package works.** The KDE package set below is kernel-agnostic (all userspace), but the display/touch/modem bring-up depends on this fork. Pin your kernel source/branch explicitly and record it.
- Everything in §4.3, §4.5 and §5.1 is a *property of this fork's device tree*, and can change between branches. Re-read the DTS for the branch you actually ship.

### 5.1 Touchscreen: no driver → **touch will not work**

**[VERIFIED]** the DTS binds the touchscreen as:

```dts
&i2c19 {
	status = "okay";
	goodix@5d {
		compatible = "goodix,gt9886";
		reg = <0x5d>;
		interrupts-extended = <&tlmm 122 IRQ_TYPE_LEVEL_LOW>;
		reset-gpios = <&tlmm 54 GPIO_ACTIVE_LOW>;
		touchscreen-size-x = <1080>;
		touchscreen-size-y = <2340>;
	};
};
```

but **`gt9886` appears in no driver's `of_device_id` table**:
- mainline `drivers/input/touchscreen/goodix.c` supports: `gt911 gt9110 gt912 gt9147 gt917 gt927 gt9271 gt928 gt9286 gt967`.
- the pmOS `sm8150/6.17` tree's `goodix.c` supports the same list — **no `gt9886`**.
- `goodix_berlin_i2c.c` / `goodix_berlin_spi.c` support only `gt9916` / `gt9897`.
- the tree also carries `goodix_gtx8.c`, `stmfts.c`, and a downstream `fts_touch/` — none matches `gt9886`.

Since `compatible` has no fallback string, the device **will not probe**, there will be no `/dev/input/event*` for touch, and **no touch input is possible**. Confirm on device:

```bash
dmesg | grep -iE 'goodix|gt9886|i2c19'
libinput list-devices
cat /proc/bus/input/devices
```

Plan accordingly: **USB-OTG keyboard + mouse, or SSH**, for the entire first bring-up. This also means the on-screen keyboard (§4.2) has nothing to serve. Getting touch working requires adding `goodix,gt9886` support to `goodix.c` (or a dedicated driver) — track the pmOS fork; the linked work item "[DTS Issue] sm8150-xiaomi-raphael" suggests it is known-unfinished.

### 5.2 Display / GPU: the good news

**[VERIFIED]** the panel is a mainline-supported driver:

```dts
panel: panel@0 {
	compatible = "samsung,ams639rq08";
	...
};
```
`drivers/gpu/drm/panel/panel-samsung-ams639rq08.c` **exists in mainline** (`torvalds/linux` master).

**[VERIFIED]** the GPU is Adreno 640 and needs a signed shader blob:

```dts
&gpu {
	zap-shader {
		memory-region = <&gpu_mem>;
		firmware-name = "qcom/sm8150/Xiaomi/raphael/a640_zap.mbn";
	};
};
```

So the firmware file **`qcom/sm8150/Xiaomi/raphael/a640_zap.mbn`** must be present in the rootfs (`/lib/firmware/`) or KWin's OpenGL compositing will not come up. Get it from a `linux-firmware`-style package or extract it from the stock phone image; it is not in ALARM's `linux-firmware`.

Also note the DTS provides a **`simple-framebuffer`** at `0x9c000000`, 1080×2340 `a8r8g8b8`, with

```
bootargs = "earlycon console=ttyMSM0,115200";
```

This gives you a working console **and** an early framebuffer before the DRM driver loads — very useful for headless bring-up (§6).

`mesa` 1:26.2.3-1 and `vulkan-freedreno` 1:26.2.3-1 are the versions in ALARM extra. **[VERIFIED from Mesa docs]** freedreno implements up to OpenGL ES 3.2 and desktop OpenGL 4.5 for **Adreno 2xx–6xx**, and Turnip is a Vulkan 1.3 driver for **Adreno 6xx** — so `a640` is in scope. Free-form "Plasma 6 Wayland works on freedreno" is **[EXPECTED]** rather than verified: there is no upstream statement I could confirm, so treat first light as a test, not a guarantee.

### 5.3 Rendering fallbacks and environment variables

Use these in this order when the compositor misbehaves.

**a) Force the QPainter (software) compositor.** This is the reliable escape hatch and it is a genuine, supported backend — KWin contains `Compositor::attemptQPainterCompositing()`, `QPainterSwapchain`, `ItemRendererQPainter`, and the `Compositor` group with key `Backend` [VERIFIED by `strings` on `libkwin.so.6.7.5`].

```sh
# In ~/.config/plasma-workspace/env/90-kwin-fallback.sh
export KWIN_COMPOSE=Q      # QPainter backend (Wayland only)
```

`KWIN_COMPOSE` values [VERIFIED, KDE wiki]: `O` OpenGL, `O1` OpenGL 1, `O2` OpenGL 2, `O2ES` GLES 2, `X` XRender (X11 only), **`Q` QPainter (Wayland only)**, `N` no compositing (X11 only). KWin's own binary also contains the literal `KWIN_COMPOSE` and the message "OpenGL 2 compositing enforced by environment variable". Note the KDE wiki page for this is flagged OBSOLETE and now redirects to `invent.kde.org/plasma/kwin/-/wikis/Environment-Variables` (which served no body to `curl`), so treat the above as legacy-but-still-present: the strings are in the shipped 6.7.5 binary.

**b) `kwinrc` software/GL selection** — prefer the supported GUI (`System Settings → Compositor`) over hand-editing; the group is `[Compositing]` and the backend key is `Backend` [VERIFIED that both literals exist in `libkwin.so.6.7.5`]. Exact accepted *values* are **[EXPECTED / verify on device]**.

**c) `--render-backend` does not exist in this version.** I searched the ALARM `kwin_wayland` 6.7.5 binary and the whole `kwin` package for `render-backend` and found **no occurrence** [VERIFIED]. Only the messages "No backend specified, automatically choosing drm" / "…choosing Wayland because WAYLAND_DISPLAY is set" / "…choosing X11 because DISPLAY is set" are present. **Do not put `kwin_wayland --render-backend=…` in a config file** — it will fail argument parsing. Use `KWIN_COMPOSE=Q` or the KCM instead.

**d) `KWIN_DRM_DEVICES`** — **real, but unnecessary here.** It exists in `libkwin.so.6.7.5`, and the kwin source shows the semantics exactly:

```cpp
// src/backends/drm/drm_backend.cpp
m_explicitGpus = GpuManager::splitPathList(qEnvironmentVariable("KWIN_DRM_DEVICES"));
...
// Ignore the device seat if the KWIN_DRM_DEVICES envvar is set.
if (!m_explicitGpus.isEmpty()) {
    const auto canonicalPath = QFileInfo(device->devNode()).canonicalFilePath();
    const bool foundMatch = std::ranges::any_of(m_explicitGpus, [&canonicalPath](const QString &explicitPath) {
        return QFileInfo(explicitPath).canonicalFilePath() == canonicalPath;
    });
    if (!foundMatch) continue;
}
```

So it is a **`splitPathList` (colon-separated, PATH-like) list of DRM node paths**, compared by canonical path, e.g. `KWIN_DRM_DEVICES=/dev/dri/card0`. `raphael` has exactly **one** GPU, so leave it unset. Setting it wrongly (e.g. pointing at a non-existent node, or at `card1` render node) will make KWin find **no** outputs and start with a black screen.

**e) Mesa/freedreno debug knobs.** From the [Mesa freedreno documentation](https://docs.mesa3d.org/drivers/freedreno.html) [VERIFIED]:

- Useful `FD_MESA_DEBUG` options (freedreno GL): `sysmem, gmem, nobin, noubwc, nolrz, notile, dclear, ddraw, flush, inorder, noblit`
- Useful `TU_DEBUG` options (Turnip): `sysmem, gmem, nobin, forcebin, noubwc, nolrz, flushall, syncdraw, rast_order`
- Useful `IR3_SHADER_DEBUG` options: `nouboopt, spillall, nopreamble, nofp16`
- GPU hang/command-stream capture:
  ```bash
  cat /sys/kernel/debug/dri/0/rd > cmdstream &
  echo Y > /sys/module/msm/parameters/rd_full   # capture all BOs (heavy; can OOM)
  ```
  Recommended practical values: `FD_MESA_DEBUG=sysmem` to bypass tiling (very effective against freedreno corruption/hangs on new panels), and `FD_MESA_DEBUG=flush` to narrow down a hang.
- `MESA_LOADER_DRIVER_OVERRIDE` — mentioned in your brief; **not documented on the freedreno page** I fetched. It is a real Mesa variable but it selects the *classic* DRI driver name; on modern Mesa the `msm`/freedreno driver is chosen by the kernel device, so overriding it is a legacy X11/GLX debugging trick. **Do not set it** unless you are deliberately debugging; if you must, the value for this GPU family is `msm` **[EXPECTED / verify on device]**.
- `QT_QUICK_BACKEND=software` — a Qt Quick (QML) renderer override. **Do not set it globally**: it would force every Plasma shell surface (which is QML) to raster-render and destroy phone performance. Use it only to bisect a specific crashing QML app.

**f) `QT_WAYLAND_DISABLE_WINDOWDECORATION`** — from your brief. It is a real Qt Wayland variable that removes server-side window decorations, intended for compositors that draw their own. Under **KWin/Plasma it is neither needed nor desirable** (KWin draws its own decorations, and the variable is aimed at embedding/weston-style setups). Setting it globally on Plasma Mobile can make windows undecorated/unclosable. **[EXPECTED]** — no upstream KDE source requires it.

**g) Firmware is a hard prerequisite.** `qcom/sm8150/Xiaomi/raphael/a640_zap.mbn` (GPU) plus, for the modem, `qcom/sm8150/Xiaomi/raphael/{modem.mbn,adsp.mbn,cdsp.mbn,ipa_fws.mbn}` [VERIFIED from the DTS]. Missing `a640_zap.mbn` is a very likely cause of "KWin starts then immediately dies".

### 5.4 X11 session removal (why you are Wayland-only)

**[VERIFIED]** `plasma-workspace` 6.7.5-1 ships `usr/share/xsessions/` as an **empty directory**, and the `kwin` package contains only `kwin_wayland` — no `kwin_x11`. X11 support was split into `plasma-x11-session` + `kwin-x11`, which you must install deliberately.

Upstream context [web]: KDE announced going "all-in on a Wayland future" (KDE blog, 2025-11-26) and press coverage reports X11 removal targeted around early 2027. So on Plasma 6.7 the X11 session is *optional*, and on this device it is also *pointless*: freedreno's strength is the Wayland/EGL path, and there is no `xorg-server` on a phone. **Plan Wayland-only.**

### 5.5 Other risks

| Risk | Detail |
|---|---|
| `sddm` drags in X | `sddm` `%DEPENDS%` includes `xorg-server` **and** `xorg-xauth`, and its `DisplayServer` default is `x11`. Prefer `plasma-login-manager` (§3.1) or set `DisplayServer=wayland` explicitly (§3.2). |
| SDDM greeter has no compositor by default | `[Wayland] CompositorCommand` defaults to `weston --shell=kiosk`, and **weston is not in the package list** — the greeter will fail to start until you set it to `kwin_wayland …`. |
| Double DM alias | Both DMs alias `display-manager.service` with no declared conflicts (§3.4). |
| `libcamera` uninstallable | `libpisp` missing → no `plasma-camera` (§1.5). |
| No telephony apps | `spacebar` (SMS), `plasma-dialer`, `ofono` all **[MISSING]**; only `modemmanager` exists (§1.3). |
| No `--noscriptlet` aftermath | sysusers/tmpfiles/icon-cache/desktop-db are skipped in a foreign-root install; run them post-install (§1.4). `plasmalogin` specifically needs `systemd-sysusers`. |
| qt6-virtualkeyboard version | `plasma-keyboard` depends on `qt6-virtualkeyboard` 6.11.2-1, while Plasma is 6.7.5 — Plasma's own Qt is 6.11.x, so this is consistent, but a Qt/Plasma mismatch is the classic cause of an OSK that does not appear. |

---

## 6. First-boot checklist (headless-ish, before the display works)

### 6.1 Serial console — your lifeline

The device tree's `chosen` node gives you a console before anything else works [VERIFIED]:

```
bootargs = "earlycon console=ttyMSM0,115200";
stdout-path = "serial0:115200n8";
```

Use a 115200 8N1 UART on the phone's debug pads (or a USB-serial adapter), and add `console=ttyMSM0,115200` to your bootloader cmdline. Also confirm the `simple-framebuffer` is registered early:

```bash
dmesg | grep -iE 'simple-framebuffer|simpledrm|msm|drm'
```

### 6.2 Services to enable

```bash
# Display manager — ONE of these, never both (§3.4)
systemctl enable plasmalogin.service        # recommended (§3.1)
# systemctl enable sddm.service             # alternative

systemctl enable NetworkManager.service
systemctl enable bluetooth.service
systemctl enable power-profiles-daemon.service

# Audio: pipewire runs per-user (socket-activated), but wireplumber + the
# pipewire user units are what actually matter.
systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service

# Optional; will report no sensors on this device (§4.3)
systemctl enable --now iio-sensor-proxy.service

# Do NOT enable these on raphael:
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target   # (§4.5)
systemctl disable wpa_supplicant.service                                          # NM owns Wi-Fi
```

User units for the Plasma session are **not** enabled manually — `startplasma-wayland` pulls `plasma-workspace.target` / `plasma-core.target` / `plasma-workspace-wayland.target`, all shipped by `plasma-workspace` [VERIFIED the unit list exists in the package].

### 6.3 Bring up the network first (SSH over USB or Wi-Fi)

```bash
# USB networking (if your kernel/DT exposes a USB gadget or RNDIS interface)
ip -br addr
nmcli device status

# Wi-Fi
nmcli device wifi list
nmcli device wifi connect "SSID" password "…"

# SSH in
systemctl enable --now sshd
```

### 6.4 Start a session manually to debug (from a VT / over serial)

Never debug the DM first — bypass it.

```bash
# 1) Log in on tty1 (serial or USB keyboard), then:
export XDG_SESSION_TYPE=wayland
export XDG_RUNTIME_DIR=/run/user/$(id -u)      # must exist and be 0700
export QT_QPA_PLATFORM=wayland
unset DISPLAY WAYLAND_DISPLAY

# 2) Desktop session, directly, with verbose logging:
dbus-run-session -- startplasma-wayland 2>&1 | tee ~/plasma-wayland.log

# 3) Mobile session (sets PLASMA_PLATFORM=phone:handset and the mobile shell):
dbus-run-session -- startplasmamobile 2>&1 | tee ~/plasma-mobile.log

# 4) Bare compositor only — isolates DRM/GPU from the shell:
kwin_wayland --exit-with-session=konsole
```

`WAYLAND_DISPLAY` is set **by the compositor** for its children; do not set it yourself when launching a session. If you need to attach a client to a running nested compositor, read it from the compositor's environment — do not guess a socket name.

Nested-in-a-session test (run from an existing session, no DRM takeover):

```bash
kwin_wayland --xwayland --width=1080 --height=2340 --nested &
WAYLAND_DISPLAY=wayland-1 plasmashell --shell org.kde.plasma.mobileshell
```

Software-rendering smoke test, to prove userspace is fine and only the GPU path is broken:

```bash
KWIN_COMPOSE=Q kwin_wayland --exit-with-session=konsole
QT_QUICK_BACKEND=software plasmashell --shell org.kde.plasma.mobileshell
```

### 6.5 Where the logs are

| What | Where |
|---|---|
| Journal, current boot | `journalctl -b` |
| Display manager | `journalctl -b -u plasmalogin` / `journalctl -b -u sddm` |
| KWin / compositor | `journalctl -b --user -u plasma-kwin_wayland.service` |
| Whole Plasma session (user units) | `journalctl -b --user -u plasma-workspace.target -u plasma-core.target` |
| Plasma shell | `journalctl -b --user -u plasma-plasmashell.service` |
| Session journal file | `~/.local/share/sddm/wayland-session.log` (SDDM, per `sddm.conf.5` default `SessionLogFile=`) |
| XDG portal | `journalctl -b --user -u xdg-desktop-portal -u xdg-desktop-portal-kde` |
| Boot / kernel / DRM | `dmesg`, then `journalctl -b -k` |
| GPU / DRM debug | `dmesg \| grep -iE 'msm\|adreno\|drm\|freedreno'` |
| Mesa / EGL capability probe | `eglinfo`, `glxinfo -B` (`mesa-utils`), `vulkaninfo` |
| Session type actually in use | `loginctl show-session $XDG_SESSION_ID -p Type` (expect `wayland`) |
| Confirm which DM owns the alias | `systemctl status display-manager` |

---

## 7. Sources

Package facts (versions, deps, provides, file lists, man pages, service files): the ALARM aarch64 databases `/tmp/alarm-core.db`, `/tmp/alarm-extra.db`, and the real packages downloaded from `http://mirror.archlinuxarm.org/aarch64/extra/` — `plasma-workspace` 6.7.5-1, `plasma-mobile` 6.7.5-1, `plasma-login-manager` 6.7.5-1, `plasma-x11-session` 6.7.5-1, `sddm` 0.21.0-7, `plasma-keyboard` 6.7.5-1, `kwin` 6.7.5-1, `powerdevil` 6.7.5-2.

KWin behaviour: [KDE Community Wiki — KWin/Environment Variables](https://community.kde.org/KWin/Environment_Variables) (marked obsolete; redirects to `invent.kde.org/plasma/kwin/-/wikis/Environment-Variables`), plus KWin source `src/inputmethod.cpp`, `src/inputmethod.h`, `src/backends/drm/drm_backend.cpp` from [KDE/kwin](https://github.com/KDE/kwin).

PowerDevil behaviour: [KDE/powerdevil](https://github.com/KDE/powerdevil) — `daemon/powerdevilenums.h`, `daemon/powerdevilsettingsdefaults.{h,cpp}`, `daemon/powerdevilcore.cpp`, and the config schema **`PowerDevilProfileSettings.kcfg`** (fetched via the [KDE GitLab API](https://invent.kde.org/api/v4/projects/plasma%2Fpowerdevil/repository/tree?recursive=true)).

Plasma Login Manager: [KDE/plasma-login-manager README](https://github.com/KDE/plasma-login-manager/blob/master/README.md) and the [KDE Discuss thread on `/etc/plasmalogin.conf`](https://discuss.kde.org/t/plasma-login-manager-wallpaper-setting-in-plasmalogin-conf-d-ignored/46226).

Device facts: `arch/arm64/boot/dts/qcom/sm8150-xiaomi-raphael.dts` and `sm8150.dtsi` from the postmarketOS SM8150 kernel fork, [gitlab.postmarketos.org/soc/qualcomm-sm8150/linux](https://gitlab.postmarketos.org/soc/qualcomm-sm8150/linux), branches `sm8150/6.17` and `sm8150/6.18`; mainline comparison against `arch/arm64/boot/dts/qcom/` and `drivers/input/touchscreen/goodix.c` in [torvalds/linux](https://github.com/torvalds/linux).

Mesa/freedreno: [Freedreno — The Mesa 3D Graphics Library](https://docs.mesa3d.org/drivers/freedreno.html).

logind: local `logind.conf.5` (systemd 262).

X11 removal: [KDE Blogs — Going all-in on a Wayland future](https://blogs.kde.org/2025/11/26/going-all-in-on-a-wayland-future/), [heise — KDE Desktop says goodbye to X11 mode](https://www.heise.de/en/news/KDE-Desktop-says-goodbye-to-X11-mode-and-fully-commits-to-Wayland-11094400.html).

Note: `wiki.postmarketos.org` and `wiki.archlinux.org` were unreachable from this host (Anubis anti-bot / DNS restrictions), so pmOS device pages are **not** used as sources above — every device claim was taken from the device tree source instead.
