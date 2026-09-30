# Qualcomm userspace daemons for mainline Snapdragon 855 — Xiaomi Redmi K20 Pro (`raphael`)

Target: **Arch Linux ARM aarch64** on Xiaomi Redmi K20 Pro (`raphael`, SM8150).
Reference image that works: the Debian/Ubuntu sibling project at
<https://github.com/Winter21c/linux-xiaomi-raphael-uboot>, which installs exactly
`rmtfs`, `protection-domain-mapper`, `tqftpserv`
(see `_recon/upstream-scripts/scripts/06-install-all-packages.sh`, line
`DEVICE_PACKAGES="rmtfs protection-domain-mapper tqftpserv"`).

All ALARM package names below were verified against `/tmp/alarm-core.db` and
`/tmp/alarm-extra.db` (313 core + 12 943 extra packages). Nothing in this
document invents a package name.

---

## 0. Ground truth extracted from the device artefacts

These were read directly out of `_recon/dl/x-image/` (the kernel the sibling
project ships) and are the basis for every "which daemon" claim below.

### 0.1 Kernel configuration (`boot/config-7.2.0-sm8150-g29662fdcefa9`)

| Symbol | Value | Consequence |
|---|---|---|
| `CONFIG_QRTR` | `=m` | QRTR is a **module** → `modprobe qrtr` needed (udev autoloads on first AF_QIPCRTR socket) |
| `CONFIG_QRTR_SMD` | `=m` | QRTR over SMD (the transport used for ADSP/CDSP/MPSS on this SoC) |
| `CONFIG_QRTR_MHI` / `CONFIG_QRTR_TUN` | `=m` | not needed on this device |
| `CONFIG_QCOM_RMTFS_MEM` | `=y` | **built-in** → `/dev/qcom_rmtfs_mem*` always appears |
| `CONFIG_QCOM_Q6V5_PAS` | `=m` | ADSP / CDSP / MPSS / SLPI remoteprocs |
| `CONFIG_QCOM_FASTRPC` | `=m` | creates `/dev/fastrpc-*` |
| `CONFIG_QCOM_PD_MAPPER` | `=m` | **in-kernel** PD mapper — see §0.3 |
| `CONFIG_ATH10K_SNOC` | `=m` | WCN3990 Wi-Fi |
| `CONFIG_BT_QCOMSMD` / `CONFIG_BT_HCIUART` | `=m` | Bluetooth |
| `CONFIG_SND_SOC_QDSP6_*` | `=m` | ADSP audio (q6afe/q6asm/q6adm/q6apm/q6routing/q6core) |

### 0.2 Device tree (`sm8150-xiaomi-raphael.dtb`, decompiled with `dtc`)

```
remoteproc@17300000  qcom,sm8150-adsp-pas   fw qcom/sm8150/Xiaomi/raphael/adsp.mbn
                     └─ fastrpc  label = "adsp"      → /dev/fastrpc-adsp
                     └─ glink-edge label "lpass" └─ apr { q6core, q6afe, ... }   [AUDIO]
remoteproc@2400000   qcom,sm8150-slpi-pas   fw .../slpi.mbn
                     └─ fastrpc  label = "sdsp"      → /dev/fastrpc-sdsp    <-- NOTE!
remoteproc@4080000   qcom,sm8150-mpss-pas   fw .../modem.mbn   (no fastrpc)   [MODEM]
remoteproc@8300000   qcom,sm8150-cdsp-pas   fw .../cdsp.mbn
                     └─ fastrpc  label = "cdsp"      → /dev/fastrpc-cdsp
wifi@18800000        qcom,wcn3990-wifi       qcom,calibration-variant = "Xiaomi_raphael"
serial@c8c000        qcom,geni-uart └─ bluetooth { compatible = "qcom,wcn3998-bt" }
```

Two facts that are easy to get wrong and that change the packaging:

1. **The SLPI remoteproc's fastrpc node is labelled `sdsp`, not `slpi`.**
   The fastrpc driver names devices `fastrpc-%s%s`, so this device gets
   `/dev/fastrpc-sdsp`. That inverts which `hexagonrpcd` unit can run — see §1.6.
2. **There is no `pd-mapper` node in the device tree**, yet the kernel driver
   still binds — see §0.3.

### 0.3 The kernel already implements the PD mapper on sm8150

Read from upstream sources (Linux master, matching 7.2.0):

* `drivers/remoteproc/qcom_q6v5_pas.c:918` calls
  `qcom_add_pdm_subdev(rproc, &pas->pdm_subdev)` **unconditionally** in probe.
* `drivers/remoteproc/qcom_common.c` `pdm_notify_prepare()` then creates an
  auxiliary device named `pd-mapper` (parent `qcom_common`), so
  `qcom_pd_mapper.ko` (module alias `auxiliary:qcom_common.pd-mapper`) is
  autoloaded.
* `drivers/soc/qcom/qcom_pd_mapper.c` `qcom_pdm_start()` does
  `of_machine_get_match(qcom_pdm_domains)`; `"qcom,sm8150"` **is** in the table
  with a non-NULL `.data`, and the driver then calls

  ```c
  qmi_add_server(&data->handle, QMI_SERVICE_ID_SERVREG_LOC, 0x101, 0);
  ```

  with `QMI_SERVICE_ID_SERVREG_LOC == 0x40 == 64`
  (`include/linux/soc/qcom/qmi.h:101`).
* The userspace daemon publishes the **same** service: `pd-mapper.c:422`
  `qrtr_publish(fd, SERVREG_QMI_SERVICE, ...)` with
  `servreg_loc.h:9 #define SERVREG_QMI_SERVICE 64`.

**Therefore on this device the kernel and the userspace `pd-mapper` contend for
QRTR service 64; only one can own it.** The kernel driver's domain table for
sm8150 is hardcoded to
`{adsp_audio_pd, adsp_root_pd, cdsp_root_pd, mpss_root_pd_gps, mpss_wlan_pd}`;
it does **not** read the `.jsn` files. The kernel even has a printk for the
fallback case: `"PDM: no support for the platform, userspace daemon might be
required."` — confirming the two are meant to be alternatives, not companions.

Practical recommendation: **install `pd-mapper` (parity with the working Debian
image and a safety net if the kernel module never binds), keep it enabled, and
verify on the device.** A logged `-EADDRINUSE`/restart loop in one of the two is
expected and is not by itself a failure. See §6.3 for the exact check.

### 0.4 Device firmware actually shipped by the working Debian image

From `_recon/dl/firmware.deb` (907 entries, extracted with
`ar x` + `tar --zstd -tf`):

```
/usr/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin.zst      <- Wi-Fi
/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin.zst
/usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn.zst
/usr/lib/firmware/ath10k/WCN3990/hw1.0/notice.txt_wlanmdsp.zst
/usr/lib/firmware/qca/crnv21.bin.zst                           <- Bluetooth NV
/usr/lib/firmware/qcom/sm8150/Xiaomi/raphael/
    adsp.mbn  adspr.jsn  adsps.jsn  adspua.jsn      <- ADSP + its servreg JSON
    cdsp.mbn  cdspr.jsn                             <- CDSP + servreg JSON
    slpi.mbn  slpir.jsn  slpius.jsn                 <- SLPI + servreg JSON
    modem.mbn modemr.jsn modemuw.jsn                <- modem + servreg JSON
    wlanmdsp.mbn  a640_zap.mbn  ipa_fws.mbn  ipa_uc.mbn  venus.mbn
```

Note that the firmware ships **`.zst`-compressed** Wi-Fi/BT files (the kernel
needs `CONFIG_FW_LOADER_COMPRESS_ZSTD`) and **only `crnv21.bin`** for Bluetooth —
there is no `crbtfw21.tlv` in this package, which is expected for WCN3998 whose
RAM patch is requested from the `qcom,wcn3998-bt` binding (see §5.2).

