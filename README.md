# Arch Linux ARM for 红米 K20 Pro (raphael / SM8150) + KDE Plasma Mobile

[![构建镜像](https://github.com/Winter21c/archlinux-xiaomi-raphael/actions/workflows/build.yml/badge.svg)](https://github.com/Winter21c/archlinux-xiaomi-raphael/actions/workflows/build.yml)

给 **Xiaomi Redmi K20 Pro / K20 Pro 尊享版 / Mi 9T Pro** 的 Arch Linux ARM (aarch64) 系统镜像，
使用 [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)
的 U-Boot + 定制内核，桌面为 **KDE Plasma 6 + Plasma Mobile**（两个会话可切换）。

上游项目只做 Debian/Ubuntu，本仓库把它移植到 Arch，并把桌面换成 KDE。
**不想本地搭环境？** 仓库自带 GitHub Actions 工作流，云端直接出镜像 —— 见 [§7.1](#71-线上编译github-actions)。

---

## 1. 产物（`out/`）

| 文件 | 大小 | 说明 |
|:--|:--|:--|
| `boot-cache.img` | 256 MiB | FAT32，刷入 **cache** 分区：systemd-boot + 内核 `linux.efi` + `initramfs` + dtb + 3 个启动项 |
| `rootfs.img` | 8 GiB | **btrfs**（默认，见 §1.1），刷入 **userdata** 分区；首启动自动扩容到分区实际大小 |
| `rootfs.sparse.img` | ~6 GiB | 上面的 sparse 版本，`fastboot` 刷写更快（推荐） |

引导链：

```
U-Boot (boot 分区)
  └─ \EFI\BOOT\BOOTAA64.EFI   (systemd-boot)
       └─ loader/entries/arch.conf
            ├─ linux.efi      (内核 Image, EFI stub)
            ├─ initramfs      (极简 initramfs, 挂载失败给救援 shell)
            └─ root=UUID=18d619c3-d55a-4004-b57a-4509becb29c6  → userdata 分区
```

三个启动项：`arch.conf`（正常）、`arch-direct.conf`（不用 initramfs，内核直接挂载根分区，
initramfs 出问题时的救命项）、`arch-debug.conf`（loglevel=7）。

### 1.1 根文件系统：btrfs（透明压缩 + 子卷）

参考 [Shorin 的 ArchLinux 安装指南](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide)
手动安装一节的做法：`mkfs.btrfs` → 建 `@` / `@home` 子卷 → `subvol=/@,compress=zstd` 挂载。

```
/mnt  fstab 形式 (PARTLABEL 定位)
  PARTLABEL=userdata  /      btrfs  rw,subvol=/@,compress=zstd:3,noatime,ssd,discard=async,space_cache=v2,x-systemd.growfs  0 1
  PARTLABEL=userdata  /home  btrfs  rw,subvol=/@home,compress=zstd:3,noatime,ssd,discard=async,space_cache=v2               0 2
  PARTLABEL=cache     /boot  vfat   umask=0077,nofail,noatime                                                              0 2
```

内核（作者预编译的 7.2 内核）**内建 btrfs**（`modinfo btrfs` → `(builtin)`），
initramfs 里的 busybox `findfs` 也认得 btrfs，所以启动链路不需要额外模块。

**关于子卷的一个硬约束**：创建子卷必须**挂载**文件系统，而挂载块设备需要 root。
本项目的构建设计是「不要 root」，所以：

| 构建环境 | 布局 | 说明 |
|:--|:--|:--|
| 有 root（GitHub Actions、或本机 `sudo`） | **`@` + `@home`** | 完整 Shorin 布局；`@` 同时被设为默认子卷 |
| 无 root（本机无 sudo） | **单子卷 btrfs** | 数据在 btrfs 顶层，**透明压缩等特性照旧** |

两种布局都通过 `scripts/lib.sh` 的 `rootfs_layout()` 统一判定，并把结果写进
`work/rootfs-layout`，**fstab / initramfs / 引导参数一定与镜像实际布局一致** ——
不会出现"引导参数写 `subvol=/@` 但镜像里没有 `@`"这种起不来的情况。
强制指定可用 `RAPHAEL_FORCE_LAYOUT=btrfs-subvol|btrfs-flat|ext4`。

透明压缩默认 `zstd:3`（可用 `RAPHAEL_BTRFS_COMPRESS` 调，如 `zstd:1` 省 CPU）；
`x-systemd.growfs` 首启动把 btrfs 撑满 userdata 分区（systemd 的 growfs 原生支持 btrfs，
兜底脚本也会按 `blkid` 识别的文件系统类型分别调用 `btrfs filesystem resize` / `resize2fs`）。

---

## 2. 刷机

**前置条件**

- Bootloader 已解锁（只有 root 不够）
- 电脑有 `adb` / `fastboot`（Arch: `sudo pacman -S android-tools`）
- 接受 **userdata 分区被清空**（Android 系统与数据全部消失）

**建议先备份 boot / dtbo**（可选，用上游一键包里的 TWRP）：

```bash
cd raphael-arch
cp <上游一键安装包>/twrp-3.7.1_12-1-raphael.img dl/
./scripts/11-flash.sh --backup     # 手机关机后按住 音量- + 电源 进 fastboot
```

**刷入**

```bash
./scripts/11-flash.sh --dry-run    # 先看命令
./scripts/11-flash.sh --flash      # 真正刷入（会二次确认）
```

等价的手工命令：

```bash
fastboot erase dtbo
fastboot erase boot
fastboot erase cache
fastboot erase userdata
fastboot flash boot     work/uboot/u-boot.img      # U-Boot
fastboot flash cache    out/boot-cache.img         # systemd-boot + 内核
fastboot flash userdata out/rootfs.sparse.img      # Arch rootfs
fastboot reboot
```

**刷完第一次开机**

1. 屏幕亮起 → U-Boot 菜单（3 秒倒计时，默认第一项）→ systemd-boot → 内核
2. 首启动会自动：扩容根分区到 userdata 全尺寸 / 初始化 pacman 密钥环 / 修正家目录属主
3. 自动登录到 **Plasma Mobile**（用户 `winter`，密码 `1234`；`root` 密码 `1234`）

**改密码**：`passwd` / `sudo passwd root`（默认 1234 是为了锁屏能用数字键盘解开）。

---

## 3. 硬件支持

| 硬件 | 状态 | 说明 |
|:--|:--:|:--|
| 屏幕 (三星 AMOLED 1080×2340) | ✅ | 主线 panel 驱动 `samsung,ams639rq08` |
| 触摸 (Goodix GT9886) | ✅ | 靠作者内核里的 `goodix_gtx8` 驱动（主线没有 gt9886，只有这套定制内核能点亮触摸） |
| GPU (Adreno 640, freedreno) | ✅ | `qcom/a640_gmu.bin` + `qcom/a630_sqe.fw`（A640 与 A630 共用 SQE） |
| Wi-Fi (WCN3990, ath10k_snoc) | ✅ | 网卡名是 **`wld0`**（systemd 改名，不是 wlan0）。需要 `skip_otp=y` + **tqftpserv 必须运行**（见 §8.1）；真机已实测扫描到 AP |
| 蓝牙 (WCN3998, hci_qca) | ✅ | **已修好**：真机实测扫描到 9 个设备、可 `powered`。需要**修补设备树**（补 `local-bd-address`）+ **机器自带的原厂 NVM**（`bluetooth` 分区里的 `crnv21.bin`），两者缺一不可 —— 详见 §8.9 |
| 音频输出 (ADSP + UCM) | ✅ | 声卡 `card 0: Raphael`；UCM 提供 `Speaker (TFA9874)` 与 `Headphone (WCD9340)` 两个输出；已实测 440Hz 播放正常。依赖 rmtfs + tqftpserv + 内核 pd-mapper |
| 麦克风 | ⚠️ | 采集链路已修到**全部上电**（`AMIC MUX0` 默认断开 + 设备树缺 MCLK 路由，两处已修），但样本仍为全零，还差最后一层（DSP/ADM 或模拟前端）。详见 §8.10 与 [notes/microphone-and-kernel-plan.md](notes/microphone-and-kernel-plan.md) |
| 电池 / 充电 / RTC | ✅ | 内核内建 |
| USB (dwc3, OTG) | ✅ | 含 **USB NCM 网络共享**：插电脑后设备是 `172.16.42.1`，可 `ssh winter@172.16.42.1` |
| 手电筒 / 振动 | ⚠️ | 未验证 |
| 传感器 (SLPI) | ⚠️ | DTS 里没有加速度计节点 → **没有自动旋转**；传感器需要 `hexagonrpcd`（本次未内置） |
| 调制解调器（通话/流量） | ⚠️ | 上游状态：联通/电信可用，移动在修；旧内核有"插 SIM 卡开机卡死"的报告（7.1+ 已改善，7.2 待你实测） |
| **闪光灯 / 手电筒** | ✅ | `&pm8150l_flash` 设备树节点已就绪 + `leds-qcom-flash` 模块 → `shoudian on/off/toggle` |
| **USB 摄像头** | ✅ | 内核带 `uvcvideo`，插 USB-C 摄像头/采集卡即可（KDE 里用 plasma-camera / VLC） |
| 摄像头（内置 4 摄） | ❌ | 主线**没有** sm8150 的 CAMSS/CCI 设备树与驱动，也**没有** IMX586 等 sensor 驱动 —— 详见 [notes/camera.md](notes/camera.md)（含可行路线与"为什么不能搬安卓相机栈"） |
| 视频硬解 (Venus) | ⚠️ | 内核有 `venus-*.ko`，但设备树里没有 venus 节点，目前只能软解 |
| 挂起/休眠 | ❌ | SM8150 只有 s2idle，已 mask 掉 sleep/suspend/hibernate（长按电源键关机，短按熄屏） |

> **尊享版注意**：尊享版 (raphaelin) 与标准版共用同一套 raphael 设备树。绝大多数硬件一致，
> 但如果你遇到屏幕/触摸异常，那是第一个要怀疑的点（需要单独加 raphaelin DTS）。

---

## 4. 桌面

- 登录界面是 SDDM（Wayland 模式），自动登录到 **Plasma Mobile**（`startplasmamobile`）
- 想用 **Plasma 桌面**：注销后（或开机时按住）在 SDDM 会话菜单里选 *Plasma (Wayland)*；
  也可以改 `/etc/sddm.conf.d/10-raphael.conf` 的 `[Autologin] Session=plasma`
- 虚拟键盘：`plasma-keyboard`（桌面会话已开启"非鼠标输入时弹出"）
- 密码键盘/中文：`noto-fonts-cjk` + `adobe-source-han-sans-cn-fonts` + 字体优先级已配好；
  SSH 会话自动切中文（`/etc/profile.d/99-locale-fix.sh`）
- 熄屏/亮屏快捷命令（KDE 版）：`leijun`（熄屏） / `jinfan`（亮屏）
- 相机相关工具：`shoudian on|off|toggle`（手电筒，KDE 菜单里也有「手电筒」）、
  `camera-check`（一条命令诊断相机卡在哪一层：内核驱动/设备树/CCI 总线/V4L2/闪光灯/USB 摄像头）
- **应用在哪**：Plasma Mobile 是手机形态，主屏只放收藏夹，**从屏幕底部上滑**打开应用抽屉
  （Konsole 终端、系统设置、Dolphin 文件管理器、Kate、Okular、Spectacle 等都预装了，共 190+ 个应用）。
  想要传统桌面（底部任务栏 + 开始菜单）就在 SDDM 里选 **Plasma (Wayland)** 会话
  （注销后选择即可，SDDM 会记住上次的选择）。
- **中文输入法**：已装 `fcitx5 + fcitx5-rime + fcitx5-chinese-addons`（和 Shorin 指南同一套），
  环境变量写在 `/etc/environment`，Rime 配置在 `~/.local/share/fcitx5/rime/`。
  外接键盘用 `Ctrl+Space` 切中英；触摸屏用屏幕键盘（plasma-keyboard）。
- **锁屏/PIN**：默认**不锁屏**（`~/.config/kscreenlockerrc` 里 `Autolock=false`），
  所以不存在"锁了以后解不开"的问题。密码 `1234` 只用于 `sudo` 和 SSH。
- **装软件**：已加 archlinuxcn 源（含密钥环）并预装 `paru`，联网后直接
  `paru -S 包名`（AUR）/ `sudo pacman -S 包名`（官方仓库）。
  > ⚠️ 作者内核**没有编 Landlock**，而 pacman 7.1 默认用它做下载沙箱 —— 镜像里已经
  > 预先关掉（`/etc/pacman.conf` 的 `DisableSandboxFilesystem`/`DisableSandboxSyscalls`），
  > 否则 `pacman -Sy` 会直接报错、连软件都装不了。
- 电源键：默认交给 PowerDevil（短按切换屏幕）。若没反应：
  `sudo systemctl enable --now raphael-power-key`（自定义守护：短按熄屏，长按 1.5 秒关机），
  并把 `~/.config/powerdevilrc` 的 `PowerButtonAction=128` 改成 `0` 避免重复触发。

---

## 5. 目录结构

```
raphael-arch/
├── build.sh                 # 总入口: ./build.sh [--from 03] [--only 06 07] [--list]
├── config/build.conf        # 全部可调参数: 镜像大小/用户名/密码/包列表/内核版本
├── scripts/
│   ├── lib.sh               # 公共函数 (userns 自举 / qemu 垫片 / mtools / systemd 单元启停)
│   ├── 00-fetch.sh          # 下载 rootfs、内核 deb、固件、U-Boot、FAT 模板
│   ├── 01-rootfs.sh         # 解包 Arch Linux ARM rootfs (在 userns 内, 保留 setuid 位)
│   ├── 02-pacman.sh         # 用宿主 pacman 往 aarch64 rootfs 装包 (--arch aarch64)
│   ├── 03-kernel.sh         # 安装作者定制内核 (Image + 957 个模块 + dtb)
│   ├── 04-firmware.sh       # 设备固件 + ALSA UCM + 精简无关固件 + 解决同名覆盖
│   ├── 05-qcom.sh           # 交叉编译 qrtr/rmtfs/pd-mapper/tqftpserv
│   ├── 06-config.sh         # locale/fstab/用户/NCM 网络/电源/zram/服务
│   ├── 07-desktop.sh        # Plasma + Plasma Mobile 会话配置
│   ├── 08-initramfs.sh      # 手工组装 initramfs (静态 busybox)
│   ├── 09-image-rootfs.sh   # mke2fs -d → rootfs.img (+ sparse)
│   ├── 10-image-boot.sh     # mtools 写 FAT → boot-cache.img
│   └── 11-flash.sh          # 备份 / 刷机
├── notes/                   # 深度调研报告 (相机 / 移植清单 / Plasma Mobile / Qualcomm 用户态)
├── pkgs/                    # 6 个 PKGBUILD (qrtr/rmtfs/pd-mapper/tqftpserv/qbootctl/hexagonrpc)
└── out/                     # 产物
```

## 6. 发布自己的镜像（可选）

```bash
./scripts/99-make-release.sh v1.0.0            # 压缩+分卷+生成校验和与刷机说明
./scripts/99-make-release.sh v1.0.0 --upload   # 直接发布到本仓库的 Release
```

GitHub Release 单个文件上限 2 GB，而 rootfs 有 6 GB 左右，脚本会自动用 zstd 压缩并把大文件切成
`*.part00`/`*.part01`…，同时生成 `SHA256SUMS` 和一份给下载者的《刷机说明.txt》。

## 7. 重新构建

```bash
./build.sh                 # 全流程（首次约 40-60 分钟，主要是下载）
./build.sh --from 09       # 只重新打包镜像（改了配置后最常用）
./build.sh --only 06 09 10 # 只跑指定阶段
```

**不需要 root**。原理：

- 整个构建跑在 `unshare -r -m -p` 的 **user namespace** 里，在里面是"假 root"：
  可以解包 rootfs（保留 setuid 位）、bind mount、写 `/proc`、执行 `mke2fs -d` 让镜像里的文件属主是 uid 0
- 宿主 systemd 把 `/proc` `/sys` `/dev` 标记为 locked mount，非特权 userns 无法 bind —— 所以
  `/proc` 用 `unshare --mount-proc` 提供，`/dev` 里的设备节点逐个 bind
- aarch64 程序用**宿主 x86_64 的 qemu-user + 显式动态加载器**在 chroot 内执行
  （本机没有 `binfmt_misc`，qemu 无法执行子进程，所以只用来跑单条命令：
  `systemctl enable`、`ldconfig`、`fc-cache`、`locale-gen` …）
- 装包用**宿主 pacman** `--arch aarch64 -r <rootfs> --noscriptlet`，
  之后用 qemu 补跑关键 scriptlet（ldconfig / sysusers / 字体与 schema 缓存）
- `rmtfs`/`pd-mapper`/`tqftpserv`/`qrtr` 用 **clang 交叉编译**
  （`--target=aarch64-linux-gnu --sysroot=<rootfs>` + ALARM gcc 包的 crt/libgcc）
- FAT 镜像用从 Arch x86_64 仓库取来的 **mtools** 直接读写，无需 mount

如果你愿意装一次 `qemu-user-binfmt`（`sudo pacman -S qemu-user-binfmt && sudo systemctl restart systemd-binfmt`），
构建会更快、也能跑完整 scriptlet —— 但不是必需的。

### 7.1 线上编译（GitHub Actions）

仓库自带 [`.github/workflows/build.yml`](.github/workflows/build.yml)，不用本地环境也能出镜像：

- **手动触发**：Actions → 「构建镜像」→ *Run workflow*
  - `stages` 留空 = 完整 `00 → 10`；填 `09 10` 就只重打包镜像
  - `upload_rootfs` 勾上才会额外上传 rootfs 发布包（zstd 分卷，约 2-3 GB）
- **自动触发**：改动 `scripts/` `config/` `dtb/` `build.sh` 后 push 到 `main` 会自动跑一次
- **产物**：`boot-cache-image`（引导镜像 + 校验和 + 刷机说明，约 256 MB，保留 30 天）；
  勾选后另有 `rootfs-release`（保留 14 天）。**不会**自动发到 Releases
- 构建约 30-60 分钟；`dl/` 与 pacman 包缓存有缓存，第二次会快很多

几个关键的 CI 设计点（照抄时注意）：

| 点 | 原因 |
|:--|:--|
| 用 `archlinux:latest` **容器**，不是 ubuntu runner | 构建脚本依赖**宿主 pacman**（`--arch aarch64` 离线装包），Ubuntu 上跑不了 |
| `options: --privileged` | 脚本在 user namespace 里 `unshare -m -p` + bind mount 出 chroot，Docker 默认 seccomp 会拦掉 |
| `-v /mnt:/mnt` + 把 `dl/ work/ out/` 软链过去 | runner 的 `/` 只有 ~14 GB，而 rootfs 镜像本身 8 GB；大磁盘挂在宿主 `/mnt`（≈74 GB），容器默认看不到 |
| 先装 `archlinux-keyring` 再 `pacman -Syu` | 官方 Arch 镜像可能过期，直接 `-Syu` 会因 keyring 太旧失败 |
| `qemu-user` 装了兜底 | 个别镜像里包名不同（`qemu-emulators-full`）；脚本用 `qemu-aarch64` 跑 chroot 内的 aarch64 命令 |

> `99-make-release.sh` 会把 `rootfs.sparse.img` 用 zstd 压到 19 级并切成 <1.9 GB 的分卷
> （GitHub Release 单 asset 上限 2 GB），`release/` 里同时生成 `SHA256SUMS` 与刷机说明。

---

## 8. 已知问题与修复（真机踩坑记录）

> 这一节是 2026-09-30 在真机上定位出来的两个会让人以为"系统坏了"的坑，已在当前镜像中修复。

### 8.1 Wi-Fi 打开但扫描不到任何网络 ★

**症状**：Wi-Fi 开关是开着的，点进去也显示"无线已启用"，但列表里一个 AP 都没有。

**根因**（逐层定位出来的完整链条）：

```
tqftpserv.service 里有一个没被替换的 @prefix@ 占位符
  → systemd 报 "bad unit file setting" 拒绝加载 → tqftpserv 从未启动
  → 主机侧没人给调制解调器提供 WLAN 电源域所需的固件服务
    （设备固件 *.jsn 里写明需要 kernel/elf_loader + wlan/fw）
  → 调制解调器的 msm/modem/wlan_pd 电源域起不来
  → 调制解调器不发布 WLFW(69) QMI 服务
  → ath10k_snoc 的 probe 正常返回，但 ath10k_core_register() 只在收到
    FW_READY_IND 时才被调用 → 永远不注册 wiphy → 没有无线网卡 → 扫描为空
```

**三步判定**（以后遇到同类问题照这个查）：

```bash
systemctl status tqftpserv                                  # 必须 active
qrtr-lookup | awk '$1==69'                                  # 必须能看到 ATH10k WLAN firmware service
ls /sys/class/ieee80211/                                    # 必须有 phyN
journalctl -b -k | grep ath10k                              # 看到 "wld0: renamed from wlan0" 就成了
```

**修复**：
1. `tqftpserv.service` **直接写单元文件**，不要 sed 上游的 `*.service.in`
   （模板里有 `@prefix@`/`@bindir@` 多个占位符，漏一个就整个服务加载失败）；
2. servreg 电源域映射表必须由**内核** `qcom_pd_mapper` 提供 ——
   设备固件的 `.jsn` 里**只有** adsp/cdsp/slpi 条目，`msm/modem/wlan_pd`
   只存在于内核硬编码表里，所以**绝不能** blacklist 它；
3. 内核模块通过 `/etc/modules-load.d/raphael-pd-mapper.conf` 尽早加载。

### 8.2 重启卡死 ★

**症状**：`systemctl reboot` 之后屏幕停在
`Fail to set watchdog hardware timeout to 10 minutes: Invalid argument`，
既不进系统也不重启；此时 USB 网络还能 ping 通，但 sshd 连不上（关机流程里已停）。

**根因**：systemd 重启时会按 `RebootWatchdogSec`（编译默认 10 分钟）去设置硬件看门狗，
PM8150 的看门狗不支持这个超时，返回 EINVAL 后卡在关机流程。

**修复**：`/etc/systemd/system.conf.d/10-raphael-watchdog.conf`：

```ini
[Manager]
RuntimeWatchdogSec=off
RebootWatchdogSec=off
KExecWatchdogSec=off
```

### 8.3 无线网卡叫 wld0，不是 wlan0

systemd 的可预测命名把它命名为 **`wld0`**（`nmcli device` 里显示的名字也是它）。
自己的脚本里请用 `nmcli device wifi ...`，不要硬编码 `wlan0`。

### 8.4 每次开机都弹"初始化向导"，而且改了不生效 ★

**症状**：每次登录都出现 Plasma Mobile 的初始设置向导；在里面改的语言/时区等不会生效；
同时还报"无法保存证书文件/私钥文件"。

**根因**：`/home/winter` 属主是 `root:root`（镜像构建时 user namespace 只映射了 uid 0，
无法 chown 到 1000），用户**写不了自己的家目录** → KDE 存不了任何配置 →
向导每次都认为"还没配置过"、证书/私钥无处可写。

**修复**：
1. `/etc/tmpfiles.d/raphael-home.conf` 里 `Z /home/winter - 1000 1000 -`
   （这条以前被写在"创建用户"分支里，用户已存在时被跳过 —— 现在无条件写）；
2. `raphael-firstboot.service` 首次开机再 `chown -R` 一次兜底；
3. 预置 `~/.config/plasmamobilerc` 的 `[InitialStart] wizardRun=true` 关掉向导
   （想再看一次：`plasma-mobile-initial-start --test-wizard`）。

### 8.5 开机报 "启动 plasma-bigscreen-inputhandler 失败（状态码 127）"

`plasma-bigscreen` 是 KDE 的**电视版界面**，它的自启动项会拉起
`plasma-bigscreen-inputhandler`，而该程序依赖 `libcec.so.8`（HDMI-CEC，手机上没人装），
于是退出码 127。已经**从镜像里移除 `plasma-bigscreen`**，报错消失。

### 8.6 桌面"什么软件都没有"

除了 §8.4 的权限问题（导致主屏收藏夹/抽屉初始化失败），还因为 Plasma Mobile 的
**默认收藏夹指向手机专属应用**（电话/短信/相机），而主线内核上这些应用不可用。
现在主屏是空的属于正常，**上滑**打开应用抽屉即可看到全部 190+ 个应用。
想要传统桌面就选 `Plasma (Wayland)` 会话。

### 8.7 `pacman` 报 "Landlock is not supported by the kernel" ★

**症状**：设备上执行 `pacman -Sy` / `pacman -S` 直接失败：

```
error: restricting filesystem access failed because Landlock is not supported by the kernel!
error: switching to sandbox user 'alpm' failed!
```

**根因**：pacman 7.1 默认给下载进程加 **Landlock** 沙箱，而作者内核
`# CONFIG_SECURITY_LANDLOCK is not set`（没编进去），于是整个下载流程失败 ——
表现为"什么软件都装不了"。

**修复**：目标系统的 `/etc/pacman.conf` 里加

```ini
DisableSandboxFilesystem
DisableSandboxSyscalls
```

（构建脚本 `02-pacman.sh` 已自动写入。注意构建机上的 userns 环境同样需要这两项。）

### 8.8 有声音选项但没有任何声音设备 ★

**症状**：Plasma 音量面板能打开，但里面一个输出设备都没有；`wpctl status` 报
`Could not connect to PipeWire`。

**根因**：`pipewire` / `pipewire-pulse` / `wireplumber` 三个**用户会话**服务全是
`inactive`。本项目的构建跳过了 pacman 的 scriptlet/hook，发行版的 user preset
没有执行，所以用户家目录里没有任何 systemd 用户单元 —— **服务从未被 enable**。

**修复**（等价于 `systemctl --user enable --now pipewire.socket pipewire-pulse.socket
wireplumber.service`，已写进 `07-desktop.sh`）：

```
~/.config/systemd/user/sockets.target.wants/pipewire.socket
~/.config/systemd/user/sockets.target.wants/pipewire-pulse.socket
~/.config/systemd/user/pipewire.service.wants/wireplumber.service
~/.config/systemd/user/pipewire-session-manager.service -> wireplumber.service
```

**验证**：`wpctl status` 能看到 `内置音频` 设备与 `Speaker (TFA9874)` /
`Headphone (WCD9340)` 两个 Sink；`speaker-test -c 2 -t sine -f 440 -l 1` 能出声。

> 提示：`pipewire-pulse` 平时显示 inactive 是正常的 —— 它由 socket 按需拉起。

### 8.9 蓝牙完全不可用（`Invalid Index` / 没有控制器）★

**症状**：`bluetoothctl` 里没有控制器；`btmgmt info` 报 `Index list with 0 items`；
对 `hci0` 执行任何操作都返回 `status 0x11 (Invalid Index)`。内核日志里 QCA 固件
下载却是**成功**的（`QCA setup on UART is completed`）。

**完整根因链**（用 dyndbg + ftrace 逐层挖出来）：

1. `btqca` 驱动会给 hci 设备设置 `HCI_QUIRK_USE_BDADDR_PROPERTY`，内核因此在
   `hci_dev_open_sync()` 里从**设备树父节点**读 `local-bd-address` 作为控制器地址；
2. U-Boot 下发的设备树里 `bluetooth { ... }` 节点**没有** `local-bd-address`；
3. 同时控制器自身（NVM 不匹配时）上报的 BD_ADDR 是**全零**；
4. 于是 `hci_power_on()` 走到这段判断后**立刻关闭设备**，并且**没有**发出
   `mgmt Index Added`：

   ```c
   if (hci_dev_test_flag(hdev, HCI_RFKILLED) ||
       hci_dev_test_flag(hdev, HCI_UNCONFIGURED) ||
       (!bacmp(&hdev->bdaddr, BDADDR_ANY) &&
        !bacmp(&hdev->static_addr, BDADDR_ANY))) {
           hci_dev_clear_flag(hdev, HCI_AUTO_OFF);
           hci_dev_do_close(hdev);        /* ← 蓝牙"没有控制器"的直接原因 */
   }
   ```

   表现为：`hci0` 设备节点存在、rfkill 正常，但 mgmt 里一个 index 都没有。日志里能
   看到 `hdev hci0 event 3`（UP）后 **36 微秒**就出现 `hci_dev_do_close` + `err 0x13`。

**修复**（两处都要，缺一不可，已写进构建脚本）：

1. **设备树补 `local-bd-address`**（`dtb/raphael-redmi-k20pro.dtb`，
   `scripts/10-image-boot.sh` 会把它写进 `/boot/dtbs/qcom/` 并在引导条目里加
   `devicetree` 行）：

   ```dts
   bluetooth {
       compatible = "qcom,wcn3998-bt";
       ...
       local-bd-address = [<你的设备蓝牙地址>];   /* 02:00:78:E0:04:F0（本机地址，小端序）*/
   };
   ```

2. **用机器自带的原厂 NVM**：`linux-firmware` 里的 `qca/crnv21.bin` 与本机板级校准
   不匹配（换用它时即使有上面的地址也仍然失败）。设备自带的 `bluetooth` 分区
   （FAT16，`/dev/disk/by-partlabel/bluetooth`）里 `image/` 目录就是原厂固件：

   ```bash
   mkdir -p /mnt/bt && mount -o ro /dev/disk/by-partlabel/bluetooth /mnt/bt
   cp /mnt/bt/image/crnv21.bin     /lib/firmware/qca/crnv21.bin
   cp /mnt/bt/image/crbtfw21.tlv   /lib/firmware/qca/crbtfw21.tlv
   umount /mnt/bt
   ```

   `06-config.sh` 已把它做成 `raphael-bt-firmware.service`（开机自动、幂等）。

**验证**：

```
$ btmgmt info
Index list with 1 item
hci0:  Primary controller
       addr 02:00:78:E0:04:F0  version 9  manufacturer 29
       current settings: powered bondable ssp br/edr le secure-conn ...
$ bluetoothctl --timeout 15 scan on     # 实测扫到 9 个真实设备
```

### 8.10 麦克风录音全是 0（采集链路不上电）★

**症状**：`arecord -D hw:0,0` 能录到文件，但样本**全为 0**（连本底噪声都没有）。

**根因（已确认并修好第一层）**：

1. 厂商 UCM 只有 `Speaker` / `Headphone`，**从来没有配置过采集路由**，
   `AMIC MUX0` 停留在默认值 `ZERO`（断开）→ DAPM 找不到完整的采集通路 →
   整个 `ADC1 / DEC0 / SLIM TX0 / AIF1 CAP` 链路**根本不上电** → 全零。
   把 `amixer -c 0 cset name='AMIC MUX0' 1`（= ADC1，主麦克风 AMIC1）设上以后，
   采集链路立刻全部 `On`（可用 `asoc` debugfs 观察）。

2. U-Boot 设备树的 `sound/audio-routing` 只给播放侧（`RX_BIAS`）挂了 `MCLK`，
   **采集侧没有任何 MCLK 依赖** → WCD9340 数字核无时钟、`ANA_BIAS` 也不开。
   修补版设备树补上了：

   ```dts
   audio-routing = ..., "AIF1 CAP", "MCLK", "AIF2 CAP", "MCLK",
                        "AIF3 CAP", "MCLK", "SLIM TX0", "MCLK";
   ```

   验证：录音时 `MCLK` 部件变为 `On`（此前一直是 `Off`）。

**当前状态**：链路已全部上电（codec 的 `ADC1/AMIC1/MIC BIAS3/CDC_IF TX0/SLIM TX0`、
q6afe 的 `SLIMBUS_0_TX`、q6asm 的 `MM_UL1` 全部 `On`，`TX port` 不再溢出），
但录到的样本**仍是全零** —— 说明还差 DSP/ADM 侧或模拟前端的最后一步，
排查过程与后续计划见 [microphone-and-kernel-plan.md](notes/microphone-and-kernel-plan.md)。

> ⚠️ **千万不要提前往 UCM 里加 `SectionDevice."Mic"` / `CapturePCM`！**
> 本机反复复现：只要 UCM 里存在一个**打不开的** `CapturePCM`
> （采集链路没通时 `hw:0,0` 的 capture open 返回 `EINVAL`），PipeWire 的 ACP 会
> **放弃整个 UCM** —— 卡片只剩 `off` / `pro-audio` 两个 profile，连
> Speaker / Headphone 一起消失；而 `pro-audio` 又会暴露那个打不开的 `hw:0,0`，
> 于是设备在"识别到 / 识别不到"之间反复抖动（音量面板里的内置音频反复启用停用）。
> 必须等采集链路真能录到数据之后，再加 Mic 设备。
> 另外：显式把内置音频切成 `专业音频 (pro-audio)` 也会触发同样的抖动。

### 8.11 其它已知限制

| 项 | 说明 |
|:--|:--|
| 自动旋转 | 设备树里没有加速度计节点，无法自动旋转 |
| 挂起/休眠 | SM8150 只有 s2idle，已 mask；用熄屏 (`leijun`) 代替 |
| 摄像头 | 主线缺 sm8150 的 CAMSS/CCI 设备树与驱动，也缺 IMX586 等 sensor 驱动 —— 详见 [camera.md](camera.md) |
| 手电筒 | ✅ 可用：`shoudian on/off/toggle`（KDE 菜单里也有） |
| 锁屏 | 默认关闭（不设 PIN），避免手机上解不开 |
| 中文输入法 | ✅ fcitx5 + Rime（Ctrl+Space 切换） |

## 9. 排障

| 现象 | 处理 |
|:--|:--|
| 刷完黑屏 | 长按电源 10 秒强制重启；确认 `fastboot flash cache` 成功（cache 分区需 ≥256 MiB） |
| 卡在 systemd-boot 菜单 | 选 `arch-direct.conf`（不用 initramfs） |
| 内核起来了但挂载根失败 | 在 `arch-debug.conf` 里看 log；initramfs 会掉进救援 shell（需 OTG 键盘） |
| **Wi-Fi 扫描不到任何 AP** | 先查 `systemctl status tqftpserv` 是否 active、`qrtr-lookup` 里有没有 69 号 WLFW 服务 —— 详见 §8.1 |
| 网卡名不是 wlan0 | 正常，systemd 把它叫 `wld0`（§8.3） |
| 没有声音 | `aplay -l` 看有没有 `card 0: Raphael`；再查 `systemctl status rmtfs tqftpserv` |
| 无法重启 | 见 §8.2（关机卡在 watchdog 设置），新镜像已修复 |
| 桌面起不来 | 用 USB NCM 网络 SSH 进去：`ssh winter@172.16.42.1`，然后 `journalctl -b -u sddm`；必要时 `KWIN_COMPOSE=Q startplasma-wayland` 用软件渲染验证 |
| 想回 Android | `fastboot flash boot <备份>`，再刷小米线刷包 |

深度资料：`notes/camera.md`（相机适配结论与路线图）、`notes/bluetooth.md`（蓝牙排查记录）、`notes/porting-checklist.md`（Debian→Arch 逐条移植对照）、
`notes/plasma-mobile.md`（Plasma 包与配置校验）、`notes/qcom-userspace.md`（Qualcomm 用户态服务构建）。

---

## 10. 致谢

- [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot) —
  U-Boot、定制内核（7.2）、设备固件、ALSA UCM，本项目直接复用其产物
- [Aospa-raphael-unofficial/linux](https://github.com/Aospa-raphael-unofficial/linux) — 内核源码
- [postmarketOS](https://postmarketos.org/) — sm8150 主线化工作与 `goodix_gtx8` 驱动来源
- [linux-msm](https://github.com/linux-msm) — qrtr / rmtfs / pd-mapper / tqftpserv
- Arch Linux ARM 与 KDE 社区

---

## 11. 许可与归属

### 本仓库

**GPL-2.0-only**（见 [LICENSE](LICENSE)）—— 与 Linux 内核生态保持一致，
任何衍生作品都必须以同样的方式开源。

```
Copyright (C) 2026 Winter21c
SPDX-License-Identifier: GPL-2.0-only
```

### 第三方材料

本项目**不分发**别人的二进制产物，所有上游文件都由 `scripts/00-fetch.sh` 在**构建时**从原始发布页下载：

| 材料 | 来源 | 说明 |
|:--|:--|:--|
| 定制内核 / 设备固件 / ALSA UCM / 内核更新包 | [GengWei1997/kernel-deb](https://github.com/GengWei1997/kernel-deb) releases | 构建时下载，不随仓库分发 |
| U-Boot、cache 分区 FAT 模板 | [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot) releases v1.0.0 | 该仓库**未声明许可证**，本项目只引用其发布产物 |
| Arch Linux ARM aarch64 rootfs | [archlinuxarm.org](https://archlinuxarm.org/) | 构建时下载 |
| 用户态服务源码 qrtr / rmtfs / pd-mapper / tqftpserv | [linux-msm](https://github.com/linux-msm) | 构建时拉取 |
| 内核源码 sm8150 分支 | [Aospa-raphael-unofficial/linux](https://github.com/Aospa-raphael-unofficial/linux) | 仅作参考（产物用上面的预编译包） |

设备固件（`firmware-xiaomi-raphael.deb` 的内容）属于厂商版权材料，
因此**不随本仓库分发**，请自行构建获取。

### 关于 notes/

`notes/` 下的调研文档为目标项目的**互操作性分析**，其中引用了上游 Debian 构建脚本的片段
（上游未声明许可证）。这些引用仅用于说明"哪个行为移植到了哪里"，
**不在本项目的 GPL-2.0 授权范围内**，版权归原作者所有。

---

## 12. 免责声明

刷机有风险：可能变砖、丢数据、失去保修。请先备份（至少 `boot`/`dtbo` 分区和 Android 数据）。
本项目按"现状"提供，不对任何损失负责。默认密码（`winter`/`winter`、`root`/`root`）
**仅供首次登录使用，刷完请立刻修改**：`passwd && sudo passwd root`。
