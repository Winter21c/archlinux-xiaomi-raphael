# Debian/Ubuntu → Arch Linux ARM porting checklist — Xiaomi Redmi K20 Pro (`raphael`, SM8150)

Target: **Arch Linux ARM aarch64** rootfs on the `userdata` partition (ext4), **systemd-boot** on the FAT
`cache` partition mounted at `/boot`.

Source of truth for behaviour: `_recon/upstream-scripts/build.sh`, `config/build-config.sh`,
`scripts/00-*.sh` … `scripts/18-*.sh` (read in full), `_recon/README-winter.md`,
`_recon/dl/x-image/`, `_recon/dl/x-fw/`, `_recon/dl/x-alsa/`.

---

## 0. Validation basis and legend

**Package database provenance.** `/tmp/alarm-core.db` (256 607 bytes) is **byte-identical in size and
content** to `https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/aarch64/core/core.db`, so the whole
validation below was done against that mirror's snapshot and extended with the matching
`core.files` / `extra.files` databases (44 MB) downloaded from the same mirror. Every package name,
version, systemd unit name and file path marked **VALIDATED** below was read out of those databases,
or out of the actual `.pkg.tar.xz` files downloaded and extracted from that mirror.

| Mark | Meaning |
|:--|:--|
| **VALIDATED** | Package name present in `core.db`/`extra.db` **and** the cited path/unit was found in that package's `files` entry (or in the extracted package). |
| **VALIDATED (pkg)** | Package name present in `core.db`/`extra.db` with the stated version; the cited internal path was **not** re-read from the package file list. |
| **UNVERIFIED** | Could not be confirmed from the databases/packages. Treat as a guess to check on-device. |
| **✗ NO ARCH EQUIVALENT** | Nothing in ALARM `core`+`extra` provides it. Must be built from source or replaced. |

Snapshot versions used: `systemd-262-1`, `mkinitcpio-42.1-1`, `glibc-2.43+r22+g8362e8ce10b2-2`,
`shadow-4.20.0.arch1-1`, `openssh-10.5p1-1`, `sudo-1.9.17.p2-6`, `networkmanager-1.58.1-1`,
`dnsmasq-2.93-1`, `chrony-4.9-1`, `zram-generator-1.2.1-1`, `alsa-ucm-conf-1.2.16.1-1`,
`pipewire-1:1.6.9-1`, `wireplumber-0.5.17-2`, `plasma-desktop/plasma-workspace/kscreen/powerdevil-6.7.5-*`,
`libkscreen-6.7.5-1`, `qt6-tools-6.11.2-1`, `python-3.14.7-1`, `linux-aarch64-7.2.8-1`,
`linux-firmware-*-20260916-1`, `wireless-regdb-2026.09.03-1`, `filesystem-2025.10.12-1`,
`base-3-3`, `pacman-7.1.0.r9.g54d9411-2`.

Conventions used in the snippets: `$ROOT` is the target rootfs prefix (the Arch analogue of
`rootdir/`), all snippets are meant to be run as root with `$ROOT` set. Paths beginning `/` inside
snippets are **inside the image**; `$ROOT/...` is the host-side write location.

Two structural facts that drive most of this document (both **VALIDATED**):

* `/lib` → `usr/lib`, `/bin` → `usr/bin`, `/sbin` → `usr/bin` are symlinks shipped by the
  `filesystem-2025.10.12-1` package (`files` list contains the bare entries `lib`, `bin`, `sbin`).
  So every Debian `/lib/...` path is `/usr/lib/...` on Arch and **must be written to `$ROOT/usr/lib/...`**.