The `qcom/sm8150/Xiaomi/raphael/` tree is **device-specific and is NOT in
ALARM's `linux-firmware`** — it must be copied from the phone's own partitions
(or taken from the sibling project's `firmware.deb`). ALARM's split
`linux-firmware-*` subpackages cover only the generic `ath10k/WCN3990` and
`qca/` parts.

---

## 1. Per-daemon reference

Legend for dependency tables: **ALARM** column is the verified package in the
ALARM core/extra databases, or `NOT IN ALARM` meaning it must be built from
source as well.

### 1.1 `qrtr` — libqrtr + `qrtr-lookup` + `qrtr-cfg`  (REQUIRED, build first)

| | |
|---|---|
| Upstream | <https://github.com/linux-msm/qrtr> |
| Build system | **meson + ninja** (`meson.build` at top level, plus `lib/`, `include/`, `src/`) |
| Verified refs | tag `v1.2` = `b51ffaf22707b6000ecfb894c5b750f3bb7843b2`; `master` = `29e36ae164389580a0f8ea7a7fdb728140ae978d` (2026-09-15) |
| Build deps | `meson` (extra ✓), `ninja` (extra ✓, pulled in by meson), `pkgconf` (core ✓, in `base-devel`), `gcc` (core ✓) |
| Runtime deps | `glibc` (core ✓) |
| Installs | `/usr/bin/qrtr-cfg`, `/usr/bin/qrtr-lookup`, `/usr/lib/libqrtr.so.1.2` (+ `.so.1`, `.so`), `/usr/include/libqrtr.h`, `/usr/lib/pkgconfig/qrtr.pc` |
| systemd units | **none** |
| udev rules | **none** |

Exact commands:

```bash
git clone https://github.com/linux-msm/qrtr && cd qrtr
meson setup build --prefix=/usr --buildtype=release \
      -Dqrtr-ns=disabled -Dsystemd-service=disabled
meson compile -C build
DESTDIR="$pkgdir" meson install -C build
```

**`qrtr-ns` must not be built.** The QRTR name service lives in the kernel:
`qrtr.ko`'s own module description string is literally
`Qualcomm IPC Router Nameservice`, and its symbol table contains
`qrtr_ns_init`, `qrtr_ns_worker`, `qrtr_ns_handler`. Debian's changelog states it
plainly: *"The QRTR nameserver has been built into the kernel for years now"*
(that is why `protection-domain-mapper` 1.0-4's `Requires=qrtr-ns.service` was
dropped in 1.0-7). Upstream **master has deleted `src/ns.c`,
`qrtr-ns.service.in`, `src/map.c`, `src/waiter.c` and `meson_options.txt`
entirely**; only the `v1.2` tag still has them. There is nothing to run — if you
build from `master`, `-Dqrtr-ns` does not even exist and must be omitted.

> `qrtr-lookup` is a **diagnostic client only** (it dumps the QRTR service
> table). Nothing requires it at boot, but it is the tool you want when
> debugging whether `pd-mapper` registered service 64. The kernel does not ship
> a replacement for it.

**Does `libqrtr-glib` substitute for `libqrtr`?** No. ALARM's `libqrtr-glib`
1.4.0-1 (`extra`) is the *glib-based* helper used by ModemManager; it depends on
`glib2`/`gcc-libs` and provides `libqrtr-glib.so=0-64`. It is a different
library, its pkg-config name is `libqrtr-glib`, and it does **not** provide
`qrtr.pc` or `libqrtr.so`. There is no `qrtr`, `qrtr-lookup`, `qrtr-ns` or
`libqrtr` package anywhere in ALARM core/extra (verified by scanning all 13 256
package names and all 7 264 `provides` entries). **Hence `libqrtr` must be built
from source — this is the one unavoidable from-source dependency.**

### 1.2 `rmtfs` — Qualcomm Remote Filesystem Service  (REQUIRED)

| | |
|---|---|
| Upstream | <https://github.com/linux-msm/rmtfs> |
| Build system | **plain Makefile** (no CMake, no QMake, no meson) |
| Verified ref | `master` = `b30a3eb38f9af283f18dbd3c7755653efc52c094` (2026-06-22). **Upstream has no git tags and no releases.** |
| Link line | `-lqrtr -ludev -lpthread` (hardcoded in `LDFLAGS`) |
| Build deps | `make` (core ✓), `gcc` (core ✓) — both from `base-devel` |
| Runtime deps | `glibc` (core ✓), `systemd-libs` (core ✓ — **`libudev` is not a package**; `systemd-libs` `provides=('libsystemd' 'libsystemd.so=0-64' 'libudev.so=1-64')`), **`qrtr`** (NOT IN ALARM → §1.1) |
| Installs | `/usr/bin/rmtfs`, `/usr/lib/systemd/system/rmtfs.service`, `/usr/lib/systemd/system/rmtfs-dir.service`, `/usr/lib/udev/rules.d/rmtfs.rules` |

Verified by running the real targets (`make -n DESTDIR=… prefix=/usr RMTFS_EFS_PATH=/var/lib/rmtfs install`):

```bash
git clone https://github.com/linux-msm/rmtfs && cd rmtfs
make prefix=/usr RMTFS_EFS_PATH=/var/lib/rmtfs
make DESTDIR="$pkgdir" prefix=/usr RMTFS_EFS_PATH=/var/lib/rmtfs install
```

`prefix = /usr/local` is a plain `=` assignment in the Makefile, but a
**command-line** `prefix=/usr` still wins (command-line variables override
makefile assignments), which is exactly what Debian's `debian/rules` does via
`RMTFS_BUILD_OPTS=prefix=/usr`. `RMTFS_EFS_PATH` is `?=` so it is also
overridable. With `prefix=/usr` the units land in `/usr/lib/systemd/system`
and the rule in `/usr/lib/udev/rules.d` — correct for Arch.

**Which unit to enable — `rmtfs.service`, not `rmtfs-dir.service`.** They are
alternatives (one uses the shared-memory device node, the other a plain
directory):

`rmtfs.service` (after `sed` substitution, verified):

```ini
[Unit]
Description=Qualcomm remotefs service
Before=NetworkManager.service
ConditionPathExists=/dev/qcom_rmtfs_mem1

[Service]
ExecStart=/usr/bin/rmtfs -r -P -s
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

`rmtfs-dir.service`:

```ini
[Unit]
Description=Qualcomm remotefs service
Before=NetworkManager.service

[Service]
ExecStart=/usr/bin/rmtfs -s -o /var/lib/rmtfs
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
```

`rmtfs.rules`:

```
ACTION=="add", KERNEL=="qcom_rmtfs_mem*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="rmtfs.service"
```

**Unit modifications needed for this device: none.** `ConditionKernelVersion` is
absent from upstream `master`, from `v1.1` and from every Debian revision
checked (1.0-4, 1.0-7, 1.1-1) — this is worth stating because the sibling
project still runs
`sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service
|| true`. That `sed` is a **harmless legacy no-op** on current versions (and it
targets `pd-mapper.service`, not `rmtfs.service`). Keep the udev rule: it
re-triggers the service whenever `/dev/qcom_rmtfs_mem*` appears, which the
static `ConditionPathExists` alone cannot do if the node shows up late.

Do **not** enable `rmtfs-dir.service`: Debian's `debian/rules` explicitly does
`dh_installsystemd --name rmtfs-dir --no-start --no-enable` with the comment
*"the rmtfs-dir must be disabled by default in order to prevent race conditions
with the main rmtfs service"*.

### 1.3 `pd-mapper` (Debian source name `protection-domain-mapper`)

| | |
|---|---|
| Upstream | <https://github.com/linux-msm/pd-mapper> |
| Build system | **plain Makefile** |
| Verified ref | `master` = `5ecd2fe926aca7abfe40724177f63b942cff3947` (2025-12-30). **No git tags.** |
| Link line | `-lqrtr -llzma` |
| Build deps | `make`, `gcc` (`base-devel` ✓) |
| Runtime deps | `glibc` (core ✓), `xz` (core ✓ — `provides=('liblzma.so=5-64')`; **there is no `liblzma` or `lzma` package**), **`qrtr`** (NOT IN ALARM) |
| Installs | `/usr/bin/pd-mapper`, `/usr/lib/systemd/system/pd-mapper.service` |
| udev rules | **none** |

Verified with `make -n install`:

```bash
git clone https://github.com/linux-msm/pd-mapper && cd pd-mapper
make prefix=/usr
make DESTDIR="$pkgdir" prefix=/usr install
```

`pd-mapper.service` (upstream `master`, byte-identical to Debian 1.1-1):

```ini
[Unit]
Description=Qualcomm PD mapper service

[Service]
ExecStart=/usr/bin/pd-mapper
Restart=always

[Install]
WantedBy=multi-user.target
```

**Unit modifications needed: none for the unit text** — but read §0.3 before
enabling it, because the kernel also claims service 64 on this SoC.

Optional hardening worth copying from Debian: `debian/patches/0001-pd-mapper-lookup-firmware-files-under-lib-firmware-u.patch`
makes pd-mapper search `/lib/firmware/updates` first and **not crash** when the
firmware directory is missing (it only `warn()`s instead of dereferencing a NULL
`DIR *`). On Arch `/lib` is a symlink to `/usr/lib`, so the extra path is
`/usr/lib/firmware/updates`. This is a genuine robustness fix, not a
device-specific requirement; add it as a `source=` patch if you want parity.

### 1.4 `tqftpserv`  (REQUIRED for modem firmware loading)

| | |
|---|---|
| Upstream | <https://github.com/linux-msm/tqftpserv> |
| Build system | **meson + ninja** |
| Verified ref | `master` = `c2559a26098f6d2b36a946ef0b6ad02223264c3e` (2026-09-02). **No git tags.** `meson.build` declares `version: '1.1.1'` (Debian labels the same code `1.2`). |
| Build deps | `meson` (extra ✓), `ninja` (extra ✓), `pkgconf` (core ✓) |
| Runtime deps | `glibc` (core ✓), `zstd` (core ✓ — `provides=('libzstd.so=1-64')`; **there is no `libzstd` package**), **`qrtr`** (NOT IN ALARM) |
| Installs | `/usr/bin/tqftpserv`, `/usr/lib/systemd/system/tqftpserv.service` |
| udev rules | **none** |

`meson.build` resolves the unit directory as
`-Dsystemd-unit-prefix` → else `systemd.pc` → else nothing, so passing the
option explicitly removes the need for systemd in a clean chroot:

```bash
git clone https://github.com/linux-msm/tqftpserv && cd tqftpserv
meson setup build --prefix=/usr --buildtype=release \
      -Dsystemd-unit-prefix=/usr/lib/systemd/system
meson compile -C build
DESTDIR="$pkgdir" meson install -C build
```

`tqftpserv.service`:

```ini
[Unit]
Description=QRTR TFTP service

[Service]
ExecStart=/usr/bin/tqftpserv
Restart=always
StateDirectory=tqftpserv

[Install]
WantedBy=multi-user.target
```

**Unit modifications needed: none.** Note the tree also contains
`tqftpserv-populate-readwrite.service.in` and `populate-readwrite.sh`, but
`meson.build` **does not install them** — they exist only for devices with a
`persist` partition (`Requires=dev-disk-by\x2dpartlabel-persist.device`), which
raphael does not have in the mainline DT. Ignore them.

The daemon translates `/readonly/firmware/image/…` → `/lib/firmware/…` and
`/readwrite/…` → `/tmp/tqftpserv/`; the readwrite root is created by the unit's
`StateDirectory=`.

### 1.5 `qbootctl`  (OPTIONAL — not needed for boot)

| | |
|---|---|
| Upstream | <https://github.com/linux-msm/qbootctl> — **default branch is `main`**, not `master` |
| Build system | **meson + ninja** (`project('qbootctl','c', default_options:['c_std=gnu11'])`) |
| Verified ref | `main` = `39a6e6daaf029fb0a083777679a15ea2c18f72de` (2025-03-24) |
| Build deps | `meson`, `ninja`, `pkgconf`, and `<linux/bsg.h>` from `linux-api-headers` (core ✓ — meson hard-errors `'linux-headers not found'` without it; it is a dependency of `glibc`, so it is always present) |
| Runtime deps | `glibc` only |
| Installs | `/usr/bin/qbootctl` — **no unit, no udev rule** |
| Systemd units | **none** (by design — it is a one-shot CLI) |

```bash
git clone https://github.com/linux-msm/qbootctl && cd qbootctl
meson setup build --prefix=/usr --buildtype=release -Dc_std=gnu11
meson compile -C build
DESTDIR="$pkgdir" meson install -C build
```

Nothing in the Wi-Fi / Bluetooth / audio / modem / sensor paths needs it. It is
also **not** what selects the boot slot on this device in the sibling project
(u-boot does that). Treat it as a debugging/administration extra.

### 1.6 `hexagonrpc` → `hexagonrpcd`  (OPTIONAL — sensors / CHRE and FastRPC fileserving)

| | |
|---|---|
| Upstream | <https://github.com/linux-msm/hexagonrpc> — note the repo is **`hexagonrpc`**, the daemon is **`hexagonrpcd`**. **Branch `main`.** |
| Build system | **meson + ninja**, `meson_version: '>=1.1'`; `project('fastrpc', 'c', version: '0.5.0')` |
| Verified ref | `main` = `598b591ae9da6a6cfe2ca5ea78998019ca6395ea` (2026-08-24) |
| Options | `meson.options` (the new filename — there is **no** `meson_options.txt`, so on meson < 1.1 the build fails): `hexagonrpcd_verbose` (bool, default false) |
| Build deps | `meson` (extra ✓, 1.12.1 ≥ 1.1), `ninja`, `pkgconf`; optional `json-c` for `tools/sscregistrygen` |
| Runtime deps | `glibc` only |
| Installs | `/usr/bin/hexagonrpcd`, `/usr/share/man/man1/hexagonrpcd.1`, `/usr/lib/libhexagonrpc.so.0.5`, `/usr/lib/hexagonrpc/chrecd`, and `hexagonrpcd-{adsp-rootpd,adsp-sensorspd,sdsp}.service` in `$(libdir)/systemd/system` |

```bash
git clone https://github.com/linux-msm/hexagonrpc && cd hexagonrpc
meson setup build --prefix=/usr --buildtype=release -Dhexagonrpcd_verbose=false
meson compile -C build
DESTDIR="$pkgdir" meson install -C build
```

**Unit modifications needed: YES — unit *selection*, not unit text.** The three
upstream units have mutually exclusive conditions:

| Unit | Conditions |
|---|---|
| `hexagonrpcd-adsp-rootpd.service` | `ConditionPathExists=!/dev/fastrpc-sdsp` + `ConditionPathExists=/dev/fastrpc-adsp` |
| `hexagonrpcd-adsp-sensorspd.service` | `ConditionPathExists=!/dev/fastrpc-sdsp` + `ConditionPathExists=/dev/fastrpc-adsp` |
| `hexagonrpcd-sdsp.service` | `ConditionPathExists=/dev/fastrpc-sdsp` |

Because raphael's SLPI is labelled `sdsp` (§0.2), `/dev/fastrpc-sdsp` **does**
exist, so:

* ✅ enable **`hexagonrpcd-sdsp.service`**
* ❌ the two `adsp-*` units are suppressed by `!/dev/fastrpc-sdsp`

The upstream FIXME — *"Remove this once hexagonrpcd can serve rootpd on the ADSP
of the SDM845 devices"* — is the same mechanism; it is intentional for
SDM845/SM8150-class SoCs.

Two packaging gaps upstream does not cover (both added in the PKGBUILD):
the units run `User=fastrpc` / `Group=fastrpc` but upstream ships **no
`sysusers.d` file**, and it ships only Android `.rc` files, **no udev rule** for
the `fastrpc-%s%s` device nodes.

### 1.7 Explicitly NOT required

| Candidate | Verdict |
|---|---|
| `qrtr-ns` | **Obsolete.** Name service is in `qrtr.ko`; upstream master deleted `src/ns.c`. See §1.1. |
| `qrtr-lookup` / `qrtr-cfg` | Diagnostic only; ship them (they come free with the `qrtr` package) but nothing depends on them at boot. |
| `msm-modem-uim-selection` | **Not required, and its upstream is not verifiable.** It is **not in Debian at all** — `packages.debian.org` returns "Sorry, your search gave no results" for it across all suites/architectures, and `sources.debian.org` has no `msm-modem` source package. The working sibling project does not install it. Origin **UNVERIFIED** (GitHub/GitLab search APIs were rate-limited or unauthorised at the time of writing). Do not add it. |
| `libqrtr-glib` | Wrong library — glib-based, for ModemManager. Not a substitute for `libqrtr`. §1.1. |
| `ModemManager` / `libqmi` | Not needed by these daemons. Only relevant if you want a full modem data stack; not part of this deliverable. |
| `protection-domain-mapper`-style udev rules | pd-mapper has none upstream. |

---

## 2. pkexec/fakeroot-free build strategy: cross-compile vs. native qemu

Goal: produce **aarch64** binaries for the `raphael-arch/work/root` rootfs,
without root and without `pkexec`.

### 2.1 What the host actually has (verified)

| Tool | Status |
|---|---|
| `clang`, `clang++`, `lld`, `ld.lld`, `llvm-ar` | ✅ present |
| `dtc`, `python3` (3.13.9), `curl`, `tar`, `7z`, `gpg`, `cpio`, `zstd`, `xz`, `make`, `git` | ✅ present |
| `qemu-aarch64` | ✅ present (11.1.1, user-mode) |
| `unshare` | ✅ present, **unprivileged user namespaces work** |
| **`cmake`** | ❌ **MISSING** |
| **`ninja`** | ❌ **MISSING** |
| `meson` | ❌ MISSING |
| `qemu-aarch64-static`, `binfmt_misc` aarch64 entry | ❌ absent (`/proc/sys/fs/binfmt_misc/` contains only `DOSWin`, `register`, `status`) |
| `fakeroot`, `pkexec` | present but **not needed** for either strategy |

The missing `cmake`/`ninja`/`meson` are a real constraint for strategy (a),
because four of the six packages (qrtr, tqftpserv, qbootctl, hexagonrpc) are
meson projects and **meson hard-requires ninja** — so on the host you must
either install them or fall back to strategy (b). They can be installed without
root via pip:

```bash
python3 -m pip install --user meson ninja
# verified: `pip download ninja` resolves ninja-1.13.2-py3-none-manylinux…whl
# cmake is only needed if you build a CMake project — none of these are CMake.
```

Note that **none of the five daemons uses CMake or QMake.** rmtfs and pd-mapper
are plain Makefiles; qrtr, tqftpserv, qbootctl and hexagonrpc are meson. A CMake
toolchain is therefore never required.

### 2.2 Option (b) — compile natively inside the aarch64 rootfs with qemu-user

**Recommended.** It is fully verified working on this machine and removes every
sysroot/CRT problem at once.

Verified facts:

* `unshare -r -m` **works**: it yields `uid=0(root)` *inside a private user+mount
  namespace* and `mount -t tmpfs` succeeds. No host root, no `pkexec`, no
  `sudo`. (`kernel.unprivileged_userns_clone = 1`, `user.max_user_namespaces =
  126794`.)
* `qemu-aarch64 -L <rootfs> <rootfs>/usr/bin/bash -c '…'` works, **including
  nested `execve` of other aarch64 binaries** — `qemu-aarch64 -L $R
  $R/usr/bin/bash -c 'pacman --version'` printed `Pacman v7.1.0 - libalpm
  v16.0.1`. This matters because `binfmt_misc` is **not** registered, so a bare
  `./aarch64-binary` would fail with `Exec format error`; you must enter through
  `qemu-aarch64` and let it re-exec itself for children.
* The rootfs at `work/root` is already extracted (18 top-level entries,
  996 files in `usr/bin`, `pacman`/`bash`/`libc.so.6`/`pacman.conf` all present)
  but contains **no build tools at all** — no `make`, `cmake`, `ninja`, `meson`,
  `gcc`, `pkgconf`, `fakeroot`.
* The rootfs is a **usable, populated system**: `qemu-aarch64 -L "$R"
  "$R/usr/bin/pacman" -Q` lists **801 installed packages**, and `pacman.conf`
  already defines an `alarm` repo (its database is not yet downloaded:
  `warning: database file for 'alarm' does not exist (use '-Sy' to download)`).
  So a `pacman -Sy` + `pacman -S base-devel meson` is a small delta, not a
  bootstrap.

Exact recipe:

```bash
R=/home/winter/Documents/VSCode/raphael-arch/work/root

# 0) one-time: point the rootfs at a mirror and fetch the package databases
unshare -r -m --propagation private bash -c '
  set -e
  R=/home/winter/Documents/VSCode/raphael-arch/work/root
  # ALARM ships a mirrorlist already; enable a fast one, e.g.:
  #   Server = http://mirror.archlinuxarm.org/$arch/$repo
  mount --bind /dev  "$R/dev"   2>/dev/null || true
  mount --bind /proc "$R/proc"  2>/dev/null || true
  mount --bind /sys  "$R/sys"   2>/dev/null || true
  # DNS/resolv.conf is needed for pacman
  cp /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null || true
  chroot "$R" /usr/bin/qemu-aarch64 -L "$R" /usr/bin/bash -c "
      pacman-key --init && pacman-key --populate archlinuxarm
      pacman -Syyu --noconfirm
      pacman -S --needed --noconfirm base-devel meson git
  "
'
```

The `chroot` needs the emulator to be reachable *inside* the rootfs. The
simplest robust arrangement is to place the (static) emulator inside the rootfs
first, then `chroot`:

```bash
# copy qemu into the rootfs once (no root needed — the rootfs is user-owned)
install -D -m 755 "$(command -v qemu-aarch64)" "$R/usr/bin/qemu-aarch64"
```

But note the host's `qemu-aarch64` is dynamically linked against **host x86_64**
libraries, so once inside the chroot it will not run. Two clean ways out:

* **Preferred:** do *not* chroot. Run everything through the host emulator with
  `-L`, which is exactly what was verified to work:

  ```bash
  qemu-aarch64 -L "$R" "$R/usr/bin/bash" -c '
      export PATH=/usr/bin:/usr/sbin
      pacman -S --needed --noconfirm base-devel meson git
  '
  ```

  `pacman` needs `/proc`, `/sys` and `/dev` to be useful; bind-mount them first
  (the `unshare -r -m` step above gives you the privilege to do that):

  ```bash
  unshare -r -m --propagation private bash -c '
    R=/home/winter/Documents/VSCode/raphael-arch/work/root
    mount --bind /proc "$R/proc"; mount --bind /sys "$R/sys"; mount --bind /dev "$R/dev"
    qemu-aarch64 -L "$R" "$R/usr/bin/bash" -c "pacman -S --needed --noconfirm base-devel meson git"
  '
  ```

* Or use `qemu-aarch64-static` (from the host `qemu-user-static`-equivalent
  package) copied into the rootfs, then a real `chroot`. That binary is not
  installed here.

Then build natively:

```bash
unshare -r -m --propagation private bash -c '
  R=/home/winter/Documents/VSCode/raphael-arch/work/root
  mount --bind /proc "$R/proc"; mount --bind /sys "$R/sys"; mount --bind /dev "$R/dev"
  cp -r /home/winter/Documents/VSCode/raphael-arch/pkgs "$R/build"
  qemu-aarch64 -L "$R" "$R/usr/bin/bash" -c "
      cd /build/rmtfs && makepkg -s --noconfirm --nodeps
  "
'
```

> **`makepkg` refuses to run as root.** Inside `unshare -r` you *are* uid 0, and
> recent pacman has removed `--asroot`. Create an unprivileged builder inside
> the namespace instead:
> ```bash
> unshare -r -m bash -c '
>   R=…/work/root
>   qemu-aarch64 -L "$R" "$R/usr/bin/bash" -c "
>       id -u builder >/dev/null 2>&1 || useradd -m builder
>       chown -R builder:builder /build
>       su builder -c \"cd /build/rmtfs && makepkg -s --noconfirm\"
>   "
> '
> ```
> This is **UNVERIFIED** end-to-end (only the `unshare -r` + `qemu-aarch64 -L` +
> `pacman --version` legs were executed). If it proves awkward, skip `makepkg`
> entirely and just run the `build()`/`package()` commands by hand inside the
> emulated rootfs, then `tar` the result — the PKGBUILDs remain valid for a real
> aarch64 builder later.

**Gotchas (verified):**

* `uname -m` **reports the host architecture (`x86_64`) inside qemu-user**
  (`qemu-aarch64 -L $R $R/usr/bin/bash -c 'echo $(uname -m)'` → `x86_64`).
  Any configure script or Makefile that keys off `uname -m` will mis-detect the
  architecture. Force `--host=aarch64-linux-gnu` / `-Dhost_machine` explicitly
  where the build system asks.
* Emulation is roughly 5–20× slower than native. Fine for these tiny C projects
  (a few hundred KB of source each), painful for a full `base-devel` install.
* Ensure the rootfs pacman mirrorlist points at `aarch64` (ALARM), not x86_64.

### 2.3 Option (a) — cross-compile from x86_64 with clang/lld + rootfs sysroot

Works, and is ~10× faster, but needs one extra staging step that is easy to miss.

**The failure mode you will hit first** (verified):

```
$ clang --target=aarch64-linux-gnu --sysroot=$R -fuse-ld=lld -o hw hw.c
ld.lld: error: cannot open crtbeginS.o: No such file or directory
ld.lld: error: unable to find library -lgcc
ld.lld: error: cannot open crtendS.o: No such file or directory
```

Cause: the extracted rootfs is a *runtime* rootfs. It has glibc's `crt1.o`,
`crti.o`, `crtn.o` (and `ld-linux-aarch64.so.1`, `libc.so.6`) but **no `gcc`
package**, hence no `/usr/lib/gcc/...`, no `crtbeginS.o`/`crtendS.o`, no
`libgcc.a`. `--rtlib=compiler-rt` does not rescue it either — the host clang has
no aarch64 builtins (`/usr/lib/clang/22/lib/aarch64-unknown-linux-gnu/libclang_rt.builtins.a`
does not exist).

Two fixes:

**(a1) Recommended — stage GCC's CRT objects into the sysroot.** Download the
ALARM `gcc` package (verified: 46 558 316 bytes from
`http://mirror.archlinuxarm.org/aarch64/core/`) and unpack it next to the
rootfs, then add `-B` *and* `-L`:

```bash
R=/home/winter/Documents/VSCode/raphael-arch/work/root
mkdir -p /tmp/sysroot-stage && cd /tmp/sysroot-stage
curl -sL -o gcc.pkg.tar.xz \
  http://mirror.archlinuxarm.org/aarch64/core/gcc-16.1.1+r12+g301eb08fa2c5-1-aarch64.pkg.tar.xz
tar -xf gcc.pkg.tar.xz -C /tmp/sysroot-stage/x

# NOTE the triple: ALARM's gcc uses aarch64-unknown-linux-gnu, but clang's
# --target=aarch64-linux-gnu makes it search aarch64-linux-gnu. Hence BOTH
# -B (for crtbeginS.o/crtendS.o) and -L (for -lgcc) are mandatory.
G=/tmp/sysroot-stage/x/usr/lib/gcc/aarch64-unknown-linux-gnu/16.1.1

clang --target=aarch64-linux-gnu --sysroot="$R" \
      -B "$G" -L "$G" -fuse-ld=lld \
      -o /tmp/hw /tmp/hw.c
```

**This is verified working**: the result is
`ELF 64-bit LSB pie executable, ARM aarch64, … interpreter /lib/ld-linux-aarch64.so.1`,
and `qemu-aarch64 -L "$R" /tmp/hw` prints `cross-ok`.

For the two Makefile projects the same thing is expressed as:

```bash
CC="clang --target=aarch64-linux-gnu --sysroot=$R -B $G -L $G -fuse-ld=lld" \
make -C rmtfs prefix=/usr RMTFS_EFS_PATH=/var/lib/rmtfs
```

(`CFLAGS +=`/`LDFLAGS +=` in those Makefiles append to, rather than replace,
your environment values, so exporting `CFLAGS`/`LDFLAGS` also works. Put the
whole `--target/--sysroot/-B/-L` set into `CC` so it reaches the link line too.)

For the meson projects, write a cross file:

```ini
# /tmp/aarch64-cross.ini
[binaries]
c = 'clang'
ar = 'llvm-ar'
strip = 'llvm-strip'
pkgconfig = 'pkg-config'

[built-in options]
c_args = ['--target=aarch64-linux-gnu', '--sysroot=/home/winter/Documents/VSCode/raphael-arch/work/root',
          '-B', '/tmp/sysroot-stage/x/usr/lib/gcc/aarch64-unknown-linux-gnu/16.1.1',
          '-L', '/tmp/sysroot-stage/x/usr/lib/gcc/aarch64-unknown-linux-gnu/16.1.1',
          '-fuse-ld=lld']
c_link_args = ['--target=aarch64-linux-gnu', '--sysroot=/home/winter/Documents/VSCode/raphael-arch/work/root',
               '-B', '/tmp/sysroot-stage/x/usr/lib/gcc/aarch64-unknown-linux-gnu/16.1.1',
               '-L', '/tmp/sysroot-stage/x/usr/lib/gcc/aarch64-unknown-linux-gnu/16.1.1',
               '-fuse-ld=lld']

[host_machine]
system = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
```

```bash
meson setup build --cross-file /tmp/aarch64-cross.ini --prefix=/usr \
      -Dqrtr-ns=disabled -Dsystemd-service=disabled
```

**(a2) Fallback without downloading gcc** — bypass the CRT entirely. Verified
to produce a valid, runnable aarch64 binary:

```bash
clang --target=aarch64-linux-gnu --sysroot="$R" -fuse-ld=lld \
      -nostdlib -nostartfiles -o hw hw.c \
      "$R/usr/lib/crt1.o" "$R/usr/lib/crti.o" "$R/usr/lib/crtn.o" -lc
```

This is **not recommended for the real daemons**: it drops `crtbegin`/`crtend`,
so `.init_array` constructors never run and no unwinder is linked. It is only
useful as a smoke test.

**Extra caveat for option (a):** `pkg-config` must resolve `qrtr` **for the
aarch64 sysroot**, not the host. Set `PKG_CONFIG_SYSROOT_DIR="$R"` and
`PKG_CONFIG_LIBDIR="$R/usr/lib/pkgconfig:$R/usr/share/pkgconfig"`, and install
the `qrtr` package into the sysroot before building tqftpserv.

### 2.4 Recommendation

**Use (b) — native build inside the emulated aarch64 rootfs — as the primary
path, and (a) as a speed-up once a sysroot is staged.**

Reasons, in order of weight:

1. **(b) is verified end-to-end on this machine; (a) is verified only for the
   toolchain** (a hello-world links and runs). Strategy (a) additionally needs
   a `qrtr` sysroot install, `PKG_CONFIG_*` redirection, a hand-written meson
   cross file, and a 46 MB gcc download — four extra failure points for a
   handful of tiny C programs.
2. **The host is missing `ninja`/`meson`** (verified), and 4 of the 5 daemons
   are meson projects. (b) sidesteps this entirely because ALARM ships `meson`
   1.12.1, `ninja` 1.13.2 and `cmake` 4.4.3 for aarch64 — all present in
   core/extra and installable with the single `pacman -S base-devel meson` above.
3. **(b) produces genuine aarch64 packages** through the normal
   `PKGBUILD`/`makepkg` flow, so the same PKGBUILDs can later be handed to a
   real aarch64 builder or CI unchanged.
4. Speed is the only argument for (a), and these binaries are ~50–200 KB of C
   each; emulation cost is negligible.

Everything needed for (b) exists in ALARM, verified by name:
`base-devel` (core, `depends=('archlinux-keyring' 'autoconf' 'automake'
'binutils' 'bison' 'debugedit' 'fakeroot' 'file' 'findutils' 'flex' 'gawk' 'gcc'
'gettext' 'grep' 'groff' 'gzip' 'libtool' 'm4' 'make' 'pacman' 'patch'
'pkgconf' 'sed' 'sudo' 'texinfo' 'which')`), `meson` 1.12.1-1 (extra),
`ninja` 1.13.2-3 (extra), `git` 2.55.0-1 (extra).

### 2.5 Is a static musl/glibc build trivial? (per project)

Short answer: **no — do not go down this path.** Static linking does *not* avoid
the sysroot problem here, because the blocker is `libqrtr`, which is a *local*
library you are building anyway, and because the real obstacle is CRT objects
that must match the target libc either way.

| Project | Static build | Why |
|---|---|---|
| `qrtr` | **Possible, not useful** | `lib/meson.build` uses `library('qrtr', …)`, which honours `-Ddefault_library=static` → produces `libqrtr.a` instead of `libqrtr.so`. But tqftpserv's `dependency('qrtr')` then needs a static `.pc` with `Libs.private`, and you lose the shared soname that the PKGBUILDs declare (`libqrtr.so=1-64`). No benefit. |
| `rmtfs` | **Not trivial** | Links `-ludev`. ALARM's `systemd-libs` ships **only** `libudev.so.1` (+ linker script/symlink); there is no `libudev.a` in the package, so a fully static link would require rebuilding systemd. You *can* statically link everything except libudev, which defeats the purpose. |
| `pd-mapper` | **Nearly trivial** | Links only `-lqrtr -llzma`. With a static `libqrtr.a` and `xz`'s `liblzma.a` (ALARM's `xz` does ship `liblzma.a`) a static build is plausible. Still pointless: you would be statically linking one local library to save one packaging line. |
| `tqftpserv` | **Not trivial** | Needs static `libzstd.a` (`zstd` does ship it) *and* static `qrtr`, and it is a meson project, so you would be fighting `dependency()` regardless. |
| `qbootctl` | **Trivial in principle** | Links only `glibc`. `clang --target=aarch64-linux-gnu -static` would produce a working static binary **without any sysroot CRT gymnastics** — but only for this one optional tool, so it does not solve the general problem. |
| `hexagonrpc` | **Not applicable** | Builds `libhexagonrpc.so` with `soversion`, consumed by `hexagonrpcd`, `chrecd` and the 3 test binaries. Static linking would contradict its own design. |

