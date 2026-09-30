# Arch Linux ARM for 红米 K20 Pro (raphael / SM8150) + KDE Plasma Mobile

给 **Xiaomi Redmi K20 Pro / K20 Pro 尊享版 / Mi 9T Pro** 的 Arch Linux ARM (aarch64) 系统镜像，
使用 [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)
的 U-Boot + 定制内核，桌面为 **KDE Plasma 6 + Plasma Mobile**（两个会话可切换）。

上游项目只做 Debian/Ubuntu，本仓库把它移植到 Arch，并把桌面换成 KDE。

---

## 1. 产物（`out/`）

| 文件 | 大小 | 说明 |
|:--|:--|:--|
| `boot-cache.img` | 256 MiB | FAT32，刷入 **cache** 分区：systemd-boot + 内核 `linux.efi` + `initramfs` + dtb + 3 个启动项 |
| `rootfs.img` | 8 GiB（用 6.1 GB） | ext4，刷入 **userdata** 分区；首启动自动扩容到分区实际大小 |
| `rootfs.sparse.img` | 6.1 GiB | 上面的 sparse 版本，`fastboot` 刷写更快（推荐） |

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
3. 自动登录到 **Plasma Mobile**（用户 `winter`，密码 `winter`；`root` 密码 `root`）

**改密码**：`passwd` / `sudo passwd root`。

---

## 3. 硬件支持

| 硬件 | 状态 | 说明 |
|:--|:--:|:--|
| 屏幕 (三星 AMOLED 1080×2340) | ✅ | 主线 panel 驱动 `samsung,ams639rq08` |
| 触摸 (Goodix GT9886) | ✅ | 靠作者内核里的 `goodix_gtx8` 驱动（主线没有 gt9886，只有这套定制内核能点亮触摸） |
| GPU (Adreno 640, freedreno) | ✅ | `qcom/a640_gmu.bin` + `qcom/a630_sqe.fw`（A640 与 A630 共用 SQE） |
| Wi-Fi (WCN3990, ath10k_snoc) | ✅ | 需要 `options ath10k_core skip_otp=y`（已配置）；固件用作者的设备专属版本 |
| 蓝牙 (WCN399x, hci_qca) | ✅ | `qca/crbtfw21.tlv` + `qca/crnv21.bin` |
| 音频 (ADSP + UCM) | ✅ | 已装作者 ALSA UCM + rmtfs/pd-mapper/tqftpserv（音频必需） |
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

---

## 8. 排障

| 现象 | 处理 |
|:--|:--|
| 刷完黑屏 | 长按电源 10 秒强制重启；确认 `fastboot flash cache` 成功（cache 分区需 ≥256 MiB） |
| 卡在 systemd-boot 菜单 | 选 `arch-direct.conf`（不用 initramfs） |
| 内核起来了但挂载根失败 | 在 `arch-debug.conf` 里看 log；initramfs 会掉进救援 shell（需 OTG 键盘） |
| 没有 Wi-Fi | `dmesg \| grep -i ath10k`；确认 `/etc/modprobe.d/ath10k.conf` 存在且固件是**设备专属** `.zst`（`04-firmware.sh` 会自检） |
| 没有声音 | `systemctl status rmtfs pd-mapper tqftpserv`；`wpctl status` 看 UCM 是否识别成 `sm8150_raphael` |
| 桌面起不来 | 用 USB NCM 网络 SSH 进去：`ssh winter@172.16.42.1`，然后 `journalctl -b -u sddm`；必要时 `KWIN_COMPOSE=Q startplasma-wayland` 用软件渲染验证 |
| 想回 Android | `fastboot flash boot <备份>`，再刷小米线刷包 |

深度资料：`notes/camera.md`（相机适配结论与路线图）、`notes/porting-checklist.md`（Debian→Arch 逐条移植对照）、
`notes/plasma-mobile.md`（Plasma 包与配置校验）、`notes/qcom-userspace.md`（Qualcomm 用户态服务构建）。

---

## 9. 致谢

- [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot) —
  U-Boot、定制内核（7.2）、设备固件、ALSA UCM，本项目直接复用其产物
- [Aospa-raphael-unofficial/linux](https://github.com/Aospa-raphael-unofficial/linux) — 内核源码
- [postmarketOS](https://postmarketos.org/) — sm8150 主线化工作与 `goodix_gtx8` 驱动来源
- [linux-msm](https://github.com/linux-msm) — qrtr / rmtfs / pd-mapper / tqftpserv
- Arch Linux ARM 与 KDE 社区

---

## 10. 许可与归属

本项目**不分发**别人的二进制产物，所有上游文件都由 `scripts/00-fetch.sh` 在构建时从原始发布页下载：

- **内核 / 固件 / ALSA UCM / 内核更新包**：来自
  [GengWei1997/kernel-deb](https://github.com/GengWei1997/kernel-deb)（releases）
- **U-Boot**：来自
  [GengWei1997/linux-xiaomi-raphael-uboot](https://github.com/GengWei1997/linux-xiaomi-raphael-uboot)
  releases v1.0.0（该仓库**未声明开源许可证**，本项目只引用其发布产物，不复制其源码）
- **FAT 引导模板**：`xiaomi-k20pro-boot.img`（同上，构建时下载）
- **rootfs**：Arch Linux ARM 官方 aarch64 通用 tarball
- **用户态服务源码**：`linux-msm/{qrtr,rmtfs,pd-mapper,tqftpserv}`（构建时 git/curl 拉取）
- **本仓库自身内容**（`build.sh` / `scripts/` / `config/` / `pkgs/` / `notes/` / 文档）：
  暂未声明许可证。**如果你要指定，告诉我用 MIT 还是 GPL-2.0，我加一个 LICENSE 文件。**

> 构建产物里包含的设备固件（`firmware-xiaomi-raphael.deb` 内容）是从你自己的手机/上游发布页来的，
> 属于厂商版权材料，因此**不随本仓库分发**，请自行构建。