* Arch's `base` metapackage (`base-3-3`) depends on `filesystem gcc-libs glibc bash coreutils file
  findutils gawk grep procps-ng sed tar gettext pciutils psmisc shadow util-linux bzip2 gzip xz
  licenses pacman archlinux-keyring systemd systemd-sysvcompat iputils iproute2` — **`kmod` is NOT in
  `base`**, but `mkinitcpio` depends on `kmod`, so installing `mkinitcpio` pulls it in.

---

## 1. Master mapping table — every behaviour in the Debian scripts

| # | Behaviour (Debian script) | Debian mechanism | Arch Linux ARM equivalent | Status |
|:--|:--|:--|:--|:--|
| 1.1 | Hostname + `/etc/hosts` + `/etc/resolv.conf` (04) | plain files | same files; `hostnamectl` optional | ✅ identical |
| 1.2 | China apt mirror (05) | `/etc/apt/sources.list.d/*.sources` + `apt-get update` | `/etc/pacman.d/mirrorlist` + `pacman -Sy` | ✅ files given in §12.2 |
| 1.3 | Base packages (06) | `apt-get install` list | see §1 table below | ⚠ 3 of 21 have no equivalent |
| 1.4 | `pd-mapper` service `ConditionKernelVersion` strip (06) | `sed -i` on `/lib/systemd/system/pd-mapper.service` | **✗ NO ARCH EQUIVALENT pkg** — build `pd-mapper` from source; upstream master has **no** such condition | ✗ see §12.5 |
| 1.5 | Chinese locale + timezone + fonts (07) | `locales`,`locales-all`,`tzdata`,`fonts-wqy-microhei`; `locale-gen`; `update-locale` | `glibc-locales`,`tzdata`,`wqy-microhei`,`noto-fonts-cjk`; `locale-gen`; `/etc/locale.conf` | ✅ §2 |
| 1.6 | `leijun` / `jinfan` screen commands + 15 s auto-blank (08) | append to `/etc/bash.bashrc`; `blank_screen.service` | identical, Arch-corrected unit | ✅ §12.6 |
| 1.7 | Kernel + firmware deb install (09) | `dpkg -i` ×3 + initramfs hook | extract debs, install to Arch paths, `mkinitcpio` + custom install hook | ⚠ §10, §11 |
| 1.8 | USB NCM gadget (10) | `dnsmasq.d/usb-ncm.conf`, `setup-usb-ncm.sh`, `usb-ncm.service` | same, **but Arch dnsmasq does not read `/etc/dnsmasq.d` by default** | ⚠ §3 |
| 1.9 | fstab + growfs (11) | `/etc/fstab` with `x-systemd.growfs` | identical file works | ✅ §4 |
| 1.10 | `IMAGE_UUID` + `root=PARTLABEL=userdata` (18) | `tune2fs -U` | same, or use PARTUUID | ✅ §4.3 |
| 1.11 | Users + passwords + SSH password login + sudo (12) | `chpasswd`, `useradd -G sudo`, append `sshd_config` | offline `/etc/passwd`/`shadow`/`group`/`gshadow`/`sudoers.d`; sshd drop-in | ⚠ §5 (group is `wheel`, not `sudo`) |
| 1.12 | Mask sleep/suspend (13) | `systemctl mask sleep.target …` | identical | ✅ §6.1 |
| 1.13 | netplan renderer (13) | `/etc/netplan/01-network-manager-all.yaml` | **not needed** — netplan is Ubuntu-only | ✅ dropped |
| 1.14 | NM `wifi.powersave = 2` (13) | `/etc/NetworkManager/conf.d/wifi-powersave.conf` | identical path, **VALIDATED present in pkg** | ✅ §6.2 |
| 1.15 | ath10k `skip_otp=y` (13) | `/etc/modprobe.d/ath10k.conf` | identical; **not needed** with vendor FW (see §6.3) | ⚠ §6.3 |
| 1.16 | Power key short/long press (14) | logind ignore + GNOME ScreenSaver DBus daemon + dconf | **drop GNOME parts**, keep logind+udev, port daemon to KDE | ⚠ §7 |
| 1.17 | zram 10 GB zstd (15) | `zram-tools` + `/etc/default/zramswap` | `zram-generator` + `/etc/systemd/zram-generator.conf` | ✅ §8 |
| 1.18 | WirePlumber ALSA tuning (16) | `/etc/wireplumber/wireplumber.conf.d/51-*.conf` | **identical path**, but the file format changed in WirePlumber 0.5 | ⚠ §9.4 |
| 1.19 | ALSA UCM for raphael (06 + `alsa-xiaomi-raphael.deb`) | `/usr/share/alsa/ucm2/{Raphael,conf.d/sm8150_raphael}` | identical path; **no conflict** with `alsa-ucm-conf` | ✅ §9.3 |
| 1.20 | apt cache clean, `mv /boot/initrd.img-* → /boot/initramfs`, `mv vmlinuz-* → /boot/linux.efi` (17) | Debian names | Arch names; keep U-Boot filenames only if U-Boot (not sd-boot) loads the kernel | ⚠ §10.4 |
| 1.21 | `rm -f /lib/firmware/reg*` (17) | remove `regulatory.db` | same file name shipped by `wireless-regdb` — same deletion applies | ✅ §12.7 |
| 1.22 | `apt-get upgrade -y` (06) | full upgrade | `pacman -Syu` | ✅ §12.2 |
| 1.23 | `rmtfs` `protection-domain-mapper` `tqftpserv` (06) | Debian packages | **✗ NO ARCH EQUIVALENT** — build from source | ✗ §12.5 |
| 1.24 | Boot partition mount (02) | `mount -o loop $BOOT_IMG rootdir/boot` | same idea, but the ESP must be a real vfat image and needs `dosfstools` | ⚠ §10.5 |
| 1.25 | `/etc/machine-id` for the USB serial (10) | created by Debian at first boot | Arch ships an **empty** `/etc/machine-id`; must be seeded explicitly | ⚠ §3.4 |
| 1.26 | Linger for the power-key user service (14) | `touch /var/lib/systemd/linger/<user>` | identical path | ✅ §7.4 |

### 1.1 Base package table (script 06 `BASE_PACKAGES` / `DEVICE_PACKAGES`)

| Debian package | Arch Linux ARM equivalent | Version @ snapshot | Status |
|:--|:--|:--|:--|
| `bash-completion` | `bash-completion` (extra) | 2.18.0-1 | VALIDATED (pkg) |
| `sudo` | `sudo` (core) | 1.9.17.p2-6 | VALIDATED — `etc/sudoers`, `etc/sudoers.d/`, `etc/pam.d/sudo` |
| `apt-utils` | — | — | ✗ dropped (no apt) |
| `ssh`, `openssh-server` | `openssh` (core) | 10.5p1-1 | VALIDATED — `etc/ssh/sshd_config`, `etc/ssh/sshd_config.d/99-archlinux.conf`, `usr/lib/systemd/system/sshd.service`, `sshd@.service`, `sshdgenkeys.service` |
| `nano` | `nano` (core) | 9.2-1 | VALIDATED (pkg) |
| `network-manager` | `networkmanager` (extra) | 1.58.1-1 | VALIDATED — `usr/lib/systemd/system/NetworkManager.service`, `NetworkManager-wait-online.service`, `etc/NetworkManager/conf.d/` |
| `initramfs-tools` | `mkinitcpio` (core) | 42.1-1 | VALIDATED — `usr/bin/mkinitcpio`, `usr/lib/initcpio/{install,hooks}/…`, `etc/mkinitcpio.conf`, `etc/mkinitcpio.conf.d/` |
| `chrony` | `chrony` (extra) | 4.9-1 | VALIDATED (pkg) — unit `chronyd.service` **UNVERIFIED** (unit not in the `files` list I read, only package presence) |
| `curl` | `curl` (core) | 8.22.0-1 | VALIDATED (pkg) |
| `wget` | `wget` (extra) | 1.25.0-6 | VALIDATED (pkg) |
| `locales`, `locales-all` | `glibc-locales` (core) | 2.43+r22+g8362e8ce10b2-2 | VALIDATED — ships `/usr/lib/locale/zh_CN.utf8/*` and `en_US.utf8/*` prebuilt |
| `tzdata` | `tzdata` (core) | 2026d-1 | VALIDATED (pkg) — `/usr/share/zoneinfo/Asia/Shanghai` |
| `iproute2` | `iproute2` (core) | 7.2.0-1 | VALIDATED (pkg) — in `base` |
| `zram-tools` | `zram-generator` (extra) | 1.2.1-1 | VALIDATED — `usr/lib/systemd/system-generators/zram-generator`, `usr/lib/systemd/system/systemd-zram-setup@.service`, `usr/share/man/man5/zram-generator.conf.5.gz` |
| `dnsmasq` | `dnsmasq` (extra) | 2.93-1 | VALIDATED — `etc/dnsmasq.conf`, `usr/lib/systemd/system/dnsmasq.service`; see §3.3 for the **conf-dir gotcha** |
| `nftables` | `nftables` (extra) | 1:1.1.7-3 | VALIDATED (pkg) |
| `fonts-wqy-microhei` | `wqy-microhei` (extra) | 0.2.0_beta-12 | VALIDATED (pkg) |
| `rmtfs` | — | — | ✗ **NO ARCH EQUIVALENT** — build from source (§12.5) |
| `protection-domain-mapper` | — | — | ✗ **NO ARCH EQUIVALENT** — build from source (§12.5) |
| `tqftpserv` | — | — | ✗ **NO ARCH EQUIVALENT** — build from source (§12.5) |

Extras worth adding on Arch (all **VALIDATED (pkg)** unless noted): `kmod` 34.2-1 (needed for
`modprobe`, pulled in by `mkinitcpio`), `util-linux` 2.42.4-1 (`setterm`, `zramctl`, `lsblk`; already
pulled by `base`), `e2fsprogs` 1.47.4-1, `dosfstools` 4.2-5 (needed if you `mkfs.vfat` the ESP),
`efibootmgr` 18-4, `polkit` 127-3 (required by `networkmanager`/`powerdevil`),
`python` 3.14.7-1 (power-key daemon), `alsa-utils` 1.2.16-1, `wireless-regdb` 2026.09.03-1,
`man-db` 2.13.1-2, `less` 1:710-1, `rsync` 3.5.1-1, `htop` 3.5.3-1.

---

## 2. Chinese locale, timezone, fonts (script 07)

### 2.1 Packages

| Debian | Arch Linux ARM | Status |
|:--|:--|:--|
| `locales` + `locales-all` | `glibc-locales` (core, 2.43+r22+g8362e8ce10b2-2) | VALIDATED — provides prebuilt `/usr/lib/locale/zh_CN.utf8/{LC_CTYPE,…}` and `/usr/lib/locale/en_US.utf8/…` |
| `tzdata` | `tzdata` (core, 2026d-1) | VALIDATED (pkg) |
| `fonts-wqy-microhei` | `wqy-microhei` (extra, 0.2.0_beta-12) | VALIDATED (pkg) |
| (Ubuntu `fonts-noto-cjk`) | `noto-fonts-cjk` (extra, 20240730-1) | VALIDATED (pkg) |
| (Ubuntu `fonts-arphic-uming/ukai`) | `ttf-arphic-uming` 0.2.20080216.2-3, `ttf-arphic-ukai` 0.2.20080216.2-3 (extra) | VALIDATED (pkg) |
| — (not installed by Debian build) | `adobe-source-han-sans-cn-fonts` (extra, 2.005-2) — recommended default CJK UI font for Plasma | VALIDATED (pkg) |
| (Ubuntu ibus stack) | `ibus` 1.5.34-1, `ibus-libpinyin` 1.16.5-4 (extra); or `fcitx5` 5.1.23-1, `fcitx5-chinese-addons` 5.1.15-1, `fcitx5-configtool` 5.1.16-2 | VALIDATED (pkg) — pick **one** stack; on Plasma 6 `fcitx5` integrates via the Wayland text-input protocol, `ibus` needs `ibus-daemon` autostart |

### 2.2 Files to write

`$ROOT/etc/locale.gen` — the Arch package already ships this file (VALIDATED: `glibc` ships `etc/locale.gen`),
so **uncomment/add** rather than replacing:

```
en_US.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
```

Generate (same command as Debian; `locale-gen` is shipped by `glibc`, VALIDATED at `usr/bin/locale-gen`):

```sh
chroot "$ROOT" locale-gen          # regenerates every uncommented entry
```

> Note: `locale-gen` writes into `/usr/lib/locale` on Arch (not `/var/lib/locale`). Because
> `glibc-locales` already ships `zh_CN.utf8`, running `locale-gen` is optional but harmless and keeps
> the image consistent if you change `locale.gen`.

`$ROOT/etc/locale.conf` — **this replaces Debian's `update-locale` / `/etc/default/locale`**:

```
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh
```

`$ROOT/etc/vconsole.conf` — the Debian script never writes one. If you want one on Arch:

```
KEYMAP=us
FONT=lat9w-16
```

(`lat9w-16.psfu.gz` and `LatArCyrHeb-16.psfu.gz` are both **VALIDATED** in the `kbd-2.10.0-1` package's
`usr/share/kbd/consolefonts/`. There is no CJK-capable console font in ALARM, which is exactly why the
Debian build documents "TTY uses English, SSH uses Chinese" — keep that behaviour.)

`$ROOT/etc/localtime` + `$ROOT/etc/timezone` — same as Debian:

```sh
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$ROOT/etc/localtime"
printf 'Asia/Shanghai\n' > "$ROOT/etc/timezone"
```

`$ROOT/etc/profile.d/99-locale-fix.sh` — **verbatim from script 07, works unchanged on Arch**
(`/etc/profile` sources `/etc/profile.d/*.sh` for login shells; `filesystem` ships
`etc/profile.d/locale.sh`, **VALIDATED**):

```sh
# 如果是SSH连接，则使用中文
if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
    export LANG=zh_CN.UTF-8
    export LANGUAGE=zh_CN:zh
    export LC_ALL=zh_CN.UTF-8
fi
```

### 2.3 Desktop language extras

The Debian/Ubuntu desktop builds additionally install GNOME/KDE translation packs and KDE cannot use
them. On Arch the equivalent work is done by the packages themselves (each KDE/Qt package ships
`usr/share/locale/zh_CN/LC_MESSAGES/*.mo` — e.g. `kscreen-6.7.5-1` ships `kscreen_common.mo`,
`kcm_kscreen.mo`, `kscreen_osd.mo` for `zh_CN`, **VALIDATED**). Nothing extra to install for KDE
translations; `plasma-desktop`/`plasma-workspace` pull them.

---

## 3. USB NCM gadget networking (script 10)

### 3.1 What the Debian script does

1. Writes `/etc/dnsmasq.d/usb-ncm.conf` — DHCP-only (`port=0` disables DNS) on `usb0`, range
   `172.16.42.2–172.16.42.254/24`, router option `3` = `172.16.42.1`, 1 h lease, `dhcp-authoritative`.
2. `systemctl enable dnsmasq`.
3. Writes `/usr/local/sbin/setup-usb-ncm.sh` — `modprobe libcomposite`, mount configfs, build gadget
   `g1` (VID `0x1d6b`, PID `0x0104`, bcdUSB `0x0200`, strings, `ncm.usb0` function), bind UDC, bring
   `usb0` up, add `172.16.42.1/24`, restart dnsmasq.
4. Writes + enables `usb-ncm.service` (oneshot, `RemainAfterExit=yes`, `After=network.target`,
   `DefaultDependencies=no`, `WantedBy=multi-user.target`).

### 3.2 Kernel side — mainline sm8150 with the vendor kernel **VALIDATED**

From `_recon/dl/x-image/boot/config-7.2.0-sm8150-g29662fdcefa9`:

```
CONFIG_CONFIGFS_FS=y
CONFIG_USB_GADGET=y
CONFIG_USB_LIBCOMPOSITE=y
CONFIG_USB_F_NCM=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_NCM=y
CONFIG_USB_DWC3=y
CONFIG_USB_DWC3_QCOM=y
CONFIG_USB_DWC3_DUAL_ROLE=y
```

All **built in** (`=y`), not modules. Consequences:

* `modprobe libcomposite` succeeds as a no-op — `kmod`'s `modprobe` finds built-in modules through
  `/usr/lib/modules/<ver>/modules.builtin` (shipped by the deb, VALIDATED present in `x-image`).
  Keep the line for portability; it is harmless.
* `modprobe` itself needs `kmod` (34.2-1, VALIDATED) — see §1 note.
* configfs is **not** mounted by the kernel; systemd provides `sys-kernel-config.mount`
  (**VALIDATED** at `usr/lib/systemd/system/sys-kernel-config.mount` inside `systemd-262-1`), so the
  `mount -t configfs` fallback in the script is redundant but safe. Prefer ordering after the unit.
* `usb0` requires the UDC (`/sys/class/udc/*`) to be present — i.e. the DWC3 driver must have probed
  and the USB role must be `peripheral`/`otg`. Unchanged from Debian.

### 3.3 `dnsmasq` — **the one real Arch difference**

* **VALIDATED**: the Arch `dnsmasq-2.93-1` package ships **only** `etc/dnsmasq.conf` and
  `usr/lib/systemd/system/dnsmasq.service`. There is **no `/etc/dnsmasq.d/` directory** in the package,
  and its shipped `/etc/dnsmasq.conf` has the include line **commented out**:

  ```
  # Include all files in a directory which end in .conf
  #conf-dir=/etc/dnsmasq.d/,*.conf
  ```

  Debian's `/etc/dnsmasq.conf` enables `conf-dir=/etc/dnsmasq.d/,*.conf`, which is why script 10 can
  just drop a file there.

* **Therefore the Arch build MUST do both:**
  1. `install -d "$ROOT/etc/dnsmasq.d"`
  2. append `conf-dir=/etc/dnsmasq.d/,*.conf` to `$ROOT/etc/dnsmasq.conf`.
     (Or write the whole config directly into `/etc/dnsmasq.conf`. The include-dir approach is
     preferred so it matches the Debian layout.)

* Arch's `dnsmasq.service` (**VALIDATED** contents) is `Type=dbus` with
  `ExecStart=/usr/bin/dnsmasq -k --enable-dbus --user=dnsmasq --pid-file` and
  `ExecStartPre=/usr/bin/dnsmasq --test`, plus `PrivateDevices=true` and `ProtectSystem=full`.
  `PrivateDevices` does **not** affect binding to `usb0` (netlink/socket only). `systemctl restart dnsmasq`
  inside the setup script works unchanged. **Note:** if `--test` fails on a malformed drop-in, the
  service fails *before* starting — which is actually a useful early check.

* **Recommended Arch-only hardening** (the Debian build does not do this and it causes flaky DHCP on
  NetworkManager systems): stop NetworkManager from trying to own `usb0`:

  `$ROOT/etc/NetworkManager/conf.d/99-usb-ncm-unmanaged.conf`
  ```
  [keyfile]
  unmanaged-devices=interface-name:usb0
  ```

### 3.4 `setup-usb-ncm.sh` — verbatim-but-Arch-correct

Two real bugs to fix while porting (they exist in the Debian version too):

* `set -e` + `mkdir -p $G` is **not** idempotent: a second start (or `systemctl restart`) fails at
  `echo $UDC > $G/UDC` with `Device or resource busy` because the gadget already exists. Unbind the UDC first.
* `serialnumber` is taken from `/etc/machine-id`. **Arch ships `/etc/machine-id` empty** (it is
  populated by `systemd-machine-id-setup` on first boot; the binary is **VALIDATED** at
  `usr/bin/systemd-machine-id-setup` in `systemd-262-1`). In an offline image build the value is
  therefore empty at first boot of the *first* boot — the gadget would advertise an empty serial.
  Seed it at build time:

  ```sh
  chroot "$ROOT" systemd-machine-id-setup
  ```

`$ROOT/usr/local/sbin/setup-usb-ncm.sh` (mode 0755):

```sh
#!/bin/sh
# USB CDC-NCM gadget setup for Xiaomi Redmi K20 Pro (raphael, sm8150)
# Arch Linux ARM port of the Debian script; idempotent.
set -e

GADGET=/sys/kernel/config/usb_gadget/g1
IP=172.16.42.1

# libcomposite/usb_f_ncm/configfs are built into the vendor kernel (=y),
# so this is a no-op success; kept for portability with modular kernels.
modprobe libcomposite

# systemd provides sys-kernel-config.mount; fall back to a manual mount.
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

# --- idempotence: unbind any existing gadget before rebuilding ------------
if [ -e "$GADGET/UDC" ]; then
    echo "" > "$GADGET/UDC" 2>/dev/null || true
fi

mkdir -p "$GADGET"
echo 0x1d6b > "$GADGET/idVendor"      # Linux Foundation
echo 0x0104 > "$GADGET/idProduct"     # Multifunction Composite Gadget
echo 0x0200 > "$GADGET/bcdUSB"

mkdir -p "$GADGET/strings/0x409"
echo "xiaomi-raphael" > "$GADGET/strings/0x409/manufacturer"
echo "NCM"            > "$GADGET/strings/0x409/product"
# /etc/machine-id must be non-empty; seed with `systemd-machine-id-setup`
# at image-build time, otherwise the descriptor serial is empty.
echo "$(cat /etc/machine-id)" > "$GADGET/strings/0x409/serialnumber"

mkdir -p "$GADGET/configs/c.1"
mkdir -p "$GADGET/configs/c.1/strings/0x409"
echo "NCM" > "$GADGET/configs/c.1/strings/0x409/configuration"

mkdir -p "$GADGET/functions/ncm.usb0"
# ln -sfn: do not fail if the link already exists from a previous run
ln -sfn "$GADGET/functions/ncm.usb0" "$GADGET/configs/c.1/"

UDC="$(ls /sys/class/udc | head -n 1)"
[ -n "$UDC" ] || { echo "setup-usb-ncm: no UDC found" >&2; exit 1; }
echo "$UDC" > "$GADGET/UDC"

# --- host side ------------------------------------------------------------
# The interface name is not guaranteed to be usb0 with systemd's predictable
# naming, but usb gadget netdevs have no PCI/SLOT id so the kernel keeps the
# name "usb0". Keep usb0 to stay byte-compatible with the dnsmasq config.
ip link set usb0 up
ip addr replace "$IP/24" dev usb0

systemctl restart dnsmasq || true
```

> If your `dnsmasq` drop-in uses `interface=usb0` and the interface ever gets renamed, dnsmasq would
> start but serve nothing. Keep `interface=usb0` and verify with `ip -br link` after first boot.

### 3.5 `usb-ncm.service` — Arch-correct unit

`$ROOT/etc/systemd/system/usb-ncm.service`:

```ini
[Unit]
Description=USB CDC-NCM gadget setup
Documentation=man:dnsmasq(8)
# configfs is a systemd unit on Arch - order after it explicitly.
After=network.target sys-kernel-config.mount
Wants=sys-kernel-config.mount
Before=dnsmasq.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-usb-ncm.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable:

```sh
chroot "$ROOT" systemctl enable usb-ncm.service dnsmasq.service
```

(The `dnsmasq` drop-in is not enabled by name here on purpose — the Debian script relies on
`systemctl enable dnsmasq` from inside script 10, which is what the line above reproduces.)

---

## 4. fstab, growfs-on-first-boot, root UUID (scripts 11 + 18)

### 4.1 fstab

The Debian file works **verbatim** on Arch. `x-systemd.growfs` is implemented by
`systemd-fstab-generator` + `systemd-growfs@.service`; **VALIDATED**: `systemd-262-1` contains
`usr/lib/systemd/system/systemd-growfs@.service`, `usr/lib/systemd/system/systemd-growfs-root.service`
and `usr/lib/systemd/system-generators/systemd-fstab-generator`.

`$ROOT/etc/fstab`:

```
PARTLABEL=userdata / ext4 errors=remount-ro,x-systemd.growfs 0 1
PARTLABEL=cache /boot vfat umask=0077 0 1
```

Notes:

* `PARTLABEL=` resolution needs a udev-populated `/dev/disk/by-partlabel/`, which requires the
  **`systemd`** mkinitcpio hook (see §10.3). With the busybox `udev` hook it also works, but the
  `systemd` hook is what ALARM's stock `HOOKS=` uses.
* `systemd-growfs@.service` runs `systemd-growfs` on the mount; for ext4 it resizes the filesystem to
  the block device. Because the flashed `rootfs.img` is smaller than the `userdata` partition, this is
  what gives you the full partition on first boot. No Debian/Arch difference.
* `umask=0077` on `/boot` means only root can read the ESP from Linux. systemd-boot reads it through
  EFI, so this is fine; `bootctl` needs root anyway.
* If you prefer not to depend on `PARTLABEL=` at all, `x-systemd.growfs` can be combined with
  `PARTUUID=<gpt-partuuid>` — but the existing image and the prebuilt boot image both use the
  partition *label*, so keep `PARTLABEL=` for compatibility.

### 4.2 growfs must not fight the FAT `/boot`

`x-systemd.growfs` is only on the ext4 root. Do **not** add it to the vfat `/boot` line — vfat cannot
be grown and `systemd-growfs` will fail noisily.

### 4.3 Root UUID / kernel command line

Script 18 forces `tune2fs -U ee8d3593-59b1-480e-a3b6-4fefb17ee7d8` and notes the legacy cmdline
`root=PARTLABEL=userdata`.

On Arch + systemd-boot the cmdline lives in the loader entry on the FAT `/boot`, so:

* Either keep `root=PARTLABEL=userdata` (recommended — same semantics as Debian, robust to
  re-flashing a differently-UUID'd image), or
* use `root=UUID=ee8d3593-59b1-480e-a3b6-4fefb17ee7d8` if you also run `tune2fs -U`.

Do **not** put the UUID in `/etc/fstab` unless you also fix it in the loader entry — the two must agree.
`tune2fs` is in `e2fsprogs-1.47.4-1` (**VALIDATED (pkg)**).

---

## 5. Users, passwords, SSH password login, sudo (script 12)

The Debian script does:

```sh
echo "root:${ROOT_PASS}" | chroot rootdir chpasswd
chroot rootdir useradd -m -G sudo -s /bin/bash ${USER_NAME}
echo "${USER_NAME}:${USER_PASS}" | chroot rootdir chpasswd
echo "PermitRootLogin yes"    >> rootdir/etc/ssh/sshd_config
echo "PasswordAuthentication yes" >> rootdir/etc/ssh/sshd_config
```

### 5.1 What changes on Arch

| Item | Debian | Arch Linux ARM |
|:--|:--|:--|
| Privileged group | `sudo` | **`wheel`**. `sudo-1.9.17.p2-6`'s `/etc/sudoers` has `# %wheel ALL=(ALL:ALL) ALL` **commented out** and `@includedir /etc/sudoers.d` **active** (VALIDATED by reading the shipped file). Nothing grants sudo until you write a drop-in. |
| Root shell | `/bin/bash` on Debian | `/bin/bash` — but Arch's real path is `/usr/bin/bash`; `/bin` is a symlink to `usr/bin` (VALIDATED), so `/bin/bash` still resolves. Prefer `/usr/bin/bash`. |
| SSH config | append to `/etc/ssh/sshd_config` | `openssh-10.5p1-1`'s `/etc/ssh/sshd_config` has `Include /etc/ssh/sshd_config.d/*.conf` as **line 2** (VALIDATED). sshd is **first-match-wins**, so a drop-in placed in `sshd_config.d/` **overrides** the commented defaults in the main file. Use a drop-in; appending to the main file also works but is not the Arch idiom. |
| `useradd` | available | `shadow-4.20.0.arch1-1` provides `usr/bin/useradd`, `usr/bin/chpasswd`, `usr/bin/pwconv`, `usr/bin/grpconv` (VALIDATED). `useradd` works fine inside a `chroot`/`systemd-nspawn`. |

Two supported ways to do it offline; the task asks for the **file-writing** way, which is given in §5.2.
`useradd` + `chpasswd` inside the rootfs also works on Arch — the only required change is
`useradd -m -G wheel -s /usr/bin/bash`.

### 5.2 Pure file-based creation (no `useradd`, no chroot exec)

Pick a UID/GID. `useradd` on Debian picks the first free UID ≥ 1000, which is **1000** on a fresh
image. Use 1000 to stay identical.

```sh
USER_NAME=user
USER_UID=1000
USER_GID=1000
USER_PASS=1234
ROOT_PASS=1234
```

**Passwords** — SHA-512 crypt, exactly what `chpasswd`/`useradd` produce on Debian:

```sh
ROOT_HASH=$(openssl passwd -6 "$ROOT_PASS")
USER_HASH=$(openssl passwd -6 "$USER_PASS")
```

`openssl-3.6.4-1` ships `usr/bin/openssl` (**VALIDATED**), and `openssl passwd -6` is available on the
build host regardless of distro. Append nothing after the hash — no `:0:99999:7:::`, `openssl passwd`
returns only the `$6$…` field.

`$ROOT/etc/passwd` — append (do **not** rewrite the file; `filesystem` ships the base one):

```
user:x:1000:1000::/home/user:/usr/bin/bash
```

`$ROOT/etc/shadow` — append:

```
user:${USER_HASH}:19000:0:99999:7:::
```

Set root's hash by **replacing** the existing `root:` line (the `filesystem`-shipped `/etc/shadow` has
`root:!::0:::::` or similar — must be replaced, not appended, or root stays locked):

```
root:${ROOT_HASH}:19000:0:99999:7:::
```

`$ROOT/etc/group` — append:

```
wheel:x:998:user
user:x:1000:
```

> `wheel`'s GID: use whatever `$ROOT/etc/group` already has for `wheel` (ALARM's base `/etc/group`
> defines it; typically **998**). Do **not** hard-code — grep it:
> `WHEEL_GID=$(awk -F: '$1=="wheel"{print $3}' "$ROOT/etc/group")` and fall back to creating the line
> `wheel:x:998:` if absent. The `user` line is only needed if you want an explicit `user` group; it is
> harmless to include it and keep `/etc/passwd`'s GID consistent.

`$ROOT/etc/gshadow` — append (the group must have a matching gshadow entry, otherwise `grpconv`
regenerates it without the membership and `wheel` membership can be lost):

```
wheel:!::user
user:!::user
```

Then normalize the shadow databases with the **VALIDATED** tools from `shadow-4.20.0.arch1-1`:

```sh
chroot "$ROOT" pwconv     # /etc/shadow  <- /etc/passwd
chroot "$ROOT" grpconv    # /etc/gshadow <- /etc/group
```

`pwconv`/`grpconv` are idempotent and will not clobber a valid `$6$` hash.

**sudo** — `$ROOT/etc/sudoers.d/10-wheel` (mode `0440`, owner `root:root`):

```
%wheel ALL=(ALL:ALL) ALL
```

> `sudo` refuses to run if `/etc/sudoers.d` is group/world-writable or if a drop-in contains a `.` or
> `~`. Verify the drop-in with `chroot "$ROOT" visudo -cf /etc/sudoers` (or
> `visudo -cf /etc/sudoers.d/10-wheel`) and set mode 0440.

If you want the Debian behaviour exactly (`user` in a `sudo` group), you can instead write
`$ROOT/etc/sudoers.d/10-sudo-group` with `%sudo ALL=(ALL:ALL) ALL` and put `user` in a `sudo` group —
but `wheel` is the Arch convention and is what `polkit`/`system-config` tooling assumes.

**Home directory** — the file-based path does not create it. Do it explicitly:

```sh
install -d -m 0755 -o 1000 -g 1000 "$ROOT/home/$USER_NAME"
cp -a "$ROOT/etc/skel/." "$ROOT/home/$USER_NAME/"
chown -R 1000:1000 "$ROOT/home/$USER_NAME"
```

(`filesystem` ships `/etc/skel/`, VALIDATED.)

### 5.3 SSH password login

`$ROOT/etc/ssh/sshd_config.d/10-raphael-auth.conf`:

```
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
```

Why this and not appending to `/etc/ssh/sshd_config`:

* `openssh-10.5p1-1` ships `etc/ssh/sshd_config.d/99-archlinux.conf` (**VALIDATED**) containing:
  ```
  # sshd_config defaults on Arch Linux
  KbdInteractiveAuthentication no
  UsePAM yes
  PrintMotd no
  ```
  `Include /etc/ssh/sshd_config.d/*.conf` is **line 2** of `sshd_config`, so drop-ins are parsed
  before the main body. sshd uses the **first** obtained value → your drop-in wins. Name it `10-…`
  so it sorts **before** `99-archlinux.conf`. (Since both set `KbdInteractiveAuthentication`, `10-`
  wins for that key too — hence the explicit line above, so `PasswordAuthentication` via PAM works.)
* `PermitRootLogin` default on Arch is `prohibit-password` (commented out in `sshd_config`,
  VALIDATED line 34) → without the drop-in, root could only log in with a key.

Enable the service (**VALIDATED**: `usr/lib/systemd/system/sshd.service` in `openssh-10.5p1-1`):

```sh
chroot "$ROOT" systemctl enable sshd.service
```

---

## 6. Power management (script 13)

### 6.1 Mask sleep/suspend targets — identical on Arch

```sh
chroot "$ROOT" systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

No Debian/Arch difference. Note: the Debian script only does this for non-server images
(`SYSTEM_TYPE != *server*`). On a phone there is no firmware S3/hibernation support, so masking
unconditionally is safer; keep it conditional only if you want to match Debian bit-for-bit.
`systemctl mask` creates symlinks to `/dev/null` in `/etc/systemd/system/`, which survives the
`mkinitcpio`/pacman operations that follow.

### 6.2 NetworkManager wifi powersave

`$ROOT/etc/NetworkManager/conf.d/wifi-powersave.conf`:

```
[connection]
wifi.powersave = 2
```

**VALIDATED**: `networkmanager-1.58.1-1` ships `etc/NetworkManager/conf.d/` (and
`etc/NetworkManager/NetworkManager.conf`). Writing a file into that directory is exactly the same as
on Debian. Value `2` = `NM_SETTING_WIRELESS_POWERSAVE_DISABLE`. This is the fix for the "Wi-Fi ping
spikes" symptom noted in script 13 and is still required.

Also drop NM's own netplan-style config — **netplan does not exist on Arch**, skip
`/etc/netplan/01-network-manager-all.yaml` entirely. NetworkManager on Arch is the default renderer
with no extra configuration.

### 6.3 `ath10k` `skip_otp=y` — what it is and whether it is still needed

`$ROOT/etc/modprobe.d/ath10k.conf`:

```
options ath10k_core skip_otp=y
```

**What it does.** `skip_otp` is an `ath10k_core` module parameter. With it set, the driver skips
reading/validating the **OTP (one-time-programmable) calibration/board-data area** on the WLAN chip
and instead uses the pre-calibrated values supplied by the firmware/board file. It exists for
Qualcomm WCN3990-class parts whose OTP region is inaccessible or unprogrammed on mainline (the vendor
boot chain normally programs it), which otherwise produces
`ath10k_snoc … failed to fetch board data` / `failed to read otp` and a dead WLAN interface.

**Is it still needed with kernel 7.2 + the vendor firmware in `_recon/dl/x-fw/`?**

Evidence, all **VALIDATED**:

* `_recon/dl/x-image/boot/config-7.2.0-sm8150-g29662fdcefa9`:
  `CONFIG_ATH10K=m`, `CONFIG_ATH10K_SNOC=m`, `CONFIG_ATH10K_CE=y`, `CONFIG_CFG80211=m`,
  `CONFIG_MAC80211=m`. So `ath10k_snoc` is a module and `skip_otp` is settable.
* The firmware package **does** ship a complete, device-specific WCN3990 set, but **only
  zstd-compressed**:
  `usr/lib/firmware/ath10k/WCN3990/hw1.0/{board-2.bin.zst, firmware-5.bin.zst, notice.txt_wlanmdsp.zst, wlanmdsp.mbn.zst}`
  plus `usr/lib/firmware/qca/crnv21.bin.zst`.
* Only 5 files in the whole 200 MB firmware tree are `.zst` — those 5. Everything else is plain.

**Answer.** The parameter is **still required**: nothing in the vendor firmware package replaces it
(the `board-2.bin` it ships is the *generic* WCN3990 board file, and the OTP path on this mainline
port is the thing that fails). Keep the file exactly as the Debian script writes it. It is
**harmless if it later becomes unnecessary** — the kernel just ignores an unused parameter value, and
`modprobe` only warns if the *module* is absent.

⚠ **Conflict you must handle** (see §11.3): ALARM's `linux-firmware-atheros-20260916-1` ships
**uncompressed** `usr/lib/firmware/ath10k/WCN3990/hw1.0/{board-2.bin,firmware-5.bin,wlanmdsp.mbn}`
at exactly the same logical names as the vendor `.zst` files. The kernel's firmware loader tries the
**unsuffixed name first**, so if both are installed the *upstream* board file wins and the vendor one
is ignored — which is the opposite of what you want.

---

## 7. Power key handling (script 14) — GNOME → KDE/Plasma-Wayland

### 7.1 Step-by-step: what the 295-line Debian script actually does

| # | Step | Lines | Desktop-specific? |
|:--|:--|:--|:--|
| 1 | **Bail out unless `DESKTOP_ENV == gnome`** | 4–7 | — (gate) |
| 2 | `POWER_KEY_USER=${USER_NAME:-user}` | 10 | no |
| 3 | Write `/etc/systemd/logind.conf.d/power-key.conf` with `HandlePowerKey=ignore`, `HandlePowerKeyLongPress=ignore`, `PowerKeyIgnoreInhibited=yes` — makes logind stop acting on the power key so userspace can own it | 15–21 | **no — desktop-agnostic** |
| 4 | Write `/usr/local/sbin/power-key-handler.py` (mode 755): find the evdev node whose `/sys/class/input/inputN/name` is `pm8941_pwrkey`, `open(O_RDONLY\|O_NONBLOCK)`, `select()` loop, `struct.unpack("llHHi")`, `EV_KEY`/`KEY_POWER` (116): on `value==1` start a 1.0 s `threading.Timer`; on `value==0` cancel it and, if it never fired, treat it as a short press → toggle screen. Long-press fires `show_power_menu()` | 25–249 | partly |
| 5 | Short press → `query_screensaver_active()` via `gdbus call --dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver --method org.gnome.ScreenSaver.GetActive`, then `SetActive true/false` | 100–147 | **GNOME-only** |
| 6 | Long press → `busctl --user call org.gnome.SessionManager /org/gnome/SessionManager org.gnome.SessionManager RequestShutdown`, fallback `gnome-session-quit --power-off` | 150–162 | **GNOME-only** |
| 7 | `wait_for_session()` polls up to 120 s for `/run/user/<uid>/bus` **and** `pgrep -u user -x gnome-shell` | 165–186 | **GNOME-only** |
| 8 | Writes `/etc/systemd/user/power-key-handler.service` (`Type=simple`, `Environment=USER_NAME=…`, `Restart=always`, `RestartSec=5`, `WantedBy=graphical-session.target`) and symlinks it into `/etc/systemd/user/graphical-session.target.wants/` | 253–271 | partly |
| 9 | `touch /var/lib/systemd/linger/<user>` so the user manager starts at boot without a login | 273–274 | **no — desktop-agnostic** |
| 10 | dconf: `/etc/dconf/profile/user` + `/etc/dconf/db/local.d/01-power-key` with `power-button-action='nothing'`, then `dconf update` — tells **gnome-settings-daemon** not to also handle the key | 277–288 | **GNOME-only** |
| 11 | udev rule `/etc/udev/rules.d/99-power-key.rules`: `ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="pm8941_pwrkey", MODE="0666"` — lets the (unprivileged) reader open the node | 291–293 | **no — desktop-agnostic** |

### 7.2 Should the GNOME script just be dropped on KDE? — **Yes, the GNOME parts must be dropped; the file cannot run at all on Plasma.**

Concretely, running `power-key-handler.py` unmodified inside a Plasma session fails in three
independent ways:

1. **It can never get past `wait_for_session()`.** It runs `pgrep -u user -x gnome-shell`. On Plasma
   there is no `gnome-shell` process, so after 120 s it returns `False` and `main()` calls `sys.exit(1)`.
   `Restart=always` + `RestartSec=5` then restarts it — forever, at 5 s intervals, each time burning
   120 s of idle polling. You get an infinite restart loop that never reads the power key.
2. **Even with that bypassed, all three DBus calls hit services that do not exist.** Plasma provides
   neither `org.gnome.ScreenSaver` nor `org.gnome.SessionManager`. `blank_screen()` / `wake_screen()`
   ignore the return code of `subprocess.run`, so every short press would be a **silent no-op**.
   `show_power_menu()` would fall through to `gnome-session-quit --power-off`, which is not installed.
3. **The dconf `power-button-action='nothing'` key is a gnome-settings-daemon setting.** dconf exists
   on Arch (`dconf-0.49.0-1`, **VALIDATED**) but nothing on Plasma reads that key, so it does nothing —
   harmless, but pointless, and it drags in `/etc/dconf/profile/user` which you do not want.

**Verdict: drop steps 5, 6, 7, 10 and the `gnome-session-quit` fallback. Keep steps 3, 9, 11 verbatim,
and re-implement step 4 with KDE-native calls and a KDE-aware session check.**

### 7.3 Keep verbatim — desktop-agnostic

`$ROOT/etc/systemd/logind.conf.d/power-key.conf`:

```ini
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
PowerKeyIgnoreInhibited=yes
```

> ⚠ `PowerKeyIgnoreInhibited=yes` means "ignore inhibitor locks and act anyway". Paired with
> `HandlePowerKey=ignore` logind does nothing either way, so it is currently inert — but it is a
> landmine: if you ever flip `HandlePowerKey` back to a real action, this setting makes logind
> **override the desktop session's inhibitor**, which is exactly what breaks KDE/GNOME power handling.
> Consider **omitting** `PowerKeyIgnoreInhibited=yes` on Arch.
>
> `HandlePowerKeyLongPress=` is understood by `systemd-262-1` (**VALIDATED (pkg)**, systemd ≥ 256).
> The Debian script sets it to `ignore` because the Python daemon does its own 1 s timer. If you drop
> the daemon you can use it: `HandlePowerKeyLongPress=poweroff`.

`$ROOT/etc/udev/rules.d/99-power-key.rules`:

```
ACTION=="add", SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="pm8941_pwrkey", MODE="0666"
```

**VALIDATED** kernel side: `CONFIG_INPUT_PM8941_PWRKEY=y` in the vendor config, so `/sys/class/input/inputN/name`
really is `pm8941_pwrkey` and the `ATTRS{name}` match works.
⚠ Note `MODE="0666"` is world-readable *and* world-writable. The daemon only needs read. Prefer
`MODE="0640", GROUP="input"` and add the user to the `input` group, or keep 0666 to stay identical to
Debian. Your call; 0666 matches the Debian image.

Linger (unchanged):

```sh
install -d -m 0755 "$ROOT/var/lib/systemd/linger"
touch "$ROOT/var/lib/systemd/linger/$USER_NAME"
```

### 7.4 KDE/Plasma-Wayland replacement daemon

Only three things change relative to the Debian script:
**(a)** the ScreenSaver bus name/object path, **(b)** the power-menu call, **(c)** the session-ready check.

**(a) Blank / wake.** The portable interface is the **freedesktop** ScreenSaver spec, which
`kscreenlocker` (extra, 6.7.5-1, **VALIDATED (pkg)**) implements alongside `org.kde.screensaver`:
`org.freedesktop.ScreenSaver` at object path `/ScreenSaver`, methods `SetActive(bool)` and `GetActive()`.
So change `--dest org.gnome.ScreenSaver --object-path /org/gnome/ScreenSaver` to
`--dest org.freedesktop.ScreenSaver --object-path /ScreenSaver` and **keep the method names**.

Alternative if you want *panel off without locking* — `kscreen-doctor`, which is shipped by
**`libkscreen-6.7.5-1`** (⚠ **not** by `kscreen-6.7.5-1` — **VALIDATED**: `usr/bin/kscreen-doctor`
lives in `libkscreen`, `kscreen` only ships `kscreen-console` and `hdrcalibrator`):

```sh
kscreen-doctor --dpms off     # panel off
kscreen-doctor --dpms on      # panel on
```

(read the current state via the KScreen DBus API, or just keep a local boolean in the daemon —
the `--dpms show` sub-command is **UNVERIFIED**).

**(b) Power menu.** Plasma 6 exposes `org.kde.Shutdown` (from `plasma-workspace`). The
"show the Leave dialog" call is **UNVERIFIED** (`org.kde.Shutdown`/`/Shutdown`/`logout`); verify with
`busctl --user introspect org.kde.Shutdown /Shutdown` on device. Deterministic fallbacks you can rely on:

```sh
systemctl poweroff                    # no dialog, always works
qdbus6 org.kde.Shutdown /Shutdown org.kde.Shutdown.logout   # UNVERIFIED: Leave dialog
```

`qdbus6` is shipped by **`qt6-tools-6.11.2-1`** (**VALIDATED**).

**(c) Session-ready check.** Replace `pgrep -x gnome-shell` with the KDE Wayland compositor, or better,
poll for the *bus name* instead of a process name (works for X11 and Wayland, any desktop):

```sh
busctl --user --quiet is-active org.freedesktop.ScreenSaver
```

### 7.5 Full Arch/KDE daemon

`$ROOT/usr/local/sbin/power-key-handler.py` (mode 0755). This is the Debian script with the three
changes above; the evdev/long-press logic is untouched.

```python
#!/usr/bin/env python3
"""
Power Key Handler for KDE Plasma 6 (Wayland or X11) on Xiaomi Redmi K20 Pro.

Behaviour ported from the Debian/GNOME phosh-derived handler:
  - Short press (< 1s): toggle screen blank/wake
  - Long press (>= 1s): power menu

Changes vs. the GNOME original:
  * org.gnome.ScreenSaver        -> org.freedesktop.ScreenSaver (implemented by
                                    kscreenlocker; path /ScreenSaver, not
                                    /org/gnome/ScreenSaver)
  * org.gnome.SessionManager RequestShutdown / gnome-session-quit
                                 -> systemctl poweroff (see show_power_menu())
  * pgrep -x gnome-shell         -> wait for the org.freedesktop.ScreenSaver
                                    name on the session bus (desktop-agnostic)
  * dconf power-button-action    -> not applicable / dropped
"""
import logging
import os
import select
import struct
import subprocess
import sys
import threading
import time

EV_KEY = 0x01
KEY_POWER = 116
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
LONG_PRESS_SEC = 1.0

SAVER_DEST = "org.freedesktop.ScreenSaver"
SAVER_PATH = "/ScreenSaver"
SAVER_IFACE = "org.freedesktop.ScreenSaver"

logging.basicConfig(level=logging.INFO, format="power-key: %(message)s", stream=sys.stdout)
log = logging.getLogger("power-key")


def get_user():
    user = os.environ.get("USER_NAME")
    if user:
        return user
    import pwd
    return pwd.getpwuid(os.getuid()).pw_name


def find_power_input():
    """Locate the pm8941_pwrkey evdev device (CONFIG_INPUT_PM8941_PWRKEY=y)."""
    from pathlib import Path
    base = Path("/sys/class/input")
    for name_path in sorted(base.glob("input*/name")):
        try:
            name = name_path.read_text().strip()
        except OSError:
            continue
        if name == "pm8941_pwrkey":
            num = name_path.parent.name.replace("input", "")
            dev = Path(f"/dev/input/event{num}")
            if dev.exists():
                return str(dev)
    return "/dev/input/event0"