**Conclusion:** no project here is a genuine candidate for a static musl/glibc
build. The one real pain point (`libqrtr` not being packaged in ALARM) is
solved by building the `qrtr` package once, not by static linking. If you want a
single self-contained artefact and do not care about Arch packaging, the
closest thing to "trivial static" is option **(a2)** above — `-nostdlib
-nostartfiles` plus explicit CRT plus `-static` — applied to `rmtfs`/`pd-mapper`
after building `libqrtr.a`; it is **UNVERIFIED** and not recommended.

---

## 3. PKGBUILDs

Written to `/home/winter/Documents/VSCode/raphael-arch/pkgs/<name>/PKGBUILD`:

| Package | PKGBUILD | Extra files | systemd units handled |
|---|---|---|---|
| `qrtr` | [pkgs/qrtr/PKGBUILD](raphael-arch/pkgs/qrtr/PKGBUILD) | — | none (units deliberately not built) |
| `rmtfs` | [pkgs/rmtfs/PKGBUILD](raphael-arch/pkgs/rmtfs/PKGBUILD) | [rmtfs.install](raphael-arch/pkgs/rmtfs/rmtfs.install) | enables `rmtfs.service`, disables `rmtfs-dir.service` |
| `pd-mapper` | [pkgs/pd-mapper/PKGBUILD](raphael-arch/pkgs/pd-mapper/PKGBUILD) | [pd-mapper.install](raphael-arch/pkgs/pd-mapper/pd-mapper.install) | enables `pd-mapper.service` + kernel-conflict warning |
| `tqftpserv` | [pkgs/tqftpserv/PKGBUILD](raphael-arch/pkgs/tqftpserv/PKGBUILD) | [tqftpserv.install](raphael-arch/pkgs/tqftpserv/tqftpserv.install) | enables `tqftpserv.service` |
| `qbootctl` | [pkgs/qbootctl/PKGBUILD](raphael-arch/pkgs/qbootctl/PKGBUILD) | — | none |
| `hexagonrpc` | [pkgs/hexagonrpc/PKGBUILD](raphael-arch/pkgs/hexagonrpc/PKGBUILD) | [hexagonrpc.install](raphael-arch/pkgs/hexagonrpc/hexagonrpc.install) | enables `hexagonrpcd-sdsp.service`, disables the two `adsp-*` units |

