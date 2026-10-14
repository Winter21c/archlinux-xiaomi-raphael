---
type: architecture
title: 架构总览：构建侧与运行时侧的阶段群划分
description: 仓库的整体心智模型：宿主侧 build.sh 的 12 个阶段（00–10，含 03b）把上游 ALARM rootfs、作者内核 deb、固件与 U-Boot 装配成三份刷机产物，设备侧由随镜像发货的 systemd 单元完成首启动初始化与常驻服务。本页给出四个阶段群的关系图、产物到分区清单，以及「构建期只写静态内容」与「设备上才发生的事」之间的分界线。
tags: [architecture, overview, build-pipeline, boot-chain, raphael, arch-linux-arm]
---

# 架构总览：构建侧与运行时侧的阶段群划分

这个仓库不是一个"在手机上安装的系统"，而是两半拼起来的东西：

- **构建侧**：一条宿主侧离线装配流水线。它**不编译内核、也不编译 U-Boot**，而是把上游产物（Arch Linux ARM aarch64 rootfs tarball、`GengWei1997/kernel-deb` 的 7.2 内核 deb、作者固件 deb、U-Boot zip、cache 分区的 FAT 模板）重排成能刷进一台 raphael 的三份镜像；仓库里真正"编译"的只有阶段 03b 的投屏模块与阶段 05 的 qcom 用户态（[`config/build.conf`](../../config/build.conf#L7-L23)、[`scripts/00-fetch.sh`](../../scripts/00-fetch.sh#L12-L40)）。
- **运行时侧**：一层随镜像发货的设备定制 —— 设备树、固件、精简 UCM、脚本与 `raphael-*` 单元、音频路由、qcom 用户态，全部在设备开机后由 systemd 拉起。

两个入口：宿主上 `./build.sh`（`--from` / `--only` / `--list`，阶段脚本在 `scripts/`）；设备侧 `./scripts/11-flash.sh --flash` 把产物写进分区。`dl/`、`work/`、`out/` 是生成物不是源码（见 [仓库布局与入口点](repository-layout-and-entrypoints.md)）。

构建默认**不需要 root**：需要 chroot 的阶段都用 `lib.sh` 的 `require_ns` 把自己重入 user namespace（无 root 时 `unshare -r -m -p -f`，已是真 root 时只建 mount/pid namespace，[`scripts/lib.sh`](../../scripts/lib.sh#L42-L59)），只有还没有 rootfs 的 `00-fetch.sh` 与纯宿主交叉编译的 `03b-ms91xx.sh` 不这样做（机制与代价见 [无 root 构建运行时](rootless-build-runtime.md)）。

## 四个阶段群

[`build.sh`](../../build.sh#L26-L39) 的 `STAGES` 数组给出全部 12 个阶段项（阶段号 `00`–`10`，其中 `03b-ms91xx.sh` 是唯一带字母后缀的阶段），并按数组顺序逐个 `bash scripts/<阶段>.sh`、把输出 `tee` 进 `logs/build.log`，任一阶段失败立即中止（[`build.sh`](../../build.sh#L89-L102)）。`11-flash.sh` 不在流水线里（只在 `--list` 时被补印一行），`99-make-release.sh` 更是另一条通道。

```mermaid
flowchart TB
  DL["dl/: ALARM rootfs tarball, 内核 deb, 固件, U-Boot zip, FAT 模板"]
  subgraph BUILD["构建期 build.sh: 四个阶段群按序执行"]
    G1["取料 00 01"]
    G2["装系统 02 03 03b 04 05"]
    G3["配置 06 07 08"]
    G4["成像 09 10"]
    G1 --> G2 --> G3 --> G4
  end
  TREE["work/root: 目标 rootfs 目录树"]
  OUT["out/: boot-cache.img 与 rootfs 镜像"]
  UB["work/uboot/u-boot.img"]
  DL --> G1
  G2 --> TREE
  G3 --> TREE
  TREE --> G4 --> OUT
  DL --> UB
  OUT --> FLASH["scripts/11-flash.sh"]
  UB --> FLASH
  FLASH --> PBOOT["boot: U-Boot 引导器"]
  FLASH --> PCACHE["cache: boot-cache.img, 运行时挂到 /boot"]
  FLASH --> PUSER["userdata: 根文件系统镜像"]
  subgraph RUN["设备运行时: 随镜像发货的 systemd 单元"]
    FIRST["首启动一次性: 扩容, pacman 密钥环, 交换文件, 原厂蓝牙 NVM, 家目录属主"]
    LONG["常驻: qcom 用户态, usb-ncm, 音频纠偏, fstrim"]
    LOGIN["graphical.target 到 SDDM 到会话"]
    FIRST --> LONG --> LOGIN
  end
  PCACHE --> RUN
  PUSER --> RUN
```

上图：四个阶段群怎样把 `dl/` 的上游产物变成三份镜像，镜像落到哪些分区，以及分区里的内容开机后由谁跑。

| 阶段群 | 阶段 | 负责什么 |
|:--|:--|:--|
| 取料 | `00` `01` | 下载并缓存上游产物到 `dl/`（ALARM rootfs tarball、内核与固件 deb、U-Boot zip、FAT 模板），再把 ALARM rootfs 解包成 `work/root` 目录树并校正权限 |
| 装系统 | `02` `03` `03b` `04` `05` | 用宿主 pacman 以 `--arch aarch64 --noscriptlet` 把基础系统与所选桌面装进树里、并对齐仓库快照；把作者内核 deb 重排成 Arch 布局；在宿主上交叉编译 MS91xx USB 投屏驱动模块；铺设备固件与精简 UCM；交叉编译 qcom 用户态（`rmtfs`/`pd-mapper`/`tqftpserv`/`qrtr`） |
| 配置 | `06` `07` `08` | 系统级配置（locale、fstab、用户、USB NCM、电源、zram、音频路由、全部 `raphael-*` 单元）；桌面/会话配置（SDDM、字体、输入法）；手工组装 initramfs |
| 成像 | `09` `10` | 造根文件系统镜像（含 `img2simg` 的 sparse 版）；造 cache 分区的 FAT32 引导镜像并注入蓝牙地址 |

阶段 02 的做法决定了后面很多事情的形态：它**不在 chroot 里跑 aarch64 程序**，而是让宿主 x86_64 的 pacman 直接往 `$ROOT` 装包并一律 `--noscriptlet`，装完列表后再用 `-Su --noscriptlet --ignore linux-firmware` 把整个 rootfs 对齐到仓库快照（忽略 `linux-firmware` 是刻意的：设备固件来自作者 deb，升级它只会连带拉进几个 GB 的无关固件）。因此**发行版的 scriptlet 与 preset 从未执行过**，所有 enable 动作（连用户级的 `pipewire.socket` / `wireplumber.service`，见 [`scripts/07-desktop.sh`](../../scripts/07-desktop.sh#L332-L342)）都必须由阶段脚本自己完成 —— 漏掉的症状是"系统里有声音选项但一个输出设备都没有"。逐阶段的前置条件、输入输出与"哪些只告警不失败"，见 [构建流水线各阶段](build-pipeline-stages.md)。

布局则是另一处跨阶段契约：根文件系统形态由 [`lib.sh:rootfs_layout()`](../../scripts/lib.sh#L317-L354) 单点决定（`ext4` / `btrfs-subvol` / `btrfs-flat`，结果缓存在 `work/rootfs-layout`），阶段 06 按它写 fstab（[`scripts/06-config.sh`](../../scripts/06-config.sh#L58-L70)）、阶段 09 按它造镜像（loop 挂载失败回退 flat 时**先重写 fstab 再 `mkfs -r`**）、阶段 10 按它生成 `rootfstype=` 与 `rootflags=subvol=...`。细节与历史事故见 [rootfs 布局、fstab 与扩容](../concepts/rootfs-layout-and-fstab.md)。

## 产物清单与目标分区

最终产物只有三样，各自对应一个设备分区：

| 产物 | 产出阶段 | 落到哪个分区 | 里面是什么 |
|:--|:--|:--|:--|
| `work/uboot/u-boot.img` | `00`（从上游 release 的 zip 里解出，仓库不编译引导器） | `boot` | 引导器本体 |
| `out/boot-cache.img` | `10`（以上游 256 MiB FAT32 模板原地改写） | `cache` | systemd-boot、内核 `linux.efi`、`initramfs`、dtb、三个 systemd-boot 条目；运行时挂到 `/boot` |
| `out/rootfs.img` / `out/rootfs.sparse.img` | `09` | `userdata` | Arch Linux ARM 根文件系统（默认 btrfs，可能是 `@`/`@home`/`@swap` 子卷布局，也可能是单子卷） |
| —— | —— | `dtbo` | **没有产物**：刷机时被 `fastboot erase dtbo` 清掉 |

设备侧的启动链是 U-Boot（`boot` 分区）→ cache 分区上的 `EFI/BOOT/BOOTAA64.EFI`（systemd-boot）→ 条目指定的内核 `linux.efi` 与 `initramfs` → `userdata` 上的根文件系统（内核命令行 `root=UUID` / `rootfstype` / `rootflags`）→ systemd → SDDM 会话。

刷机顺序是固定的：先 `erase dtbo boot cache userdata`，再依次 `flash boot`（U-Boot）、`flash cache`、`flash userdata`，最后 `reboot`；三份产物缺任何一份脚本直接失败（[`scripts/11-flash.sh`](../../scripts/11-flash.sh#L84-L117)、[`scripts/99-make-release.sh`](../../scripts/99-make-release.sh#L37-L45)）。

几件必须知道的事：

- **`cache` 就是运行时的 `/boot`**（fstab 用 `PARTLABEL=cache` 挂 vfat 到 `/boot`，`umask=0077`，[`scripts/lib.sh`](../../scripts/lib.sh#L429-L430)）。所以换内核、initramfs、设备树**不用重新刷机**：`scp` 覆盖 `/boot` 下的文件再重启即可 —— 这是本仓库迭代最快的路径。引导链与 cache 分区里每个文件的来源见 [引导链与镜像/分区布局](boot-chain-and-image-layout.md)。
- **`dtbo` 被擦掉会带走每台设备唯一的蓝牙地址**（产线值写在厂商设备树里，`persist`/`bluetooth` 分区没有明文）。公开镜像不携带地址：构建期可用 `config/local.conf` 的 `BT_MAC`（或环境变量 `RAPHAEL_BT_MAC`）注入，刷机时可用 `11-flash.sh --bt-mac`（或 `scripts/bt-mac.sh`）直接改 FAT 镜像里的设备树（[`scripts/10-image-boot.sh`](../../scripts/10-image-boot.sh#L50-L80)、[`scripts/11-flash.sh`](../../scripts/11-flash.sh#L88-L104)）；写法是设备树的小端字节序，和 `bluetoothctl` 显示的值相反，格式错误只 WARN 不失败。见 [蓝牙与设备树身份](../integrations/bluetooth-and-devicetree-identity.md) 与 [刷机与恢复](../workflows/flash-a-device.md)。
- **镜像大小只上不下**：`IMAGE_SIZE`（默认 8G）是下限，阶段 09 按内容自动放大，首启动再由 fstab 的 `x-systemd.growfs` 把根撑满 `userdata` 分区（[`config/build.conf`](../../config/build.conf#L43-L46)、[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L44-L60)）。
- **cache 镜像里的三个条目是有意的容错设计**：`arch.conf` 正常带 initramfs 启动；`arch-direct.conf` 不带 initrd、由内核直接挂根（initramfs 出问题时的救援项）；`arch-debug.conf` 带 initramfs 并加 `loglevel=7` 与 `systemd.log_level=debug`。三者的 `devicetree` 行只在仓库自带 `dtb/raphael-redmi-k20pro.dtb` 存在时写入，指向它；根参数由同一个 `$ROOTOPTS` 生成，所以三个条目不会各说各话（[`scripts/10-image-boot.sh`](../../scripts/10-image-boot.sh#L111-L150)）。
- `out/boot-cache.img` **不是从零生成**：阶段 10 以上游 release 的 256 MiB FAT32 引导镜像为模板，用宿主 `mtools` 原地替换/新增文件（不需要 root，也不需要挂载，[`scripts/10-image-boot.sh`](../../scripts/10-image-boot.sh#L156-L184)）。

## 构建期与运行时的分界

这是本页最该记住的一条线：**构建期只做两件事 —— 把静态文件写进 rootfs 目录树，以及离线改单元启停状态**（`systemctl --root=/ enable|mask`，在无 dbus 的 chroot 里失败则退回手工建 `*.wants` 软链或指向 `/dev/null` 的 mask 软链，[`scripts/lib.sh`](../../scripts/lib.sh#L171-L194)）。凡是需要真实硬件、真实时机或真实会话才能完成的事，一律留给随镜像发货的 systemd —— 这与"阶段 02 跳过 scriptlet"是同一件事的两面。

| 事项 | 构建期（阶段脚本） | 设备运行时 |
|:--|:--|:--|
| 文件落地 | 决定 rootfs 里有哪些文件、fstab 怎么写、引导项参数是什么 | —— |
| 单元启停 | 离线 `enable`/`mask`（`lib.sh:enable_unit` / `mask_unit`，经 qemu 在 chroot 内执行，不需要 dbus） | systemd 按 `*.wants` 软链启动 |
| 根扩容 | 把 `x-systemd.growfs` 写进 fstab（systemd 没提供 `systemd-growfs@` 时退回自建 `raphael-growfs.service`，[`scripts/06-config.sh`](../../scripts/06-config.sh#L71-L105)） | 首次开机挂根时把根撑满 `userdata` |
| 家目录属主 | userns 里 chown 不到 uid 1000，所以只写规则：`/etc/tmpfiles.d/raphael-home.conf` 的 `Z /home/<user>`，并往 `raphael-firstboot.sh` 里插一行 `chown -R` 兜底（[`scripts/06-config.sh`](../../scripts/06-config.sh#L866-L889)） | systemd-tmpfiles / 首启动脚本实际修正属主（漏了会让 KDE 写不了配置、每次开机弹初始化向导） |
| 首启动一次性动作 | 只放脚本 + 条件（`ConditionPathExists=…`），不执行 | `raphael-firstboot.service` 初始化 pacman keyring（含 archlinuxcn）、`raphael-swapfile.service` 在 `@swap` 建 nocow 交换文件并写进 fstab、`raphael-bt-firmware.service` 从 `bluetooth` 分区把原厂 NVM/固件装到 `/lib/firmware/qca`（[`scripts/06-config.sh`](../../scripts/06-config.sh#L381-L410)、[`scripts/06-config.sh`](../../scripts/06-config.sh#L418-L456)、[`scripts/06-config.sh`](../../scripts/06-config.sh#L766-L807)） |
| 音频 | 把作者 deb 的 UCM 裁成只留能工作的扬声器通路并补到实际声卡名对应目录（`Raphael` / `sm8150` / `sm8150_raphael` / `xiaomi-XiaomiRedmiK20Pro` —— 声卡名会随内核构建变化，只要有一个打不开的 PCM，PipeWire 的 ACP 就会放弃整个 UCM）；写 WirePlumber 格式规则；blacklist `slim_qcom_ngd_ctrl` 与 `snd_soc_sm8150`（[`scripts/06-config.sh`](../../scripts/06-config.sh#L466-L529)、[`scripts/06-config.sh`](../../scripts/06-config.sh#L546-L559)） | `raphael-audio-init.timer` 在开机 12 秒后拉起一次性初始化（重启 `pd-mapper`、手动加载 slim-ngd、等 codec 就绪再带重试 `modprobe` 声卡、以用户身份重启 WirePlumber、把 profile 切到 `output:stereo-fallback` 或 `HiFi`、写 Q6 mixer）；`raphael-audio-routing.timer` 从 25 秒起**每 5 秒**重跑（`OnBootSec=25s` + `OnUnitActiveSec=5s`，单元 `Description` 里"every 20s"的说法已经过期），按 ALSA 的 `Headset Jack` 控件在耳机 / 底部扬声器两条路由里二选一，并在 profile 掉回 `pro-audio`/`off` 时再切回来（ACP 激活 profile 时会复位路由与 profile，[`scripts/06-config.sh`](../../scripts/06-config.sh#L652-L664)、[`scripts/06-config.sh`](../../scripts/06-config.sh#L674-L756)） |
| qcom 用户态 | `rmtfs`/`pd-mapper`/`tqftpserv`/`qrtr` 在 ALARM 仓库里不存在，阶段 05 用宿主 clang 交叉编译进镜像，阶段 06 再显式 `enable`（[`scripts/06-config.sh`](../../scripts/06-config.sh#L206-L212)） | 常驻，给 ADSP/CDSP/MSS 提供固件、电源域（servreg）与 EFS 服务；没跑就没有 Wi-Fi（WLFW）与声音 |
| 网络 | 禁用并 mask ALARM 默认启用的 `systemd-networkd`/`systemd-resolved`，改用 NetworkManager（阶段 09 还会硬检查残留软链），并写入 USB NCM gadget 脚本（[`scripts/06-config.sh`](../../scripts/06-config.sh#L213-L240)、[`scripts/06-config.sh`](../../scripts/06-config.sh#L242-L314)） | `usb-ncm.service` 等 UDC 出现后绑 gadget（失败按 `RestartSec=8` 重试），设备侧固定 `172.16.42.1` 供 SSH 直连 |
| 桌面 | 写 `sddm.conf.d/10-raphael.conf`（会话、自动登录、合成器、主题）并 `set-default graphical.target`（[`scripts/07-desktop.sh`](../../scripts/07-desktop.sh#L58-L114)） | SDDM 起登录界面 → 会话 |
| 其它 | `fstrim.timer`、`zram-generator`、`raphael-snapper-setup.service`、`raphael-display-nopm.service`、非 KDE 时的 `raphael-power-key.service`（[`scripts/07-desktop.sh`](../../scripts/07-desktop.sh#L526-L553)），以及关掉 systemd 的看门狗（`system.conf.d/10-raphael-watchdog.conf`：PM8150 硬件看门狗不支持 10 分钟超时，设置失败会让重启卡在关机流程，[`scripts/06-config.sh`](../../scripts/06-config.sh#L1061-L1072)） | 各自在上线后执行 |

几处"故意屏蔽"同属运行语义：`sleep`/`suspend`/`hibernate`/`hybrid-sleep` 目标被 mask（SM8150 只有 s2idle 且不稳定，用熄屏代替），`logind` 的 `HandlePowerKey` 等设成 `ignore` 把电源键交给桌面或自研守护，`systemd-firstboot.service` 被 mask 以免交互式首启卡住无人值守启动（[`scripts/06-config.sh`](../../scripts/06-config.sh#L332-L346)、[`scripts/06-config.sh`](../../scripts/06-config.sh#L358-L360)）。

跨阶段的所有权只剩一处分歧：`05-qcom.sh` 明确把用户态 `pd-mapper` 保持禁用（真机验证内核 `qcom_pd_mapper` 已覆盖必需的电源域映射），但随后运行的 `06-config.sh` 6b 段又把它 `enable` 回来，所以镜像里最终是**启用**状态 —— 要改 qcom 服务启停，两个阶段都得看（[`scripts/05-qcom.sh`](../../scripts/05-qcom.sh#L219-L230)、[`scripts/06-config.sh`](../../scripts/06-config.sh#L196-L212)）。

运行时侧的完整单元清单、启动时序与首启动那几件一次性动作的先后关系不在本页展开，见 [设备运行时服务](../operations/device-runtime-services.md)；音频链路的真机结论见 [音频管线与路由](../integrations/audio-pipeline-and-routing.md)，qcom 用户态与 remoteproc 的关系见 [Qualcomm remoteproc 与用户态](../integrations/qualcomm-remoteproc-and-userspace.md)。

## 哪些是 raphael 专属，哪些是可迁移机制

这是本仓库最容易让新读者误判的地方：**通用机制**（阶段骨架、无 root 构建、systemd-boot 引导项、btrfs + `x-systemd.growfs`、单元 enable/mask）与**设备专属配置**（内核、设备树、固件、声卡名、分区名）混在同一个脚本目录里。

| 层面 | raphael / SM8150 专属 | 可迁移的 Arch/ALARM 机制 |
|:--|:--|:--|
| 引导与内核 | 上游 `linux-xiaomi-raphael-uboot` 的 U-Boot；`GengWei1997/kernel-deb` 的 7.2 内核 deb；`dtb/raphael-redmi-k20pro.dtb`；`erase dtbo` 与每机唯一的蓝牙地址 | systemd-boot 的 `loader.conf` + `loader/entries/*.conf`；`root=`/`rootfstype=`/`rootflags=` 引导参数 |
| 分区 | `boot`/`cache`/`userdata` 这套 Android 分区名，`cache` 当 `/boot` | FAT32 镜像用 `mtools` 无 root 读写；`mke2fs -d` / `mkfs.btrfs -r` |
| 根文件系统 | —— | ALARM aarch64 rootfs tarball；btrfs 子卷 + `compress=zstd:3`；`x-systemd.growfs` |
| 软件来源 | 设备固件与 UCM 来自作者 deb（且阶段 04 会**故意删掉** `regulatory.db*`：内核要求签名管制数据库而这个包的签名不被 vendor 内核信任，无线管制域只能靠引导参数 `cfg80211.ieee80211_regdom` 设置）；qcom 用户态要自己交叉编译；`vendor/ms91xx` 的投屏驱动 | 宿主 pacman `--arch aarch64` 装 ALARM/archlinuxcn 包；`--noscriptlet` + qemu 补跑 |
| 硬件服务 | `tqftpserv`/`rmtfs`/`pd-mapper`、蓝牙原厂 NVM、精简 UCM + amixer 路由 + WirePlumber 规则、USB NCM gadget | systemd 单元的 enable/mask、`tmpfiles.d`、`logind.conf.d`、`zram-generator`、`fstrim.timer` |
| 桌面 | 这台设备没有实体键盘，触屏键盘与电源键策略按形态切换（`DESKTOPS` 派生 `HAVE_*`/`PRIMARY_SESSION`；含 KDE 时用 `kwin_wayland` 当登录界面合成器，否则用 `weston --shell=kiosk`；留空 = 纯命令行，不装显示管理器并 `set-default multi-user.target`） | SDDM 会话机制、`graphical.target` |
| 构建环境 | —— | user namespace 无 root 构建；qemu 垫片；CI 里的 privileged 容器 + loop 设备 |

设备专属的耦合点集中且可数：`config/build.conf` 的上游 URL 与内核版本、`dtb/` 与 `BT_DT_NODE` 那棵设备树路径、`raphael-*` 单元与服务脚本名、UCM 的声卡名目录列表、以及分区名。换成另一台设备时，改这些点即可，阶段骨架与构建运行时可以照搬；反过来，看到 `raphael-` 前缀请不要以为整条流水线都是设备专用的（[`config/build.conf`](../../config/build.conf#L7-L23)、[`scripts/lib.sh`](../../scripts/lib.sh#L356-L366)）。

## 入口、配置与扩展点

- **构建**：`./build.sh`（全量）、`--from 03`（从某阶段起）、`--only 06 07 08 09 10`（只跑指定阶段，改配置后的重打包常用）、`--list`。哪些阶段跳过会留下陈旧状态（`work/root` 复用、`work/rootfs-layout` 缓存粘性）见 [构建流水线各阶段](build-pipeline-stages.md)。
- **调参**：`config/build.conf` 是唯一调参入口（镜像大小、根文件系统类型、包列表与桌面、账户、locale/时区、内核版本与上游 URL、无线管制域）；本机私密值放已 gitignore 的 `config/local.conf`。注意它是**会被 source 执行的 bash**，写错桌面名会让 `build.sh` 自己 `exit 1`。见 [配置模型](../concepts/configuration-model.md)。
- **加一个阶段**：写 `scripts/NN-name.sh`（`source lib.sh` + 需要时 `require_ns`）并加进 `build.sh` 的 `STAGES` 数组 —— 阶段号就是脚本名前缀，未被列进数组的脚本永远不会被执行（[`build.sh`](../../build.sh#L26-L39)）。
- **加一个运行时单元**：在 `06`（系统级）或 `07`（桌面相关）里写脚本 + unit，然后 `enable_unit`，它会自动处理"无 dbus 的 chroot"这条路径（[`scripts/lib.sh`](../../scripts/lib.sh#L171-L194)）。
- **云端构建**：CI 在 `archlinux:latest` 容器里以 `--privileged -v /mnt:/mnt` 跑同一套 `build.sh`（privileged 是 `unshare` 必需的，`/mnt` 是因为 runner 根分区只有十几 GB），输入/Secret/产物通道见 [CI 构建工作流](../operations/ci-build-workflow.md) 与 [打包与发布](../workflows/package-and-publish-a-release.md)（[`.github/workflows/build.yml`](../../.github/workflows/build.yml#L99-L124)）。

## 相关页面

- [Quickstart — 按任务路由的阅读地图](../quickstart.md) —— 不知道该看哪页时从这里出发。
- [构建流水线各阶段](build-pipeline-stages.md) —— 每个阶段的前置条件、产出与失败点。
- [引导链与镜像/分区布局](boot-chain-and-image-layout.md) —— 上电到 systemd 的链路、cache 分区文件清单。
- [仓库布局与入口点](repository-layout-and-entrypoints.md) —— 源码路径 vs 生成目录（`dl/` `work/` `out/`）。
- [无 root 构建运行时](rootless-build-runtime.md) —— userns、qemu 垫片、mtools。
- [设备运行时服务](../operations/device-runtime-services.md) —— 随镜像发货的单元清单、首启动初始化与启动时序。
- [失败模式与不变量](../concepts/failure-modes-and-invariants.md) —— "做错了会开不了机/静默残废"的规则索引。
- [硬件支持与能力边界](../concepts/hardware-support-and-limits.md) —— 每个外设靠什么才能工作、当前状态与缺口。
- [刷机与恢复](../workflows/flash-a-device.md) —— 把产物落到设备上的完整操作面。