def get_env():
    """Build the user session environment for gdbus/busctl calls."""
    user = get_user()
    import pwd
    uid = pwd.getpwnam(user).pw_uid
    runtime = f"/run/user/{uid}"
    env = os.environ.copy()
    env.update({
        "HOME": f"/home/{user}",
        "USER": user,
        "LOGNAME": user,
        "XDG_RUNTIME_DIR": runtime,
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime}/bus",
    })
    for disp in ("wayland-0", "wayland-1"):
        if os.path.exists(f"{runtime}/{disp}"):
            env["WAYLAND_DISPLAY"] = disp
            break
    return env


def query_screensaver_active():
    env = get_env()
    try:
        r = subprocess.run(
            ["gdbus", "call", "--session",
             "--dest", SAVER_DEST,
             "--object-path", SAVER_PATH,
             "--method", f"{SAVER_IFACE}.GetActive"],
            env=env, capture_output=True, text=True, timeout=2)
        return "(true" in r.stdout
    except Exception as e:
        log.warning("GetActive failed: %s", e)
        return False


def _set_active(active: bool):
    env = get_env()
    log.info("SetActive %s", active)
    try:
        subprocess.run(
            ["gdbus", "call", "--session",
             "--dest", SAVER_DEST,
             "--object-path", SAVER_PATH,
             "--method", f"{SAVER_IFACE}.SetActive",
             "true" if active else "false"],
            env=env, timeout=3, check=False)
    except Exception as e:
        log.warning("SetActive failed: %s", e)