Conventions used, all verified against the ALARM databases:

* `arch=('aarch64')` everywhere (`systemd-libs`, `xz`, `zstd`, `qrtr` and all
  other runtime deps are `aarch64`; `meson` is `arch=any`, which is fine).
* `sha256sums=('SKIP')` because every `source=()` is a VCS `git+` URL. `qrtr`
  pins the real tag `#tag=v1.2`; the untagged projects use `#branch=<branch>`
  plus a `pkgver()` (`git rev-list --count` + short SHA) since upstream has no
  tags. The verified-good SHA for each is recorded as a comment at the top of
  each PKGBUILD so you can switch to `#commit=<sha>` for reproducibility.
* `depends` use only names that exist: `glibc`, `systemd-libs`, `xz`, `zstd`,
  `qrtr` (local), `linux-api-headers`, `json-c`.
* `makedepends` are `meson` for the meson projects and empty for the Makefile
  projects; `gcc`/`make`/`pkgconf`/`ninja` all come from `base-devel` (verified
  group membership), which `makepkg` assumes.

Build them (inside the aarch64 rootfs, per §2.2):

```bash
for p in qrtr rmtfs pd-mapper tqftpserv; do
  ( cd "/home/winter/Documents/VSCode/raphael-arch/pkgs/$p" && makepkg -s --noconfirm )
done
# then install in dependency order
pacman -U qrtr-*.pkg.tar.zst rmtfs-*.pkg.tar.zst \
          pd-mapper-*.pkg.tar.zst tqftpserv-*.pkg.tar.zst
```