def toggle_screen():
    active = query_screensaver_active()
    log.info("screensaver active=%s", active)
    _set_active(not active)


def show_power_menu():
    """Long press. Plasma's Leave dialog is org.kde.Shutdown (UNVERIFIED);
    fall back to a direct poweroff, which always works."""
    env = get_env()
    log.info("show power menu (long press)")
    r = subprocess.run(
        ["busctl", "--user", "call",
         "org.kde.Shutdown", "/Shutdown", "org.kde.Shutdown", "logout"],
        env=env, capture_output=True, text=True, timeout=3)
    if r.returncode != 0:
        log.warning("org.kde.Shutdown unavailable, using systemctl poweroff")
        subprocess.Popen(["systemctl", "poweroff"], env=env)


def wait_for_session(timeout=120):
    """Wait until kscreenlocker has claimed the ScreenSaver name on the
    session bus. Desktop-agnostic; no gnome-shell / plasmashell process name."""
    user = get_user()
    import pwd
    uid = pwd.getpwnam(user).pw_uid
    bus_path = f"/run/user/{uid}/bus"
    log.info("waiting for the %s session bus + ScreenSaver name", user)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(bus_path):
            r = subprocess.run(
                ["busctl", "--user", "--quiet", "is-active", SAVER_DEST],
                env=get_env(), capture_output=True, text=True)
            # is-active prints "active"/"inactive"/... and exits 0 for a known name
            if r.stdout.strip() == "active":
                time.sleep(2)
                log.info("session ready")
                return True
        time.sleep(1)
    log.error("session not ready after %ss", timeout)
    return False


def main():
    if not wait_for_session():
        sys.exit(1)

    dev = find_power_input()
    fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
    log.info("listening on %s", dev)

    state = {"press_time": None, "long_fired": False, "timer": None, "pressed": False}

    def cancel_long_timer():
        if state["timer"] is not None:
            state["timer"].cancel()
            state["timer"] = None

    def on_long_press():
        if not state["pressed"]:
            return
        state["long_fired"] = True
        show_power_menu()

    while True:
        r, _, _ = select.select([fd], [], [], 1.0)
        if not r:
            continue
        data = os.read(fd, EVENT_SIZE)
        if len(data) < EVENT_SIZE:
            continue
        _sec, _usec, ev_type, code, value = struct.unpack(EVENT_FMT, data)
        if ev_type != EV_KEY or code != KEY_POWER:
            continue
        log.info("KEY_POWER value=%s", value)
        if value == 1:
            if not state["pressed"]:
                state["pressed"] = True
                state["press_time"] = time.monotonic()
                state["long_fired"] = False
                cancel_long_timer()
                t = threading.Timer(LONG_PRESS_SEC, on_long_press)
                t.daemon = True
                t.start()
                state["timer"] = t
        elif value == 0 and state["press_time"] is not None:
            state["pressed"] = False
            cancel_long_timer()
            if not state["long_fired"]:
                if time.monotonic() - state["press_time"] < LONG_PRESS_SEC:
                    toggle_screen()
            state["press_time"] = None


if __name__ == "__main__":
    main()
```

`$ROOT/etc/systemd/user/power-key-handler.service` — note `WantedBy=plasma-workspace.target`
(**VALIDATED**: `usr/lib/systemd/user/plasma-workspace.target` is shipped by
`plasma-workspace-6.7.5-1`), which is the KDE counterpart of `graphical-session.target`:

```ini
[Unit]
Description=Power key handler (short press: toggle screen, long press: power menu)
After=plasma-workspace.target
Wants=plasma-workspace.target

[Service]
Type=simple
Environment=USER_NAME=user
ExecStart=/usr/bin/python3 /usr/local/sbin/power-key-handler.py
Restart=always
RestartSec=5

[Install]
WantedBy=plasma-workspace.target
```

Enable:

```sh
install -d "$ROOT/etc/systemd/user/plasma-workspace.target.wants"
ln -sf /etc/systemd/user/power-key-handler.service \
       "$ROOT/etc/systemd/user/plasma-workspace.target.wants/power-key-handler.service"