---

## 4. Verification without the device

### 4.1 On the built binaries

```bash
R=/home/winter/Documents/VSCode/raphael-arch/work/root

# 1. Correct architecture.
file usr/bin/rmtfs        # -> ELF 64-bit LSB pie executable, ARM aarch64 …
file usr/bin/pd-mapper
file usr/bin/tqftpserv

# 2. Correct dynamic dependencies + interpreter (readelf is a HOST tool and
#    needs no emulation -- prefer it over ldd here).
LC_ALL=C readelf -d usr/bin/rmtfs   | grep NEEDED
LC_ALL=C readelf -l usr/bin/rmtfs   | grep -i interpreter
```

Expected `NEEDED` sets — if one of these is missing, a `depends` line is wrong:

| binary | `NEEDED` (expected) |
|---|---|
| `rmtfs` | `libqrtr.so.1`, `libudev.so.1`, `libc.so.6` |
| `pd-mapper` | `libqrtr.so.1`, `liblzma.so.5`, `libc.so.6` |
| `tqftpserv` | `libqrtr.so.1`, `libzstd.so.1`, `libc.so.6` |
| `qbootctl` | `libc.so.6` |
| `hexagonrpcd` | `libhexagonrpc.so.0.5`, `libc.so.6` |

Interpreter must be `/lib/ld-linux-aarch64.so.1`. Anything mentioning
`ld-linux-x86-64` means the cross build leaked host objects.