install -d "$ROOT/var/lib/systemd/linger"
touch "$ROOT/var/lib/systemd/linger/$USER_NAME"
```

### 7.6 KDE-native alternative (no custom daemon at all)

If you are willing to give up "short press toggles blank" and "long press opens a menu", you can drop
the daemon entirely and let logind + PowerDevil own the key:

`$ROOT/etc/systemd/logind.conf.d/power-key.conf`:

```ini
[Login]
HandlePowerKey=ignore
HandlePowerKeyLongPress=ignore
```

and set PowerDevil's power-button action. **VALIDATED**: `powerdevil-6.7.5-2` ships
`usr/lib/systemd/user/plasma-powerdevil.service` and `etc/xdg/autostart/powerdevil.desktop`, and its
`kcm_powerdevilprofilesconfig.so` binary contains a `PowerButtonActionModel` with the option strings
`Do nothing / Sleep / Hibernate / Hybrid sleep / Turn off screen / Lock screen / Prompt logout / Shut down`,
plus the config symbol `PowerDevil::PowerButtonAction`.

⚠ **UNVERIFIED**: the exact `powerdevilrc` group header and the exact enum literal for the saved value.
Because PowerDevil's own KCM writes it, the robust instruction is: **set it once from the GUI**
(System Settings → Power Management → Energy Saving → *When power button pressed*) and then read back
the key with `kreadconfig6 --file powerdevilrc --group '<group>' --key PowerButtonAction`, then bake
that literal into `/etc/xdg/powerdevilrc` for the image. Do **not** copy a guessed literal into the
image. Also note: I could **not** find any `handle-power-key` logind inhibitor string in
`powerdevil-6.7.5-2`, so whether PowerDevil receives `KEY_POWER` at all on this stack is
**UNVERIFIED** — test on device before relying on it.

---

## 8. zram (script 15)

### 8.1 What Debian does

`zram-tools` provides `/etc/default/zramswap` + a `zramswap.service`. Script 15 edits
`ALGO=zstd`, comments out `PERCENT=`, sets `SIZE=10240` (MiB) and enables `zramswap`.

### 8.2 Arch equivalent — `zram-generator` (VALIDATED)

* **✗ `zram-tools` / `zramswap` do not exist in ALARM** (no `zram-tools` in `core.db` or `extra.db`).
  **No `zramswap.service` exists either.**
* **VALIDATED** replacement: `zram-generator-1.2.1-1` (extra). Its package file list contains
  `usr/lib/systemd/system-generators/zram-generator`,
  `usr/lib/systemd/system/systemd-zram-setup@.service`,
  `usr/share/doc/zram-generator/zram-generator.conf.example`,
  `usr/share/man/man5/zram-generator.conf.5.gz`, `usr/share/man/man8/zram-generator.8.gz`.
* The config path is confirmed by the **shipped man page**: `/usr/lib/systemd/zram-generator.conf`,
  `/usr/local/lib/systemd/zram-generator.conf`, **`/etc/systemd/zram-generator.conf`**,
  `/run/systemd/zram-generator.conf` (plus `.conf.d/` variants).
* There is **no `systemctl enable`** step: `zram-generator` is a **systemd generator**. It runs on
  every `daemon-reload`/boot and creates `dev-zram0.swap` + `systemd-zram-setup@zram0.service`
  dynamically. The Debian `systemctl enable zramswap` has no Arch counterpart and must be dropped.

### 8.3 Config file

`$ROOT/etc/systemd/zram-generator.conf` — sized identically to Debian (10 GiB = 10240 MiB, zstd):

```ini
# zram swap for Xiaomi Redmi K20 Pro (raphael, SM8150, 6/8 GB RAM)
# Debian equivalent: /etc/default/zramswap with ALGO=zstd, SIZE=10240
[zram0]
zram-size = 10240
compression-algorithm = zstd
```

Notes:

* `zram-size` takes an expression and is evaluated against `ram` (MemTotal in MB). A bare number is
  allowed and means a **fixed** size in MB — this is the literal equivalent of `SIZE=10240`. The
  default (`min(ram / 2, 4096)`) is *not* what Debian configured, so you must set it explicitly.
* If you would rather not hard-code 10 GiB on a 6 GB device, `zram-size = min(ram, 10240)` reproduces
  "up to 10 GiB, never more than RAM". The Debian image uses the hard `10240`; keep it for parity.
* `compression-algorithm = zstd` is **also the kernel default here**: the vendor config has
  `CONFIG_ZRAM_DEF_COMP="zstd"`, `CONFIG_ZRAM_DEF_COMP_ZSTD=y`, `CONFIG_ZRAM_BACKEND_ZSTD=y`
  (**VALIDATED**). Setting it explicitly is still recommended (it makes the intent explicit and
  survives a kernel swap).
* Kernel side: `CONFIG_ZRAM=m` — **the module must be loaded**. `zram-generator` runs `modprobe`
  itself (its binary embeds a `modprobe "{module}" failed, ignoring: …` message, **VALIDATED** by
  `strings` on the extracted binary), so nothing extra is required — but for a deterministic offline
  image you can add a belt-and-braces module load:

  `$ROOT/etc/modules-load.d/zram.conf`
  ```
  zram
  ```

  `systemd-modules-load.service` and `etc/modules-load.d/` are **VALIDATED** present in
  `systemd-262-1`. This costs nothing and removes any dependency on generator internals.

* `ALGO=zstd` in Debian requires `PERCENT` to be disabled — on Arch there is no `PERCENT`, only
  `zram-size`, so that whole dance disappears.

---

## 9. Audio (script 16 + the `alsa-xiaomi-raphael.deb` UCM package)

### 9.1 Packages (all **VALIDATED (pkg)**)

| Debian | Arch Linux ARM | Version | Notes |
|:--|:--|:--|:--|
| `alsa-ucm-conf` (Depends of the vendor deb) | `alsa-ucm-conf` (extra) | 1.2.16.1-1 | required before you copy the vendor UCM in |
| `alsa-utils` | `alsa-utils` (extra) | 1.2.16-1 | `alsamixer`, `aplay`, `amixer` — needed for debugging `cset` lines |
| `pipewire` | `pipewire` (extra) | 1:1.6.9-1 | |
| `pipewire-pulse` | `pipewire-pulse` (extra) | 1:1.6.9-1 | |
| (pipewire ALSA compat) | `pipewire-alsa` (extra) | 1:1.6.9-1 | makes plain ALSA apps go through PipeWire — install it, otherwise the UCM `PlaybackPCM "hw:0,N"` is bypassed in confusing ways |
| `wireplumber` | `wireplumber` (extra) | 0.5.17-2 | **0.5.x — config format changed, see §9.4** |
| (optional) | `pipewire-audio` (extra) | 1:1.6.9-1 | pulls the common audio session bits |
| `pulseaudio-utils`/`pavucontrol` | `pavucontrol` (extra) | 1:6.2-1 | VALIDATED (pkg) — verify the Speaker/Headphone ports appear |

### 9.2 Where the vendor UCM files go

The `alsa-xiaomi-raphael.deb` payload is (**VALIDATED** by listing `_recon/dl/x-alsa/`):

```
usr/share/alsa/ucm2/Raphael/Raphael.conf
usr/share/alsa/ucm2/Raphael/HiFi.conf
usr/share/alsa/ucm2/conf.d/sm8150_raphael/sm8150_raphael.conf
usr/share/alsa/ucm2/conf.d/sm8150_raphael/xiaomi-XiaomiRedmiK20Pro.conf
usr/share/alsa/ucm2/conf.d/sm8150_raphael/HiFi.conf
```

**Copy all five to the identical paths under `$ROOT`.** `/usr/share` is the same on Arch; nothing is
Debian-specific about these paths.

Why both layouts exist — the lookup order is defined by the **shipped** `alsa-ucm-conf` file
`/usr/share/alsa/ucm2/ucm.conf` (**VALIDATED**, read from the extracted package). Its `Syntax 4` body is:

```
Define.V1 ""            # non-empty enables ucm v1 paths        -> v1 paths DISABLED
Define.V2ConfD yes      # empty disables                       -> conf.d paths ENABLED
Define.V2Module ""      # non-empty enables module lookups      -> DISABLED (obsolete)
Define.V2Name ""        # non-empty enables driver & card name  -> DISABLED (obsolete)
...
UseCasePath.confd1 { Directory "conf.d/${var:Driver}"  File "${CardLongName}.conf" }
UseCasePath.confd2 { Directory "conf.d/${var:Driver}"  File "${var:Driver}.conf" }
```

So with the stock Arch/upstream `ucm.conf` **only these two paths are live**:

```
/usr/share/alsa/ucm2/conf.d/<CardDriver>/<CardLongName>.conf
/usr/share/alsa/ucm2/conf.d/<CardDriver>/<CardDriver>.conf
```

which is exactly `conf.d/sm8150_raphael/xiaomi-XiaomiRedmiK20Pro.conf` and
`conf.d/sm8150_raphael/sm8150_raphael.conf`. The `Raphael/Raphael.conf` + `HiFi.conf` pair belongs to
the **obsolete** `ucm2/${CardDriver}/${CardDriver}.conf` path, which `Define.V2Name ""` turns off —
so it is inert in this version. Copy it anyway (it is 2 files, it costs nothing, and it is what the
Debian package ships), but do not rely on it.

### 9.3 Conflict with Arch's own `alsa-ucm-conf`? — **No conflict.**

Verified by searching the **complete** `alsa-ucm-conf-1.2.16.1-1` package file list and the extracted
tree: there is **no** `Raphael/`, **no** `conf.d/sm8150_raphael/`, **no** file matching
`*raphael*`, `*sm8150*` or `*xiaomi*` anywhere in the package. The package's own Qualcomm content is
`usr/share/alsa/ucm2/Qualcomm/{x1e80100,sm8750,sm8650,sm8550,sm8250,sdm845,sc8280xp,qcm6490,qcs6490,
qcs615,qcs8300,sa8775p,kaanapali,glymur,apq8016-sbc,apq8096}` — **no `sm8150`**.

Two practical consequences:

* Safe to copy the vendor files in **after** installing `alsa-ucm-conf`; nothing is overwritten.
* If a future `alsa-ucm-conf` release ever adds `conf.d/sm8150_raphael/`, an upgrade would silently
  replace your UCM. Guard against it by adding `alsa-ucm-conf` to `IgnorePkg` in `/etc/pacman.conf`
  (or by keeping the vendor files in a separate directory and using `ALSA_CONFIG_UCM2`).
  This is worth doing because this device will never be supported upstream.

### 9.4 The WirePlumber config — **the file format changed in 0.5, the Debian file is wrong for Arch**

Script 16 writes `/etc/wireplumber/wireplumber.conf.d/51-disable-suspension.conf` in the
**WirePlumber 0.4 Lua-ish `monitor.alsa.rules` syntax**:

```
monitor.alsa.rules = [
  {
    matches = [ { node.name = "~alsa_input.*" }, { node.name = "~alsa_output.*" } ]
    actions = { update-props = { audio.format = "S16LE" ... } }
  }
]
```

ALARM ships **`wireplumber-0.5.17-2`**. WirePlumber 0.5 replaced the standalone Lua configuration with
a **SPA-JSON component system**; the correct path and syntax are:

* Directory: `$ROOT/etc/wireplumber/wireplumber.conf.d/` — **this path is still correct in 0.5**
  (the drop-in dir is unchanged). The file must be named `*.conf` and contain a **SPA-JSON object**
  with one or more `monitor.alsa.rules` sections.
* 0.5 also accepts the legacy `/etc/wireplumber/` compatibility drop-ins, but the rewrite below is the
  supported form.

`$ROOT/etc/wireplumber/wireplumber.conf.d/51-raphael-alsa.conf` (**SPA-JSON**, *not* strict JSON — see note):

```spa-json
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_input.*"
      }
      {
        node.name = "~alsa_output.*"
      }
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
```

> **Do not try to validate this file with a JSON parser.** WirePlumber/PipeWire use **SPA-JSON**, a
> superset of JSON that allows bare (unquoted) keys, `=` in place of `:` as the key/value separator, and
> `#` comments. `python3 -m json.tool` / `jq` will reject it, and that is expected — it is valid
> SPA-JSON and WirePlumber parses it. Validate the *syntax categories that matter* (no trailing commas,
> balanced braces) by checking the WirePlumber journal after a restart instead.

Differences from the Debian file, and why:

| Debian (script 16) | Arch fix | Why |
|:--|:--|:--|
| `api.alsa.headroom = 512,` (trailing comma) | `api.alsa.headroom = 512` | trailing commas are a syntax error in strict SPA-JSON parsing; WirePlumber 0.5 rejects the whole drop-in. The Debian file gets away with it because 0.4's parser was lenient. |
| Lua-style comments `# …` | removed | `#` is not a JSON comment; WirePlumber 0.5 will refuse to parse the file. Keep the *content* (the commented-out `session.suspend-timeout-seconds = 0` and the dither options) as a separate note, not inside the JSON. |
| file named `51-disable-suspension.conf` in 0.4 syntax | renamed `51-raphael-alsa.conf` | cosmetic, but makes it obvious this is a rewritten drop-in, not the 0.4 one. |
| `session.suspend-timeout-seconds = 0` commented out | **leave it out**, or add `session.suspend-timeout-seconds = 0` as a real property if you actually want suspension disabled | in 0.5 this belongs in the `wireplumber.settings` / `sm-settings` sections, not in an ALSA rule. |

Verify on device:

```sh
wpctl status
systemctl --user status wireplumber
journalctl --user -u wireplumber | grep -i '51-raphael\|parse'
```

If WirePlumber logs a parse error for your drop-in it silently ignores the whole file — which is the
failure mode you are most likely to hit.

**Exact unit names — all VALIDATED from the ALARM `files` databases:**

| Package | User units shipped |
|:--|:--|
| `pipewire-1:1.6.9-1` | `usr/lib/systemd/user/pipewire.service`, `…/pipewire.socket`, `…/filter-chain.service` |
| `pipewire-pulse-1:1.6.9-1` | `usr/lib/systemd/user/pipewire-pulse.service`, `…/pipewire-pulse.socket` |
| `wireplumber-0.5.17-2` | `usr/lib/systemd/user/wireplumber.service`, `…/wireplumber@.service` |
| `systemd-262-1` | `usr/lib/systemd/user/graphical-session.target` |

Enable by **creating the symlinks offline** (the reliable approach in a chroot — `systemctl --user
enable` needs a live user manager):

```sh
install -d "$ROOT/etc/systemd/user/graphical-session.target.wants"
for u in pipewire.service pipewire-pulse.service wireplumber.service; do
    ln -sf "/usr/lib/systemd/user/$u" \
           "$ROOT/etc/systemd/user/graphical-session.target.wants/$u"
done
```

Socket activation is also available (`pipewire.socket`, `pipewire-pulse.socket`) if you prefer not to
hard-enable the services; the sockets must then be enabled into `sockets.target.wants` instead.
⚠ The `[Install]` sections of these packaged units are still **UNVERIFIED** (I validated the unit file
*names*, not their `WantedBy=` lines), so on KDE double-check that `graphical-session.target` is the
right anchor for your session — `plasma-workspace.target` is the alternative used in §7.5.

### 9.5 Codec kernel side

`CONFIG_SND_SOC_WCD934X=m`, `CONFIG_SND_SOC_WCD_MBHC=m`, `CONFIG_SND_SOC_TFA9872=m`,
`CONFIG_SND_SOC_QDSP6_*=m`, `CONFIG_SND_SOC_QCOM=m`, `CONFIG_QCOM_Q6V5_ADSP=m`,
`CONFIG_QCOM_Q6V5_PAS=m`, `CONFIG_QCOM_PIL_INFO=m` (**all VALIDATED** from the vendor config). These
are **modules**, so they must land in the initramfs only if you need audio before the rootfs is up —
you do not. Make sure the audio daemons `usr/share/qcom/dsp/adsp/*` are present (§11) or the ADSP will
fail to come up and the card will never appear.

---

## 10. Kernel package layout: Debian deb → Arch rootfs

### 10.1 What the deb actually contains (**VALIDATED** by listing `_recon/dl/x-image/`)

```
boot/vmlinuz-7.2.0-sm8150-g29662fdcefa9          13 750 784 B   (EFI-stub kernel)
boot/System.map-7.2.0-sm8150-g29662fdcefa9        7 206 302 B
boot/config-7.2.0-sm8150-g29662fdcefa9              253 295 B
boot/dtbs/qcom/*.dtb                           11 DTBs, incl. sm8150-xiaomi-raphael.dtb
lib/modules/7.2.0-sm8150-g29662fdcefa9/        957 modules + modules.{alias,dep,builtin,…}[.bin]
usr/lib/linux-image-7.2.0-sm8150-g29662fdcefa9/  full dtbs_install tree (all vendors)
usr/share/doc/linux-image-7.2.0-…/              changelog + copyright
```

Debian `postinst` runs `run-parts` over `/etc/kernel/postinst.d` and `/usr/share/kernel/postinst.d` —
**this does nothing on Arch**; there is no kernel hook mechanism. `mkinitcpio` is triggered by pacman
hooks (`90-mkinitcpio-install.hook`, **VALIDATED** in `mkinitcpio-42.1-1`), which also will not fire
because this kernel is not installed by pacman. **You must run `mkinitcpio` explicitly.**

### 10.2 Destination table

| Debian deb path | Arch destination | Which filesystem | Notes |
|:--|:--|:--|:--|
| `/boot/vmlinuz-<ver>` | `$ROOT/usr/lib/modules/<ver>/vmlinuz` **and** a copy at `$ROOT/boot/vmlinuz-linux-raphael` | ext4 (canonical) + **FAT** (needed by sd-boot) | Arch's convention keeps the kernel under `/usr/lib/modules/<ver>/`; systemd-boot needs a file it can `ReadFile()` from the ESP, so a copy must also exist at `/boot`. `/boot` is the FAT partition, mounted at runtime. |
| `/boot/initrd.img-<ver>` | `$ROOT/boot/initramfs-linux-raphael.img` (generated by `mkinitcpio -g`) | **FAT** | never ship a pre-generated Debian initrd; the Arch initrd must be built by `mkinitcpio` with the `systemd` hook so `PARTLABEL=` resolution works. |
| `/boot/System.map-<ver>` | `$ROOT/usr/lib/modules/<ver>/System.map` | ext4 | not needed for booting; keep for `crash`/`perf`/debugging. **Do not** put it on the FAT partition. |
| `/boot/config-<ver>` | `$ROOT/usr/lib/modules/<ver>/config` | ext4 | same. |
| `/boot/dtbs/qcom/sm8150-xiaomi-raphael.dtb` | `$ROOT/boot/dtbs/qcom/sm8150-xiaomi-raphael.dtb` | **FAT** | U-Boot's standard `fdtfile` lookup path; also usable from sd-boot's `devicetree` key. Keep at least the raphael DTB here. |
| the other 10 DTBs in `boot/dtbs/qcom/` | optional | FAT | ~11 files; keep them if you want to boot the same ESP on `nabu`/`cepheus`/`guacamole`. |
| `/lib/modules/<ver>/…` | `$ROOT/usr/lib/modules/<ver>/…` | ext4 | **`/lib` is a symlink to `usr/lib`** on Arch (VALIDATED via the `filesystem` package). Copy to `usr/lib`. |
| `/usr/lib/linux-image-<ver>/` | **not used on Arch** | — | this is a Debian `make dtbs_install` convention. If you want the full tree, put it at `$ROOT/usr/lib/modules/<ver>/dtbs/` (that is where Arch/ALARM kernels keep DTBs), but nothing reads it for booting. |
| `/usr/share/doc/linux-image-…/` | drop | — | pacman-managed files do not live there. |

The `/lib` → `/usr/lib` mapping is mechanical but a build script that copies `/lib/modules/...`
straight out of the extracted deb into `$ROOT/lib/modules/...` will **fail** if `/lib` is not yet a
symlink at that point in the build (it is created by the `filesystem` package, so it usually is).
Write to `usr/lib` explicitly and never rely on the symlink.

### 10.3 mkinitcpio configuration

`$ROOT/etc/mkinitcpio.d/linux-raphael.preset`:

```ini
ALL_config="/etc/mkinitcpio.conf"
ALL_kver="/boot/vmlinuz-linux-raphael"
PRESETS=('default')
default_image="/boot/initramfs-linux-raphael.img"
```

`$ROOT/etc/mkinitcpio.conf.d/raphael.conf`:

```ini
# Cross-built image: "autodetect" would pick up the BUILD HOST's /sys, which is
# the wrong machine. Do not use it.
HOOKS=(base systemd modconf kms keyboard block filesystems fsck)
MODULES=(qcom_q6v5_pas qcom_q6v5_mss qcom_q6v5_adsp qcom_pil_info qrtr qrtr_smd)
COMPRESSION=(zstd)
```

Rationale, all **VALIDATED**:

* ALARM's stock `/etc/mkinitcpio.conf` has
  `HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block filesystems fsck)`.
  **Remove `autodetect`** — it scans the running system's `/sys` and, in an offline/cross build, adds
  the wrong (host) modules. **`microcode` is x86-only** (the hook is shipped by mkinitcpio itself but
  the `intel-ucode`/`amd-ucode` payloads do not exist for aarch64); harmless but pointless, remove it.
* `CONFIG_EXT4_FS=y`, `CONFIG_DEVTMPFS=y`, `CONFIG_BLK_DEV_SD=y`, `CONFIG_MMC=y`, `CONFIG_MMC_SDHCI=y`
  are all **built in**, so no block/fs module needs to be in the initrd — the `block`/`filesystems`
  hooks are enough and will find nothing extra.
* The `systemd` hook is what makes `root=PARTLABEL=userdata` resolvable (it provides udev +
  `systemd-udevd` in the initrd, which builds `/dev/disk/by-partlabel/`).
  Do **not** swap to the busybox `udev` hook unless you also use `root=UUID=`/`root=/dev/…`.
* `kms` is harmless (`CONFIG_DRM_MSM=y` is built in so nothing gets pulled in).
* The QCOM remoteproc modules are `=m` and will be loaded by udev from the rootfs after the switch —
  they do **not** need to be in `MODULES`. Listing them is a cheap guarantee that they load even if
  the DT `compatible` matching is fragile.

### 10.4 Firmware in the initramfs — the faithful port of the Debian hook

Script 09 installs an initramfs-tools hook that copies four firmware globs:
`/lib/firmware/qcom/a6*`, `…/raphael/a6*`, `…/raphael/ad*`, `…/raphael/cd*`, `…/raphael/ipa*`.
Those are the Adreno GPU zap/`a6xx` blobs, the ADSP/CDSP/modem remoteproc images, and IPA.

**mkinitcpio's `FILES=()` does NOT glob-expand.** Verified in the shipped `mkinitcpio-42.1-1`:
`/usr/lib/initcpio/functions:1161` is `map add_file "${FILES[@]}"` — quoted, no globbing — and the
`add_file` helper does `install -Dm… "$src" "$dst"`. So the Debian globs must be expanded at build
time or replaced by a custom install hook.

**Recommended (faithful, glob-based) — a custom mkinitcpio install hook:**

`$ROOT/etc/initcpio/install/raphael-firmware` (mode 0755; `etc/initcpio/install/` is **VALIDATED**
as a scanned directory in `mkinitcpio-42.1-1`):

```sh
#!/usr/bin/env bash
# Port of the Debian initramfs-tools hook /etc/initramfs-tools/hooks/raphael
# (scripts/09-install-kernel.sh). Pulls the GPU / ADSP / CDSP / modem / IPA
# firmware into the initramfs, because CONFIG_DRM_MSM=y probes before the
# root filesystem is mounted.

build() {
    local fw
    for fw in /usr/lib/firmware/qcom/a6* \
              /usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/a6* \
              /usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/ad* \
              /usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/cd* \
              /usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/ipa*; do
        [ -e "$fw" ] || continue
        add_file "$fw"
    done
}

help() {
    cat <<EOF
This hook adds the Xiaomi raphael firmware needed by the built-in (CONFIG_DRM_MSM=y)
display driver and the ADSP/CDSP/modem/IPA remoteprocs to the initramfs.
EOF
}
```

Then add `raphael-firmware` to `HOOKS=()` **after** `modconf`:

```ini
HOOKS=(base systemd modconf raphael-firmware kms keyboard block filesystems fsck)
```

**Alternative (no custom hook)** — expand the globs at build time into `FILES=()`:

```sh
FW_FILES=$(cd "$ROOT" && ls usr/lib/firmware/qcom/a6* \
    usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/{a6,ad,cd,ipa}* 2>/dev/null \
    | sed 's|^usr/|/usr/|' | tr '\n' ' ')
printf 'FILES=(%s)\n' "$FW_FILES" >> "$ROOT/etc/mkinitcpio.conf.d/raphael.conf"
```

> Should you include firmware at all? Strictly, the initrd only needs to mount the ext4 root. But
> `CONFIG_DRM_MSM=y` is **built in**, so the display driver probes during kernel init — before the
> rootfs is mounted — and requests `qcom/a630_sqe.fw` / `qcom/a640_gmu.bin` and
> `qcom/sm8150/Xiaomi/raphael/a640_zap.mbn`. Without them the probe defers; modern kernels retry after
> the rootfs is up, so it usually recovers, but the Debian maintainers chose to ship them in the initrd
> and you should keep that behaviour to avoid a black screen if the retry ever regresses.

Build:

```sh
chroot "$ROOT" mkinitcpio -P
```

⚠ `mkinitcpio -P` uses the presets in `/etc/mkinitcpio.d/`. Because the vendor kernel is **not**
pacman-managed, nothing regenerates the initrd automatically after a kernel update — the Arch port of
the "one-click kernel update" script must call `mkinitcpio -P` itself.

### 10.5 Filenames the bootloader needs, and the `linux.efi`/`initramfs` question

Script 17 renames the Debian kernel files to the names the prebuilt U-Boot image expects:

```
/boot/vmlinuz-*    -> /boot/linux.efi     (EFI-stub kernel)
/boot/initrd.img-* -> /boot/initramfs     (initrd)
```

The README's flashing procedure (`fastboot flash cache xiaomi-k20pro-boot.img`,
`fastboot flash boot u-boot.img`) means the **`cache` partition already contains a FAT image with
U-Boot's expected layout**, and `xiaomi-k20pro-boot.img` is loop-mounted at `rootdir/boot` in script 02.
The vendor config has `CONFIG_EFI_STUB=y` + `CONFIG_EFI_GENERIC_STUB=y` (**VALIDATED**), so
`vmlinuz-<ver>` *is* a valid EFI application and can be loaded by U-Boot's EFI boot path directly.

**Two supported layouts — pick one and be consistent:**

**(A) systemd-boot (what this port targets).** Files on the **FAT** `/boot`:

```
/boot/EFI/systemd/systemd-bootaa64.efi     <- from /usr/lib/systemd/boot/efi/systemd-bootaa64.efi
/boot/EFI/BOOT/BOOTAA64.EFI                <- same file, lenient fallback path
/boot/vmlinuz-linux-raphael
/boot/initramfs-linux-raphael.img
/boot/dtbs/qcom/sm8150-xiaomi-raphael.dtb
/boot/loader/loader.conf
/boot/loader/entries/arch.conf
```

* **VALIDATED**: `systemd-262-1` ships `usr/lib/systemd/boot/efi/systemd-bootaa64.efi` — the
  **aarch64** build (`…aa64.efi`, *not* `…x64.efi`), plus `usr/bin/bootctl`,
  `usr/share/systemd/bootctl/{arch.conf,loader.conf,splash-arch.bmp}` and
  `usr/lib/systemd/system/systemd-boot-update.service`.
* Install it with `bootctl --path="$ROOT/boot" install` (needs `efibootmgr-18-4` only for the NVRAM
  entry; on this device U-Boot EFI does the loading, so `--no-variables` is the safer form).
* `/boot/boot` must be a real vfat filesystem for `bootctl`; on the build host that means loop-mounting
  the FAT image, which needs `dosfstools-4.2-5` (VALIDATED (pkg)).

`$ROOT/boot/loader/loader.conf`:

```
default arch.conf
timeout 3
console-mode max
editor no
```

`$ROOT/boot/loader/entries/arch.conf` — note `devicetree`, which systemd-boot supports on ARM64
(**UNVERIFIED** for `systemd-bootaa64.efi` in 262; if the entry fails to boot, delete the
`devicetree` line — U-Boot will already have installed the DT the kernel uses):

```
title   Arch Linux ARM (Xiaomi Redmi K20 Pro)
linux   /vmlinuz-linux-raphael
initrd  /initramfs-linux-raphael.img
devicetree /dtbs/qcom/sm8150-xiaomi-raphael.dtb
options root=PARTLABEL=userdata rw rootwait console=tty0 quiet
```

**Files that belong on the ext4 root, NOT on the FAT `/boot`:**

* everything under `/usr/lib/modules/<ver>/` (modules, `modules.alias`, `System.map`, `config`)
* the full `/usr/lib/modules/<ver>/dtbs/` tree, if you keep it
* `/etc/mkinitcpio.conf*`, `/etc/mkinitcpio.d/*.preset`
* the UCM, firmware, and everything else in this document

**(B) U-Boot legacy filenames (what the existing `cache` image expects).** If you keep using the
prebuilt `xiaomi-k20pro-boot.img` unchanged, you must still produce `/boot/linux.efi` and
`/boot/initramfs`:

```sh
cp "$ROOT/boot/vmlinuz-linux-raphael"          "$ROOT/boot/linux.efi"
cp "$ROOT/boot/initramfs-linux-raphael.img"    "$ROOT/boot/initramfs"
```

and you do **not** need systemd-boot at all. The cmdline then comes from U-Boot's `bootargs`
(`root=PARTLABEL=userdata`), matching script 18's comment. Do not ship both layouts on the same ESP
with the same filenames; it just wastes space. Pick one.

---

## 11. Firmware package

### 11.1 What it contains (**VALIDATED** by listing `_recon/dl/x-fw/`)

513 files, 200 MB. Only **five** are zstd-compressed:

```
usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin.zst
usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin.zst
usr/lib/firmware/ath10k/WCN3990/hw1.0/notice.txt_wlanmdsp.zst
usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn.zst
usr/lib/firmware/qca/crnv21.bin.zst
```

Everything else is uncompressed: `usr/lib/firmware/qcom/` (210 files, 111 MB — `a630_sqe.fw`,
`a640_gmu.bin`, and `qcom/sm8150/Xiaomi/raphael/` with `a640_zap.mbn`, `adsp.mbn`, `adspr.jsn`,
`adsps.jsn`, `adspua.jsn`, `cdsp.mbn`, `cdspr.jsn`, `ipa_fws.mbn`, `ipa_uc.mbn`, `modem.mbn` and the
whole `modem_pr/mcfg/configs/**` tree of 198 `mcfg_*.mbn`), plus `usr/share/qcom/` (295 files, 32 MB —
`acdb/Forte/*.acdb`, `acdb/adsp_avs_config.acdb`, `dsp/adsp/*` (the ADSP sidecar `.so.1` modules and
`fastrpc_shell_0`), `sensors/*`, `socinfo/*`).