**Do not use `ldd` for this.** Under qemu-user `ldd` misreports — verified:
`qemu-aarch64 -L $R $R/usr/bin/bash $R/usr/bin/ldd /tmp/hw` prints
`不是动态可执行文件` ("not a dynamic executable") for a perfectly good binary,
because `ldd` is itself a shell script and its `/proc`-based probing does not
work through emulation. Use `readelf -d` on the host, or just run the binary.

```bash
# 3. Resolve every NEEDED soname against the target rootfs (pure host-side).
for b in rmtfs pd-mapper tqftpserv; do
  echo "== $b"
  LC_ALL=C readelf -d "usr/bin/$b" | awk '/NEEDED/{gsub(/[][]/,"",$5); print $5}' | while read -r so; do
    if find "$R/usr/lib" -name "$so" | grep -q .; then echo "   OK   $so"
    else echo "   MISS $so"; fi
  done
done
```

```bash
# 4. Functional smoke test: run them under emulation.
qemu-aarch64 -L "$R" usr/bin/rmtfs --help   || true
qemu-aarch64 -L "$R" usr/bin/pd-mapper --help || true
qemu-aarch64 -L "$R" usr/bin/tqftpserv --help || true
```

Caveat: these daemons open AF_QIPCRTR sockets and will fail to *serve* outside
the device — that is expected. You are only checking that the binary loads, the
dynamic linker resolves, and the usage/error path prints (i.e. no
`Exec format error`, no `error while loading shared libraries`).

```bash
# 5. Unit files were generated with the right paths substituted.
grep -H ExecStart usr/lib/systemd/system/*.service
#   rmtfs.service       -> ExecStart=/usr/bin/rmtfs -r -P -s
#   rmtfs-dir.service   -> ExecStart=/usr/bin/rmtfs -s -o /var/lib/rmtfs
#   pd-mapper.service   -> ExecStart=/usr/bin/pd-mapper
#   tqftpserv.service   -> ExecStart=/usr/bin/tqftpserv
# A literal "/usr/local/bin/..." means prefix=/usr was not applied.

# 6. No stray /usr/local paths anywhere in the package.
grep -rl '/usr/local' . && echo 'FAIL: /usr/local leaked' || echo 'OK'

# 7. udev rule present and correct.
cat usr/lib/udev/rules.d/rmtfs.rules
#   ACTION=="add", KERNEL=="qcom_rmtfs_mem*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="rmtfs.service"

# 8. Strings sanity: confirm the QRTR service ids the daemons will publish.
LC_ALL=C strings usr/bin/pd-mapper | grep -iE 'servreg|servreg_loc|/lib/firmware|updates'
LC_ALL=C strings usr/bin/rmtfs     | grep -iE 'qcom_rmtfs_mem|/dev/|rmtfs'
```

### 4.2 Runtime symptoms if a daemon is missing (on the device)

| Missing daemon | Observable symptom |
|---|---|
| **`rmtfs`** | Modem (MPSS) cannot read/write its EFS/persist storage. `rmtfs.service` is inert anyway without `/dev/qcom_rmtfs_mem1` — check `ls /dev/qcom_rmtfs_mem*` first (the node comes from the built-in `CONFIG_QCOM_RMTFS_MEM=y`). The modem remoteproc will crash or fail to complete boot with `qcom_q6v5_pas … modem` errors in `dmesg`; `qcom_q6v5_mss` reports a fatal/stop-ack. Calls and mobile data never come up. If rmtfs is absent you also typically see the modem fall over repeatedly (`Restart`/PDR loops). |
| **`pd-mapper`** (and kernel driver not binding either) | Subsystems that look up a *protection domain* by name via `servreg_loc` (QRTR service **64**) cannot resolve it. On sm8150 the kernel driver's table covers `adsp_audio_pd`, `adsp_root_pd`, `cdsp_root_pd`, `mpss_root_pd_gps`, `mpss_wlan_pd`. **Audio (ADSP) and Wi-Fi/WLAN** are the visible casualties: `q6afe`/`q6asm` fail to probe so no sound card appears (`aplay -l` empty), and the WLAN domain never comes up so `ath10k_snoc` fails to start. Log lines to look for: `PDM: no support for the platform, userspace daemon might be required.` and `qcom_pd_mapper` init failures in `dmesg`; on the userspace side, pd-mapper exiting immediately. |
| **`tqftpserv`** | The modem's own TFTP client cannot fetch files. Because the Hexagon modem requests firmware/EFS content over TFTP at boot, the modem will stall partway through bring-up. Look for the daemon's log lines (`[TQFTP] RRQ: /readonly/firmware/image/…`) *not* appearing while the modem is booting, and modem PDR/crash loops. |
| **`hexagonrpcd`** | Only FastRPC-fileserving and CHRE (sensors) are affected. Audio, Wi-Fi, BT and modem are unaffected. Symptom: `/dev/fastrpc-sdsp` exists but nothing serves it; sensor/CHRE clients on the ADSP/SLPI fail. |
| **`qrtr` (libqrtr)** | *Everything* above fails to build. At runtime, `ip` will not show the qrtr links; the `qrtr` netlink family (`AF_QIPCRTR`) has no userspace clients, so nothing can bind service 64 or serve TFTP — i.e. you get the union of all the rows above. |