### 11.2 Destination paths on Arch

| Source in the deb | Arch destination | Why |
|:--|:--|:--|
| `usr/lib/firmware/**` | `$ROOT/usr/lib/firmware/**` | identical. `/lib/firmware/...` (the path the kernel asks for) resolves here because `/lib` → `usr/lib` (VALIDATED). **Write to `usr/lib`, not `lib`.** |
| `usr/share/qcom/**` | `$ROOT/usr/share/qcom/**` | identical. This is a **userspace** data path, not a kernel path — the kernel never reads it. Nothing in ALARM `core`+`extra` ships `/usr/share/qcom/` (**VALIDATED**: no package's `files` list contains `usr/share/qcom/`), so there is no conflict and you keep the vendor layout. |

`/usr/share/qcom/` is consumed by the FastRPC/"reverse tunnel" userspace daemon
(`hexagonrpcd`/`adsprpcd`): the ADSP `dlopen()`s `dsp/adsp/*.so.1` and requests the ACDB blobs, and the
daemon serves them from a root directory. ⚠ **UNVERIFIED**: I could not confirm from the local
material which daemon the parent intends to run, so verify the daemon's `--root`/`-r` argument matches
`/usr/share/qcom` when you build it (see §12.5). If you use a daemon that expects a different root,
either symlink or pass the argument — do **not** move the files.

### 11.3 ⚠ Real conflict with ALARM's `linux-firmware` — must be handled

**VALIDATED** from the ALARM `files` databases:

* `linux-firmware-atheros-20260916-1` (core) ships **uncompressed**
  ```
  usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
  usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin
  usr/lib/firmware/ath10k/WCN3990/hw1.0/notice.txt_wlanmdsp
  usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn
  ```
  at the **same logical names** as the vendor `.zst` files.
* `linux-firmware-qcom-20260916-1` (core) ships
  ```
  usr/lib/firmware/qcom/a630_gmu.bin
  usr/lib/firmware/qcom/a630_sqe.fw
  usr/lib/firmware/qcom/a640_gmu.bin
  usr/lib/firmware/qcom/sm8150/a640_zap.mbn
  ```
  — three of those are **byte-path-identical** to the vendor package's `usr/lib/firmware/qcom/a630_sqe.fw`
  and `usr/lib/firmware/qcom/a640_gmu.bin`, i.e. a hard file-level conflict.
* Nothing in ALARM ships `qcom/sm8150/Xiaomi/raphael/**` or `qca/crnv21.bin`, so the modem/ADSP
  firmware and the WLAN `crnv21.bin` are safe.

**The trap:** the kernel's firmware loader tries the **unsuffixed** filename first
(`fw_get_filesystem_firmware()` walks the search paths and, for each, tries `""`, then `.xz`, then
`.zst`). With both packages installed you get `board-2.bin` (upstream, generic) **and**
`board-2.bin.zst` (vendor, device-specific) — and the **upstream one wins**, because `board-2.bin`
exists. Same for `a630_sqe.fw`/`a640_gmu.bin`, where the two packages ship genuinely different bytes.

**Fix (choose one):**

1. **Do not install `linux-firmware` at all** in this image. It is only an *optdepends* of
   `linux-aarch64` (`linux-aarch64-7.2.8-1` `%OPTDEPENDS%` lists `linux-firmware: firmware images
   needed for some devices`), so nothing pulls it in automatically. You are not using
   `linux-aarch64` anyway. **Recommended.**
2. If something forces `linux-firmware` in, install only the sub-packages you need and then delete the
   colliding plain files after the vendor firmware is in place:
   ```sh
   rm -f "$ROOT/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin" \
         "$ROOT/usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin" \
         "$ROOT/usr/lib/firmware/ath10k/WCN3990/hw1.0/notice.txt_wlanmdsp" \
         "$ROOT/usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn" \
         "$ROOT/usr/lib/firmware/qcom/a630_sqe.fw" \
         "$ROOT/usr/lib/firmware/qcom/a630_gmu.bin" \
         "$ROOT/usr/lib/firmware/qcom/a640_gmu.bin"
   ```
   and add the packages to `IgnorePkg` so a `pacman -Syu` cannot reintroduce them.
3. Or install the vendor firmware **after** every pacman transaction (a pacman hook), which is fragile.
   Prefer 1 or 2.

Also: pacman will refuse to install the vendor files "over" a package's files unless you use
`--overwrite`. Since you are writing files directly (not with pacman), this only matters if
linux-firmware is installed *afterwards* — order the build so the vendor firmware is copied last.

### 11.4 Do the `.zst` files have to be decompressed? — **No. Definitively no.**

**VALIDATED** from `_recon/dl/x-image/boot/config-7.2.0-sm8150-g29662fdcefa9`:

```
CONFIG_FW_LOADER=y
CONFIG_FW_LOADER_PAGED_BUF=y
CONFIG_FW_LOADER_SYSFS=y
# CONFIG_FW_LOADER_USER_HELPER is not set
CONFIG_FW_LOADER_COMPRESS=y
CONFIG_FW_LOADER_COMPRESS_XZ=y
CONFIG_FW_LOADER_COMPRESS_ZSTD=y
CONFIG_ZSTD_DECOMPRESS=y
CONFIG_DECOMPRESS_ZSTD=y
CONFIG_RD_ZSTD=y
```

`CONFIG_FW_LOADER_COMPRESS_ZSTD=y` means the *direct* firmware loader (`request_firmware()` →
`fw_get_filesystem_firmware()`) transparently decompresses `<name>.zst` in the kernel when userspace
asks for `<name>`. `CONFIG_FW_LOADER_USER_HELPER` is **off**, so there is no udev fallback path that
could behave differently — everything goes through the same in-kernel decompressor.

**Therefore: copy the `.zst` files verbatim to `$ROOT/usr/lib/firmware/…`. Do NOT decompress them,
and do NOT ship both the compressed and uncompressed forms** (the plain name wins and you lose the
zstd version). Decompressing is a pure waste of ~20 MB of rootfs and, worse, reintroduces exactly the
"plain name shadows the compressed one" hazard described in §11.3.

Also note `CONFIG_MODULE_COMPRESS` is **not set** (`# CONFIG_MODULE_COMPRESS is not set`) — so the
kernel modules are **uncompressed `.ko`**, which is what `depmod`/`modprobe` expect by default. If you
ever swap kernels, check this: a kernel built with `CONFIG_MODULE_COMPRESS_ZSTD=y` needs
`/etc/modprobe.d/` handling or `depmod` support, and Arch's `kmod` handles both, but the preset differs.

`CONFIG_MODULE_SIG` is **not set** — no module signature enforcement, so the vendor modules load fine.

### 11.5 Copy snippet

```sh
# $FW  = extracted firmware deb root (…/x-fw)
install -d "$ROOT/usr/lib/firmware" "$ROOT/usr/share/qcom"
cp -a "$FW/usr/lib/firmware/." "$ROOT/usr/lib/firmware/"
cp -a "$FW/usr/share/qcom/."   "$ROOT/usr/share/qcom/"
# preserve the .zst files exactly as shipped
find "$ROOT/usr/lib/firmware" -name '*.zst' -printf '%p\n'
```

---

## 12. Everything else the scripts do

### 12.1 Hostname, hosts, DNS (script 04)

`$ROOT/etc/hostname`:

```
xiaomi-raphael
```

`$ROOT/etc/hosts`:

```
127.0.0.1 localhost
127.0.1.1 xiaomi-raphael
```

`$ROOT/etc/resolv.conf` — ⚠ **do not ship this on Arch the way Debian does.** Script 04 writes a
static `nameserver 1.1.1.1`. On Arch, `systemd-resolved` is *not* enabled by default and
`networkmanager` writes `/etc/resolv.conf` itself, but:
* if `/etc/resolv.conf` is a **regular file**, NetworkManager leaves it alone on some configurations;
* `systemd-resolvconf-262-1` (core, VALIDATED) exists and provides the `resolvconf` shim if you enable
  `systemd-resolved`.

Safest for this image: write the file with a comment header and let NM manage it, or make it a
symlink to the NM-managed path:

```sh
printf 'nameserver 1.1.1.1\nnameserver 223.5.5.5\n' > "$ROOT/etc/resolv.conf"
```

(`223.5.5.5` = AliDNS, for the China-first mirror setup; optional.) Because the USB-NCM `dnsmasq`
runs with `port=0`, it does **not** interfere with DNS on the device.

### 12.2 Package sources (scripts 05, 06) — apt → pacman

* **VALIDATED by construction**: `/tmp/alarm-core.db` is byte-identical to the tuna mirror's
  `core.db`, so the tuna ALARM mirror is a working, current source. Write
  `$ROOT/etc/pacman.d/mirrorlist` with the tuna ALARM Server line first:

  ```
  Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
  ```

  (ALARM's `$arch` is `aarch64`; the `mirrorlist` placeholder syntax is the same as Arch's.)
* `apt-get update && apt-get upgrade -y` → `pacman -Syu --noconfirm`.
* `apt-get install -y $ALL_PACKAGES` → `pacman -S --noconfirm --needed $ALL_PACKAGES`.
* `apt-get clean` (script 17) → `pacman -Scc --noconfirm` **or** just `rm -rf "$ROOT/var/cache/pacman/pkg/*"`.
  (`pacman -Scc` also wipes the sync dbs; use `rm -rf` for a reproducible image.)
* `DEBIAN_FRONTEND=noninteractive` → `--noconfirm` / `--assume-installed`; there is no env var.
* `dpkg -i` for the vendor kernel/firmware/ALSA debs → **extract, do not install**: pacman has no
  `-i` for a foreign `.deb`. Use `dpkg-deb -x` (or `ar x` + `tar`) and copy the trees as in §10/§11,
  then run `depmod` and `mkinitcpio` yourself.
* `apt-utils` has no equivalent (no package-manager helper layer needed).
* `apt-get update` inside the chroot requires network + DNS. For a hermetic build, prefer
  `pacstrap`/`pacman -r "$ROOT"` with `--cachedir` and a pre-populated package cache.

### 12.3 Screen commands + auto-blank (script 08)

`setterm` comes from `util-linux-2.42.4-1` — **VALIDATED** at `usr/bin/setterm`, and `util-linux` is in
`base`. So the `leijun`/`jinfan` functions work unchanged. On Arch, `/etc/bash.bashrc` exists — it is
shipped by `bash-5.3.20-1` (**VALIDATED**) — and is sourced by bash for interactive non-login shells
(the Arch equivalent of Debian's). Append verbatim:

```sh
cat >> "$ROOT/etc/bash.bashrc" <<'EOF'

# 屏幕管理命令
leijun() {
    if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
        sudo sh -c 'TERM=linux setterm --blank force </dev/tty1'
    else
        setterm --blank force --term linux </dev/tty1
    fi
    echo "屏幕已关闭"
}

jinfan() {
    if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
        sudo sh -c 'TERM=linux setterm --blank poke </dev/tty1'
    else
        setterm --blank poke --term linux </dev/tty1
    fi
    echo "屏幕已开启"
}
EOF
```

⚠ **Arch-specific caveat**: `leijun`/`jinfan` use `setterm` against `/dev/tty1`, i.e. the **kernel
VT**. If the image runs a KDE *Wayland* session, the visible output is on the compositor, not on
`/dev/tty1`, so these commands will not blank the panel. They are still correct for the server variant
and for a bare-VT console. For KDE, use the §7.4 `kscreen-doctor --dpms` mechanism instead, and
document `leijun`/`jinfan` as server-only.

`$ROOT/etc/systemd/system/blank_screen.service` — Debian's unit works on Arch verbatim, but it uses
`/bin/bash` (a symlink on Arch, fine) and `ExecStartPre=/usr/bin/sleep` (present on Arch). The only
Arch-ism worth fixing is `After=multi-user.target` combined with `WantedBy=multi-user.target`
(a unit ordering itself after its own target is odd; it works but is fragile). Cleaned-up version:

```ini
[Unit]
Description=Auto-blank screen after 15s
After=multi-user.target getty@tty1.service
Wants=getty@tty1.service

[Service]
Type=oneshot
ExecStartPre=/usr/bin/sleep 15
ExecStart=/bin/sh -c 'TERM=linux setterm --blank force </dev/tty1'
RemainAfterExit=yes
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

```sh
chroot "$ROOT" systemctl enable blank_screen.service
```

### 12.4 Script 09's other job — `initramfs-tools` hook registration

Already covered in §10.4. Note the Debian hook directory `/etc/initramfs-tools/hooks/` has **no** Arch
counterpart; the Arch equivalent is `/etc/initcpio/install/` (VALIDATED as a real, scanned directory in
`mkinitcpio-42.1-1`) — the `mkinitcpio` package ships `etc/initcpio/install/` in addition to
`usr/lib/initcpio/install/`, so local hooks belong in `/etc/initcpio/install/`.

### 12.5 ✗ The three Qualcomm userspace daemons — no Arch equivalent

**VALIDATED**: searching every `files` list in `core.files` + `extra.files` (13 256 packages) for
`rmtfs`, `pd-mapper`, `tqftpserv`, `protection-domain-mapper`, `q6voiced`, `hexagonrpcd`,
`usr/bin/rmtfs`, `usr/lib/systemd/system/rmtfs.service`, `usr/lib/systemd/system/pd-mapper.service`,
`usr/lib/systemd/system/tqftpserv.service`, `usr/share/qcom/` returns **zero** hits.

These are the pieces from the qcom-mainline `linux-msm` project. There is also no AUR for ALARM by
default, so you must **build them from source**:

| Daemon | Upstream | What it does on this device | Build notes |
|:--|:--|:--|:--|
| `rmtfs` | `github.com/linux-msm/rmtfs` | Serves the modem's shared-memory/EFS (`modem_pr`) partition to the MSS remoteproc over QMI (`qmi_rmtfs`). Without it `modem.mbn` fails to boot. Repo also contains `rmtfs.rules` (udev) and `rmtfs-dir.service.in`. | Plain C + `libqrtr`/`libqmi`; `libqrtr-glib-1.4.0-1` and `libqmi-1.38.0-1` **are** in extra (VALIDATED (pkg)), but upstream `rmtfs` vendors its own `qmi_rmtfs.c`, so it needs no external libqmi. Cross-compile with `make CROSS_COMPILE=aarch64-linux-gnu-`. |
| `tqftpserv` | `github.com/linux-msm/tqftpserv` | TFTP-over-QRTR server that feeds the ADSP/CDSP firmware images from `/lib/firmware/qcom/...` to the remoteprocs. Without it ADSP/CDSP never come up → **no audio**. | Plain C, no deps. |
| `pd-mapper` | `github.com/linux-msm/pd-mapper` | Parses `/lib/firmware/qcom/.../*.jsn` (`adspr.jsn`, `adsps.jsn`, `adspua.jsn`, `cdspr.jsn`) and answers the ADSP's protection-domain lookups. Ships `pd-mapper.service.in` with `ExecStart=PD_MAPPER_PATH/pd-mapper`, `Restart=always`, `WantedBy=multi-user.target` — **VALIDATED by fetching the file from upstream master**. | Needs `libxml2` (in core as a dependency of other things; **VALIDATE** before building). The template must be `sed`-substituted: `sed 's|PD_MAPPER_PATH|/usr/bin|' pd-mapper.service.in > pd-mapper.service`. |
| (FastRPC, if you want audio sidecar loading) | `github.com/linux-msm/hexagonrpc` (`hexagonrpcd`) or Qualcomm's `adsprpcd` | Serves `/usr/share/qcom/dsp/adsp/*.so.1` + ACDB to the ADSP. | See §11.2. **UNVERIFIED** which one the parent plans to use. |

**Re script 06's `sed -i '/ConditionKernelVersion/d'`:** upstream `pd-mapper.service.in` on master has
**no `ConditionKernelVersion=` line at all** (VALIDATED by fetching it). Debian's
`protection-domain-mapper` package adds one. So when building from upstream source for Arch there is
**nothing to strip** — the porting action is to *not* carry this `sed` over, and only add it back if you
copy Debian's unit file instead of upstream's.

Estimated build effort: all three are small single-binary C projects; a `PKGBUILD`-less manual
`make && install` in the build script is realistic. This is the single biggest ✗ item in the port.

### 12.6 `regulatory.db` removal (script 17)

Script 17 does `rm -f rootdir/lib/firmware/reg*`. On Arch, `wireless-regdb-2026.09.03-1` (core,
**VALIDATED (pkg)**) installs `/usr/lib/firmware/regulatory.db` and `regulatory.db.p7s` — the **same
filenames**. The vendor kernel has `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y` and
`CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS=y` (**VALIDATED**), i.e. it only accepts a regulatory database
signed with the *kernel's built-in* key. Arch's `wireless-regdb` is signed with the upstream
`sforshee` key, which the vendor kernel does **not** trust → the load fails and you get
`cfg80211: Failed to load regulatory.db` and a world-domain regdb.

Two options, both Arch-valid:

1. **Port the Debian behaviour**: `rm -f "$ROOT/usr/lib/firmware"/regulatory.db*` and never install
   `wireless-regdb`. The device then runs with the world regulatory domain (all channels usable but
   `NO_IR` restrictions are not applied). This is what the Debian image does and what works there.
2. Better: install `wireless-regdb`, then either
   * set `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB` off (you cannot — the kernel is prebuilt), or
   * keep the file and accept the "Failed to load regulatory.db" message (the plain `regulatory.bin`
     legacy format is also not shipped), or
   * load a signed-for-this-kernel regdb yourself (`regdbdump`/`crda` are gone from modern stacks).

**Recommendation: option 1** — port the `rm -f` line and add `wireless-regdb` to `IgnorePkg` so
`pacman -Syu` cannot bring it back. Do **not** copy the Debian `rm` blindly as
`rm -f rootdir/lib/firmware/reg*`: on Arch write it as
`rm -f "$ROOT"/usr/lib/firmware/regulatory.db*`, because `$ROOT/lib` is a symlink and a `rm` through
it behaves differently from a `rm` on the real path (and `reg*` is an overly broad glob).

### 12.7 Script 02/03 — mounts, bind mounts, chroot

| Debian | Arch equivalent |
|:--|:--|
| `truncate -s $IMAGE_SIZE rootfs.img; mkfs.ext4` | identical (`e2fsprogs-1.47.4-1`, VALIDATED (pkg)) |
| `mount -o loop rootfs.img rootdir` | identical |
| `mount -o loop $BOOT_IMG rootdir/boot` | identical, but the prebuilt `xiaomi-k20pro-boot.img` may already have a filesystem; verify with `file`/`blkid` before mounting. If you build your own ESP: `truncate` + `mkfs.vfat -F 32` + `mount -o loop` (`dosfstools-4.2-5`, VALIDATED (pkg)). |
| `mount --bind /dev /dev/pts /proc /sys` | identical; on Arch also bind `/run` if you run `pacman`/`systemctl` inside the chroot |
| `chroot rootdir …` | identical; prefer `systemd-nspawn -D "$ROOT"` or `arch-chroot` semantics so `/etc/resolv.conf`, `/proc`, `/sys`, `/dev` and the pacman keyring are set up correctly. **`pacman-key --init && pacman-key --populate archlinuxarm`** must be run before the first `pacman -S` inside the rootfs (`archlinuxarm-keyring-20240419-2`, VALIDATED). This is Debian's `apt-key`/`debian-archive-keyring` equivalent and has no Debian analogue in the scripts because Debian's bootstrap handles it. |

### 12.8 Script 00 / the "one-click kernel update"

Script 00 downloads three `.deb`s plus `xiaomi-k20pro-boot.img` from GitHub releases. On Arch there is
no `dpkg`, so the update path must be rewritten as:

```sh
# fetch the kernel payload, then (VER = 7.2.0-sm8150-g29662fdcefa9):
VER=7.2.0-sm8150-g29662fdcefa9
install -Dm0644 "vmlinuz-$VER"                 "$ROOT/usr/lib/modules/$VER/vmlinuz"
install -Dm0644 "vmlinuz-$VER"                 "$ROOT/boot/vmlinuz-linux-raphael"
cp -a "lib/modules/$VER"                       "$ROOT/usr/lib/modules/"
cp -a boot/dtbs/qcom/*.dtb                     "$ROOT/boot/dtbs/qcom/"
depmod -b "$ROOT" "$VER"
systemd-nspawn -D "$ROOT" mkinitcpio -P
```

⚠ `mkinitcpio -P` is the **only** thing that regenerates the initrd, and nothing triggers it
automatically for an out-of-tree kernel (the pacman hook only fires for pacman-owned files).
Whatever "Update-kernel" script you ship must call it explicitly, and must copy the new kernel to the
**FAT** `/boot` as well as to `usr/lib/modules/<ver>/`.

Also note the Debian README says cellular is **not** fully supported ("移动正在修复中"), which matches
the firmware tree here (no `mcfg_sw` for China Mobile's `cmcc` commercial profile beyond the generic
ones) — do not promise cellular in the Arch image either.

### 12.9 Script 18 — finalize

| Debian | Arch |
|:--|:--|
| `e2fsck -f -y rootfs.img` | identical |
| `tune2fs -U ee8d3593-… rootfs.img` | identical — or omit and use `PARTLABEL=`/`PARTUUID=` in the loader entry (§4.3) |
| `umount` chain | identical |
| (no 7z packing in the script, the README mentions it) | `7zip-26.02-1` (extra, **VALIDATED (pkg)**) | use it, or `zstd`/`xz` from `base`, to match the release artifacts. |

---

## 13. Summary — items with **no clean Arch Linux ARM equivalent**

These are the things that need the most attention, in rough order of risk. Everything else in this
document is a file copy or a one-line rename.

| # | Item | Why it has no equivalent | Recommended replacement |
|:--|:--|:--|:--|
| **1** | **`zram-tools` / `zramswap.service` / `/etc/default/zramswap`** | Not in ALARM `core` or `extra`. Debian's `ALGO=`/`SIZE=`/`PERCENT=` knob set does not exist. | **`zram-generator-1.2.1-1`** (extra, VALIDATED) + `/etc/systemd/zram-generator.conf` (§8.3). ⚠ It is a **systemd generator** — there is **no `systemctl enable` step**; do not try to port `systemctl enable zramswap`. |
| **2** | **`rmtfs`** | Not in ALARM. Serves the modem's EFS/shared memory; the modem firmware will not boot without it. | Build from `github.com/linux-msm/rmtfs` (§12.5). |
| **3** | **`protection-domain-mapper` (`pd-mapper`)** | Not in ALARM. Without it the ADSP's protection-domain lookups fail. | Build from `github.com/linux-msm/pd-mapper` (§12.5). Upstream's `pd-mapper.service.in` has **no** `ConditionKernelVersion` — do not port script 06's `sed` unless you reuse Debian's unit file. |
| **4** | **`tqftpserv`** | Not in ALARM. Without it ADSP/CDSP firmware never loads → **no audio at all**, and the UCM file is useless. | Build from `github.com/linux-msm/tqftpserv` (§12.5). |
| **5** | **FastRPC reverse-tunnel daemon for `/usr/share/qcom/`** | Nothing in ALARM ships `/usr/share/qcom/` or reads it. | `hexagonrpcd` (`github.com/linux-msm/hexagonrpc`) or Qualcomm `adsprpcd`; **UNVERIFIED** which one is intended. Verify its root argument matches `/usr/share/qcom` (§11.2). |
| **6** | **apt / dpkg themselves** (`apt-utils`, `dpkg -i`, `sources.list.d`, `update-locale`, `locale-gen` as a Debian command) | Arch uses pacman; there is no `dpkg -i` for the vendor `.deb`s. | Extract debs with `dpkg-deb -x`/`ar`+`tar`, copy trees, run `depmod` + `mkinitcpio` by hand (§10, §11.5, §12.2). Replace `update-locale` with `/etc/locale.conf` (§2.2). |
| **7** | **The GNOME power-key daemon** (script 14, 295 lines) | Its session check (`pgrep -x gnome-shell`), its ScreenSaver bus (`org.gnome.ScreenSaver`), its power menu (`org.gnome.SessionManager` / `gnome-session-quit`) and its dconf key are all GNOME-only. On Plasma it **cannot work** — it exits after 120 s and `Restart=always` loops it forever. | **Drop the GNOME parts**; keep the logind drop-in, the udev rule and the linger file verbatim; use the §7.5 KDE port (freedesktop ScreenSaver + `systemctl poweroff` + bus-name readiness check + `plasma-workspace.target`). See §7.6 for the no-daemon alternative. |
| **8** | **`/etc/default/zramswap`, `sleep.target` masking on a phone**, and the rest of the Debian-specific *paths* under `/etc/default/` | Debian's `/etc/default/<pkg>` convention is not used by Arch packages. | Nothing to do — just do not create `/etc/default/*` files. Arch package config lives in `/etc/systemd/*.conf.d/`, `/etc/<pkg>/conf.d/`, or the package's own `/etc` file. |
| **9** | **ALARM's own `linux-firmware-*` vs the vendor firmware** | Not "missing", but a **hard conflict**: `linux-firmware-atheros-20260916-1` and `linux-firmware-qcom-20260916-1` ship files at the same paths/logical names as the vendor package, and the kernel prefers the unsuffixed upstream file over the vendor `.zst`. | Do **not** install `linux-firmware`; or delete the colliding plain files and `IgnorePkg` them (§11.3). |
| **10** | **The vendor kernel's initramfs hook** | `/etc/initramfs-tools/hooks/` does not exist on Arch, and `mkinitcpio`'s `FILES=()` does **not** glob-expand (VALIDATED: `/usr/lib/initcpio/functions:1161`). | Custom `/etc/initcpio/install/raphael-firmware` hook, or build-time glob expansion into `FILES=()` (§10.4). |
| **11** | **`autodetect` in mkinitcpio's stock `HOOKS`** | Not "missing" — actively **wrong** for a cross-built image: it scans the build host's `/sys`. | Remove `autodetect` (and the x86-only `microcode`) from `HOOKS` (§10.3). |
| **12** | **`netplan`** (script 13, Ubuntu only) | Does not exist on Arch. | Drop it. NetworkManager on Arch is the renderer with no extra config (§6.1). |
| **13** | **`sudo` group** | Arch's `/etc/sudoers` grants nothing by default (`%wheel` and `%sudo` both commented out; only `@includedir /etc/sudoers.d` is active — VALIDATED by reading the shipped file). | Write `/etc/sudoers.d/10-wheel` and put the user in **`wheel`**, not `sudo` (§5.2). |
| **14** | **`/etc/dnsmasq.d/` being read by default** | Arch's `dnsmasq-2.93-1` ships **no** `/etc/dnsmasq.d/` and its `/etc/dnsmasq.conf` has `conf-dir=/etc/dnsmasq.d/,*.conf` **commented out** (VALIDATED). | `install -d /etc/dnsmasq.d` **and** append the `conf-dir=` line to `/etc/dnsmasq.conf` (§3.3). |
| **15** | **The WirePlumber 0.4-format config** (script 16) | ALARM ships `wireplumber-0.5.17-2`; the 0.4 Lua-ish `monitor.alsa.rules` file contains a **trailing comma** and `#` comments, both of which 0.5's strict parser rejects — the whole drop-in is then silently ignored. | Use the 0.5 SPA-JSON form in §9.4, at the same path `/etc/wireplumber/wireplumber.conf.d/`. |
| **16** | **`wireless-regdb` vs the vendor kernel's signed-regdb requirement** | The vendor kernel has `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y`; ALARM's `wireless-regdb` is signed with a key the kernel does not trust, so it fails to load. | Port script 17's `rm -f` for `regulatory.db*` and `IgnorePkg wireless-regdb` (§12.6). |
| **17** | **Prebuilt `xiaomi-k20pro-boot.img` / U-Boot's `linux.efi`+`initramfs` names** | The names are a Debian-script artifact; systemd-boot uses `loader/entries/*.conf`. | Pick layout (A) systemd-boot or (B) U-Boot legacy filenames — do not mix (§10.5). |
| **18** | **`/etc/machine-id` being non-empty at first boot** | Arch ships it **empty**; Debian populates it during bootstrap. The USB gadget's serial number depends on it. | `chroot "$ROOT" systemd-machine-id-setup` at build time (§3.4). |

**Everything else** in the 19 scripts maps 1:1: mask sleep targets, NetworkManager wifi powersave, the
fstab (including `x-systemd.growfs`), the ALSA UCM files (no conflict with `alsa-ucm-conf`), the
Chinese locale/timezone/fonts, the `leijun`/`jinfan` shell functions, the `blank_screen.service`, the
`ath10k` `skip_otp=y` modprobe option, the udev rule, the lingering file, and the `e2fsck`/`tune2fs`
finalize step.