Diagnostic commands on the device (Linux-msm `qrtr` package):

```bash
modprobe qrtr qrtr-smd                      # CONFIG_QRTR=m / CONFIG_QRTR_SMD=m
qrtr-lookup                                 # dump the QRTR service table
qrtr-lookup | grep -iE 'servreg|tftp|rmtfs'  # expect service 64 for servreg_loc
systemctl status rmtfs tqftpserv pd-mapper
ls -l /dev/qcom_rmtfs_mem* /dev/fastrpc-*
dmesg | grep -iE 'qcom_pd_mapper|PDM|q6v5|rmtfs|fastrpc|ath10k'
```

---

## 5. Which daemons must run for which subsystem

Ordered by how much you lose if they are absent. "Kernel" means the
corresponding driver is already in the shipped 7.2.0 config (§0.1).

### 5.1 Wi-Fi — ath10k WCN3990 (`wifi@18800000`, `qcom,wcn3990-wifi`)

| Component | Required? |
|---|---|
| Kernel `ath10k` + `ath10k_snoc` (`=m`) | **Yes** |
| Firmware `/lib/firmware/ath10k/WCN3990/hw1.0/{firmware-5.bin,board-2.bin}` (+ zstd `.zst` variants) | **Yes** — from ALARM `linux-firmware-atheros`; note the device package ships them `.zst`-compressed, so `CONFIG_FW_LOADER_COMPRESS_ZSTD` must be on |
| `qcom/sm8150/Xiaomi/raphael/wlanmdsp.mbn` | **Yes** — device-specific, **not in `linux-firmware`** |
| `servreg_loc` provider for **`mpss_wlan_pd`** | **Yes.** WLAN on SM8150 is a protection domain of the modem; the mapping is what tells the WLAN subsystem where `mpss_wlan_pd` lives. Provided by the **kernel** `qcom_pd_mapper` (its `sm8150_domains` explicitly contains `mpss_wlan_pd`) or by the userspace `pd-mapper`. |
| `rmtfs` | **No** — rmtfs is the modem's EFS/persist store, unrelated to WLAN firmware |
| `tqftpserv` | **No** — this is not how ath10k fetches WCN3990 firmware |
| `hexagonrpcd` | **No** |

So Wi-Fi depends on **a working `servreg_loc` provider** (kernel or userspace
`pd-mapper`) plus firmware — **not** on rmtfs or tqftpserv.

### 5.2 Bluetooth — WCN3998 over GENI UART (`qcom,wcn3998-bt`)

| Component | Required? |
|---|---|
| Kernel `bluetooth` + `hci_uart`/`hci_qca` (`CONFIG_BT_QCOMSMD=m`, `CONFIG_BT_HCIUART=m`) | **Yes** |
| Firmware `/lib/firmware/qca/crnv21.bin` (`.zst`) | **Yes** — from ALARM `linux-firmware` |
| `rmtfs`, `pd-mapper`, `tqftpserv`, `hexagonrpcd` | **No** — BT is brought up entirely by `hci_qca` over the UART, with no QRTR/EFS involvement |

Bluetooth is the subsystem **least** dependent on the Qualcomm userspace
daemons: none of them are needed. (Contrast the Debian sibling's README, which
lists Bluetooth as working — consistent with the fact that it installs only
three daemons and BT needs none of them specifically.)

Note the device package contains only `crnv21.bin`; the RAM patch
(`crbtfw21.tlv`-class file) is requested by the `qcom,wcn3998-bt` binding. If BT
fails to initialise, check for a missing patch file before blaming a daemon —
this is **UNVERIFIED** here (I did not enumerate the full ALARM
`linux-firmware-broadcom`/`qca` split contents).

### 5.3 Audio via the ADSP (`apr` → `q6core`/`q6afe`/`q6asm`/`q6adm`)

| Component | Required? |
|---|---|
| Kernel `qcom_q6v5_pas` (ADSP) + `snd-soc-qcom-common` + `q6afe`/`q6asm`/`q6adm`/`q6apm`/`q6routing`/`q6core` (all `=m`) | **Yes** |
| Firmware `qcom/sm8150/Xiaomi/raphael/adsp.mbn` (+ `adspr.jsn`, `adsps.jsn`, `adspua.jsn`) | **Yes** — device-specific |
| `servreg_loc` provider for **`adsp_audio_pd`** and **`adsp_root_pd`** | **Yes** — the ADSP's audio services are protection domains; both are in the kernel driver's sm8150 table |
| `rmtfs` | **No** for audio itself (the ADSP does not use `/dev/qcom_rmtfs_mem*`) |
| `tqftpserv` | **No** for audio; it targets the modem |
| ALSA UCM (`alsa-ucm-conf`, extra ✓) + the device's `sm8150_raphael` UCM | **Yes for a usable sound card** — the sibling project ships `alsa.deb` containing `/usr/share/alsa/ucm2/conf.d/sm8150_raphael/{sm8150_raphael.conf,HiFi.conf,xiaomi-XiaomiRedmiK20Pro.conf}` and `/usr/share/alsa/ucm2/Raphael/` |
| `hexagonrpcd` | **No** for plain audio playback |

Audio therefore needs **the ADSP to boot** and **`adsp_audio_pd`/`adsp_root_pd`
to resolve** — i.e. a `servreg_loc` provider — plus `alsa-ucm-conf` and the
device UCM. Not rmtfs, not tqftpserv.

The sibling project's only audio tuning is a WirePlumber drop-in
(`/etc/wireplumber/wireplumber.conf.d/51-disable-suspension.conf`, see
`_recon/upstream-scripts/scripts/16-config-audio.sh`) forcing S16LE/48 kHz with
`api.alsa.period-size = 4096`, `period-num = 6`, `headroom = 512`; that is a
userspace workaround and is independent of the daemons.

### 5.4 Modem / calls / data (MPSS, `qcom,sm8150-mpss-pas`)

| Component | Required? |
|---|---|
| Kernel `qcom_q6v5_mss` + `qcom_q6v5_pas` (`=m`) | **Yes** |
| Firmware `qcom/sm8150/Xiaomi/raphael/modem.mbn` + `modem_pr/mcfg/configs/.../mcfg_hw.mbn` + `modemr.jsn`/`modemuw.jsn` | **Yes** — device-specific, includes per-carrier MCFG configs (the package carries `cmcc_sub` and `la` variants) |
| **`rmtfs`** | **Yes** — the modem's EFS/persist filesystem. Needs `/dev/qcom_rmtfs_mem1` (`CONFIG_QCOM_RMTFS_MEM=y`) and the `rmtfs.rules` udev trigger |
| **`tqftpserv`** | **Yes** — the modem is the TFTP *client*; it requests `/readonly/firmware/image/...` at boot and writes `/readwrite/server_check.txt` etc. Its README documents exactly these modem-boot requests |
| `servreg_loc` provider for **`mpss_root_pd_gps`** | **Yes** — in the kernel driver's sm8150 table, so the kernel path suffices |
| `pd-mapper` | **Yes in one form or another** — the modem's subsystems resolve PDs via QRTR service 64; either the kernel `qcom_pd_mapper` or the userspace daemon must own it (§0.3) |
| `hexagonrpcd` | **No** |

The sibling project's README marks **cellular as ❌ unsupported** even though it
installs all three daemons — so on this device the modem stack is *not* expected
to give working calls/data, and the daemons being present is necessary but not
sufficient (the userspace data stack — ModemManager/libqmi — is absent from that
image). Do not treat "modem works" as a success criterion for this bring-up.

### 5.5 Sensors

| Component | Required? |
|---|---|
| Kernel SLPI remoteproc (`qcom,sm8150-slpi-pas`, `slpi.mbn`) | **Yes** — SLPI is the sensor low-power island |
| Firmware `qcom/sm8150/Xiaomi/raphael/slpi.mbn` + `slpir.jsn`/`slpius.jsn` | **Yes** — device-specific |
| **`hexagonrpcd`** (`hexagonrpcd-sdsp.service` on this device) | **Likely yes** for CHRE/FastRPC-based sensors. Its README states FastRPC is how the AP talks to CHRE, "a program on the DSP that manages sensors" |
| `pd-mapper` beyond the kernel's table | **Possibly** — see the caveat below |
| `iio-sensor-proxy` | Needed for a desktop to consume IIO sensors, but that is a userspace consumer, not a Qualcomm daemon |
| `rmtfs`, `tqftpserv` | **No** |

**Caveat, and it is a real one:** the kernel `qcom_pd_mapper`'s `sm8150_domains`
table contains **no SLPI entries** (unlike `sm8250_domains`, which has
`slpi_root_pd` and `slpi_sensor_pd`), and no `adsp_sensor_pd` either (present
for `sm7150` and `sm8550`). Yet the device firmware **does** ship `slpir.jsn`
and `slpius.jsn`. So if the SLPI needs its root/sensor PD published via
`servreg_loc`, only the **userspace** `pd-mapper` can do it — and it cannot do so
while the kernel driver owns service 64. Resolving this properly is
**UNVERIFIED** and is the single most important thing to test on hardware:

```bash
# on the device
dmesg | grep -i 'PDM'            # "no support for the platform" => kernel did NOT take over
qrtr-lookup | grep -i servreg    # who owns service 64?
cat /sys/bus/auxiliary/devices/qcom_common.pd-mapper*/uevent 2>/dev/null
systemctl status pd-mapper
```

If sensors turn out to need the userspace mapper, the clean fix is to build the
kernel with `# CONFIG_QCOM_PD_MAPPER is not set` (or blacklist
`qcom_pd_mapper`) so the userspace daemon can own service 64 uncontested.

### 5.6 Summary matrix

| Subsystem | rmtfs | pd-mapper (kernel or user) | tqftpserv | hexagonrpcd | qrtr/libqrtr |
|---|---|---|---|---|---|
| Wi-Fi (WCN3990) | — | **required** (for `mpss_wlan_pd`) | — | — | required (mechanism) |
| Bluetooth (WCN3998) | — | — | — | — | — |
| Audio (ADSP) | — | **required** (for `adsp_audio_pd`, `adsp_root_pd`) | — | — | required (mechanism) |
| Modem / calls / data | **required** | **required** | **required** | — | required (mechanism) |
| Sensors (SLPI) | — | likely required (see §5.5) | — | likely required | required (mechanism) |

`qrtr`/`libqrtr` is listed as "mechanism" because it is a *library* plus two
diagnostic binaries — it is not a service, but every row that needs a QRTR
service transitively needs it to be installed.

---

## 6. Citations

Upstream projects (all `linux-msm`):

* <https://github.com/linux-msm/qrtr> — `meson.build`, `lib/meson.build`, `src/meson.build`, `ci/archlinux.sh`, tag `v1.2` tree vs. `master` tree
* <https://github.com/linux-msm/rmtfs> — `Makefile`, `rmtfs.service.in`, `rmtfs-dir.service.in`, `rmtfs.rules`
* <https://github.com/linux-msm/pd-mapper> — `Makefile`, `pd-mapper.service.in`, `pd-mapper.c:422`, `servreg_loc.h:9`
* <https://github.com/linux-msm/tqftpserv> — `README.md`, `meson.build`, `meson_options.txt`, `tqftpserv.service.in`, `tqftpserv-populate-readwrite.service.in`
* <https://github.com/linux-msm/qbootctl> — `meson.build`, `README.md`
* <https://github.com/linux-msm/hexagonrpc> — `README.md`, `meson.build`, `meson.options`, `hexagonrpcd/meson.build`, `libhexagonrpc/meson.build`, `chrecd/meson.build`, `data/meson.build`, `data/hexagonrpcd-*.service.in`, `tools/meson.build`, `tests/meson.build`

Linux kernel (instantiation of the in-kernel PD mapper and the QRTR nameservice):

* <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/soc/qcom/qcom_pd_mapper.c> — `qcom_pdm_start()`, `of_machine_get_match()`, `qmi_add_server(QMI_SERVICE_ID_SERVREG_LOC)`, `sm8150_domains[]`
* <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/remoteproc/qcom_common.c> — `pdm_notify_prepare()`, auxiliary device `"pd-mapper"`
* <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/drivers/remoteproc/qcom_q6v5_pas.c> — `qcom_add_pdm_subdev()` at line 918
* <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/linux/soc/qcom/qmi.h> — `QMI_SERVICE_ID_SERVREG_LOC 0x40 /* 64 */`
* <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/net/qrtr/ns.c> — kernel QRTR name service

Debian packaging (source of the packaging conventions and the legacy `sed`):

* <https://sources.debian.org/src/protection-domain-mapper/> — versions 1.0-4 / 1.0-7 (trixie) / 1.1-1 (forky, sid); `debian/rules`, `debian/patches/0001-pd-mapper-lookup-firmware-files-under-lib-firmware-u.patch`, `debian/changelog` ("The QRTR nameserver has been built into the kernel for years now")
* <https://sources.debian.org/src/rmtfs/> — 1.3-1; `debian/rules` (`RMTFS_BUILD_OPTS=prefix=/usr`, `dh_installsystemd --name rmtfs-dir --no-start --no-enable`)
* <https://sources.debian.org/src/tqftpserv/> — 1.2-1
* <https://sources.debian.org/src/qrtr/> — 1.2-1 (retains `qrtr-ns.service.in`, removed upstream)
* <https://packages.debian.org/search?keywords=msm-modem-uim-selection> — "Sorry, your search gave no results" (all suites, all architectures)

Sibling project (the working Debian/Ubuntu image for this device):

* <https://github.com/Winter21c/linux-xiaomi-raphael-uboot> — `README.md`, `scripts/06-install-all-packages.sh` (`DEVICE_PACKAGES="rmtfs protection-domain-mapper tqftpserv"`, the `ConditionKernelVersion` sed), `scripts/16-config-audio.sh`

ALARM package databases (local, authoritative for this document):

* `/tmp/alarm-core.db`, `/tmp/alarm-extra.db` — 313 + 12 943 packages; per-package `desc` + `depends` (the `depends` file carries `%DEPENDS%`/`%PROVIDES%`/`%OPTDEPENDS%` markers)

Local device artefacts (in `_recon/`):

* `_recon/dl/x-image/boot/config-7.2.0-sm8150-g29662fdcefa9` — kernel config
* `_recon/dl/x-image/boot/dtbs/qcom/sm8150-xiaomi-raphael.dtb` — decompiled with `dtc` to `/tmp/raphael.dts`
* `_recon/dl/x-image/lib/modules/7.2.0-sm8150-g29662fdcefa9/` — `qcom_pd_mapper.ko`, `qrtr.ko`, `fastrpc.ko`, `qcom_common.ko`
* `_recon/dl/firmware.deb` — 907 firmware entries (extracted via `ar x` + `tar --zstd -tf`)
* `_recon/dl/alsa.deb` — `sm8150_raphael` / `Raphael` ALSA UCM profiles

---

## 7. Summary

| Daemon | Needed on raphael? | Recommended build path | PKGBUILD |
|---|---|---|---|
| **`qrtr`** (libqrtr, `qrtr-lookup`, `qrtr-cfg`) | **Yes — mandatory.** The only dependency with no ALARM package (`libqrtr-glib` is a different, glib-based library) | meson; **native in emulated aarch64 rootfs** (§2.2); cross-compile via §2.3 as a speed-up | [pkgs/qrtr/PKGBUILD](raphael-arch/pkgs/qrtr/PKGBUILD) |
| **`rmtfs`** | **Yes** — modem EFS/persist | plain `make prefix=/usr RMTFS_EFS_PATH=/var/lib/rmtfs`; native in emulated rootfs | [pkgs/rmtfs/PKGBUILD](raphael-arch/pkgs/rmtfs/PKGBUILD) |
| **`pd-mapper`** | **Yes, but the kernel also provides it** — install for parity with the working Debian image; the kernel `qcom_pd_mapper.ko` claims the same QRTR service 64 on `qcom,sm8150`. Verify on device | plain `make prefix=/usr`; native in emulated rootfs | [pkgs/pd-mapper/PKGBUILD](raphael-arch/pkgs/pd-mapper/PKGBUILD) |
| **`tqftpserv`** | **Yes** — the modem is the TFTP client and fetches firmware/files at boot | meson; native in emulated rootfs | [pkgs/tqftpserv/PKGBUILD](raphael-arch/pkgs/tqftpserv/PKGBUILD) |
| **`qbootctl`** | **Optional** — A/B slot CLI, nothing in the boot path needs it | meson; native in emulated rootfs | [pkgs/qbootctl/PKGBUILD](raphael-arch/pkgs/qbootctl/PKGBUILD) |
| **`hexagonrpc`** (`hexagonrpcd`) | **Optional** — sensors/CHRE and FastRPC fileserving only. Enable `hexagonrpcd-sdsp.service` (not the `adsp-*` units) | meson; native in emulated rootfs | [pkgs/hexagonrpc/PKGBUILD](raphael-arch/pkgs/hexagonrpc/PKGBUILD) |
| `qrtr-ns` | **No — obsolete.** Name service is in `qrtr.ko`; deleted from upstream master | — | — |
| `msm-modem-uim-selection` | **No** — not in Debian, not installed by the working sibling, upstream UNVERIFIED | — | — |

**Build path recommendation in one line:** build all of them natively inside the
extracted aarch64 rootfs using `unshare -r -m` + `qemu-aarch64 -L <rootfs>`
(§2.2) — it is the only path verified end-to-end on this host and it needs no
root, no `pkexec`, and no fakeroot.
