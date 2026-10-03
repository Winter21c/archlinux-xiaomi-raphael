# 接手必读 —— Redmi K20 Pro 上的 Arch Linux ARM

> 写给"下一个要改这个仓库的人"。
> 假设你懂 Linux 和命令行，但**完全不了解**这台手机、这套构建、以及前人踩过的坑。
> 目标：读完这一篇，你能看懂每一行在干什么、知道改哪里、知道哪些地方一碰就炸。
>
> 最后更新：2026-10-02 · 对应提交 `3105d7c` 之后

---

## 0. 三十秒版本

把小米 **Redmi K20 Pro（代号 raphael，骁龙 855+）** 从 Android 换成一个能日常开机的
**Arch Linux ARM + KDE Plasma Mobile** 手机系统：

```
U-Boot  →  systemd-boot  →  定制 7.2 内核  →  Arch Linux ARM (btrfs)  →  Plasma Mobile
(boot 分区)   (cache 分区)                     (userdata 分区)
```

触摸屏、Wi-Fi、蓝牙、扬声器、USB 网络共享、屏幕键盘都能用；
**麦克风和相机还不能用**（见 §6）。

一键产出刷机镜像（本地或 GitHub Actions 云端），刷完首次开机自动扩容、自动登录。

---

## 1. 硬件与软件事实速查

| 项 | 值 | 备注 |
|:--|:--|:--|
| 设备 | Xiaomi Redmi K20 Pro / raphael | 国际版叫 Mi 9T Pro，代码里统一用 `raphael` |
| SoC | Qualcomm SM8150（骁龙 855+） | |
| 屏幕 | 2340×1080 AMOLED | DSI + `msm_dpu` + Adreno 640（freedreno/Mesa） |
| 存储 | UFS，`sda` | 分区名见下 |
| Wi-Fi | WCN3990 / `ath10k_snoc` | **网卡名是 `wld0`**（不是 wlan0）；固件要 `tqftpserv` 通过 QRTR 送 |
| 蓝牙 | WCN3998 / `hci_qca` | **地址每台设备不同**（见 §3.3）；NVM 要 `bluetooth` 分区里的原厂文件 |
| 音频 | SLIMBUS WCD9340（未用）+ **QUAT_MI2S → TFA9874 功放（底部扬声器）** | 走 ADSP(Q6) + `pro-audio` profile |
| 调制解调器 | 需要 `rmtfs` + `pd-mapper` + QRTR | 当前**没解决通话/数据**，只保证服务在跑 |
| 相机 | 无主线驱动 | 详见 `notes/camera.md` |

**三个分区怎么用**：

| 分区 | 内容 | 谁写 |
|:--|:--|:--|
| `boot` | **U-Boot**（引导器本体） | `fastboot flash boot work/uboot/u-boot.img` |
| `cache` | FAT32：systemd-boot(`bootaa64.efi`) + `linux.efi` + `initramfs` + `dtbs/qcom/raphael-redmi-k20pro.dtb` + `loader/entries/*.conf` | `fastboot flash cache out/boot-cache.img` |
| `userdata` | **btrfs 根文件系统**（`@` 子卷或单子卷） | `fastboot flash userdata out/rootfs.sparse.img` |

> 💡 **`cache` 就是系统里的 `/boot`**（开机自动挂载）。所以换内核/initramfs/设备树
> **根本不用刷机**：直接 `scp` 进 `/boot` 覆盖再重启即可。这是本项目迭代最快的技巧。

---

## 1.5 两种形态（`SESSION`）

`config/build.conf` 的 `SESSION`（可用环境变量覆盖）在**两种桌面形态**间切换，
包列表与 SDDM 会话名都跟着变：

| 值 | 包列表 | SDDM `Session=` | 说明 |
|:--|:--|:--|:--|
| `mobile`（默认） | `PKGS_KDE_COMMON` + `PKGS_KDE_MOBILE_EXTRA` + 手机应用 + 全套字体 | `plasma-mobile` | Plasma Mobile 外壳 |
| `desktop` | `PKGS_KDE_COMMON` + `PKGS_KDE_DESKTOP_EXTRA`（只多 kate），并去掉 flatpak/kdeconnect/man-pages/vim、手机字体、yay | `plasma` | 普通桌面（面板+开始菜单） |

脚本里用 `[ "${SESSION:-mobile}" != "desktop" ]` 把 Plasma Mobile 专属配置
（`plasmamobile` 主屏缩放、`plasmamobilerc` 向导）圈起来。改形态时**记得同时看**：
`config/build.conf` 的拼装段、`scripts/07-desktop.sh` 的两处分支。
CI 侧对应 `session` 输入（choice），日志「显示构建配置」会把生效的完整包列表打出来。

> `@`/`@home` 与形态无关：取决于**构建时能不能 loop 挂载 btrfs**（CI 有准备 loop
> 设备；本地内核升级后没重启会退回单子卷 flat）。

---

## 2. 仓库结构与构建流水线

### 2.1 目录

| 目录 | 作用 |
|:--|:--|
| `build.sh` | 总入口：`./build.sh` / `--from 03` / `--only 06 07` / `--list` |
| `scripts/00…11-*.sh` | 各阶段；`lib.sh` 是公共库（日志、布局、mtools、qemu 垫片、fstab、蓝牙地址注入…） |
| `scripts/11-flash.sh` | 刷机（含 `--backup` 用 TWRP 备份、`--bt-mac` 刷机时注入蓝牙地址） |
| `scripts/bt-mac.sh` | 给"下载来的引导镜像"读/写蓝牙地址（不重新构建） |
| `config/build.conf` | **唯一调参入口**：镜像大小、包列表、用户名密码、内核版本、UI 语言… |
| `config/local.conf` | **已 gitignore** 的本机私密值（`BT_MAC` 等），不要提交 |
| `dtb/raphael-redmi-k20pro.dtb` | 从设备导出的**厂商设备树** + 我们改的 3 处（见 §4.7） |
| `pkgs/` | 自己打包的 AUR 类包（UCM 等） |
| `dl/` | 下载缓存（rootfs tarball、内核 deb、固件、qcom 源码…）→ CI 会缓存 |
| `work/` | 展开的 rootfs、initramfs、内核源码、构建中间产物 |
| `out/` | **最终产物**：`boot-cache.img` + `rootfs.sparse.img` |
| `notes/` | 深挖笔记（蓝牙、相机、麦克风、上游对齐…），遇到问题先翻这里 |
| `_recon/` | 早期侦察时从设备/固件里扒出来的东西（**未跟踪**，只在原作者机器上） |

### 2.2 十个阶段（`./build.sh --list`）

| 阶段 | 干什么 | 典型耗时 | 容易出事的地方 |
|:--|:--|:--|:--|
| 00 | 下载上游产物（ALARM rootfs、内核 deb、固件、U-Boot、FAT 模板） | 看缓存 | 上游 Release 改名/删除 |
| 01 | 解包 rootfs 并校正权限 | 1-2 min | userns 下 uid 映射（见 §5.1） |
| 02 | `pacman` 装基础系统 + KDE + Plasma Mobile（约 190 个包） | 5-15 min | **半升级**（见 §4.5）；脚本后置步骤要 qemu 补跑 |
| 03 | 装 raphael 定制内核（Image + 模块 + dtb） | 秒级 | |
| 04 | 设备固件 + ALSA UCM | 秒级 | **故意删掉 `regulatory.db`**（见 §4.8） |
| 05 | 交叉编译 qcom 用户态：`rmtfs`/`pd-mapper`/`tqftpserv`/`qrtr` | 1 min | **`-lqrtr` 找不到库**（见 §4.6） |
| 06 | 系统配置：locale、fstab、用户、USB NCM、音频路由、电源 | 10 s | fstab 与实际布局必须一致（见 §4.1） |
| 07 | Plasma 桌面/移动会话配置（键盘、输入法、WirePlumber 规则…） | 10 s | 输入法环境变量（见 §5.5） |
| 08 | 手工组装 initramfs（busybox + 模块 + **固件** + `lib` 软链） | 5 s | **忘了 `/lib` 软链 → 花屏**（见 §4.3） |
| 09 | 造 `rootfs.img`（btrfs，压缩写入）+ sparse 版 | 1-2 min | loop 缺失会回退单子卷（见 §4.1） |
| 10 | 造 `boot-cache.img`（FAT32：systemd-boot + 内核 + initramfs + DTB）+ 注入蓝牙地址 | 5 s | 蓝牙地址格式（见 §3.3） |

> 只改 06/07/08 时，`sudo ./build.sh --only 06 07 08 09 10` 大约 **2 分钟**出全套镜像。

---

## 3. 产物、刷机、首次开机

### 3.1 刷机

```bash
# 完整流程（本地构建后）
./scripts/11-flash.sh --dry-run            # 先看命令
./scripts/11-flash.sh --flash              # 会二次确认
./scripts/11-flash.sh --flash --bt-mac "11 22 33 44 55 66"   # 顺手注入蓝牙地址

# 手工等价命令
fastboot erase dtbo boot cache userdata
fastboot flash boot     work/uboot/u-boot.img
fastboot flash cache    out/boot-cache.img
fastboot flash userdata out/rootfs.sparse.img
fastboot reboot
```

用 GitHub 产物时：下载 `boot-cache-image` 与 `rootfs-release`，`sha256sum -c`，
合并分卷 → `zstd -d` → 得到 `rootfs.sparse.img`，然后同样 `fastboot flash`。
（`release/刷机说明.txt` 里也有这一套。）

> ⚠️ 这个 U-Boot 的 `fastboot reboot` 会回一句 `Command failed`，但**设备确实在重启**，别慌。

### 3.2 首次开机会自动做三件事

1. `x-systemd.growfs` 把 `userdata` 上的 btrfs **扩到分区全尺寸**（8 GiB 镜像 → 469 GB）；
2. `raphael-firstboot.service` 初始化 pacman keyring（含 archlinuxcn）；
3. `raphael-bt-firmware.service` 把 `bluetooth` 分区里的**原厂 NVM/固件**拷进 `/lib/firmware/qca/`。

登录：用户名 `user`，密码 `1234`（`root` 同）。密码可在 `config/build.conf` 或 CI 表单里改。

### 3.3 蓝牙地址：**每台设备都不一样**（最容易踩的坑）

- 地址是**产线**写进设备自己的数据里的（`dtbo` 分区里那份厂商设备树带这个值），
  而本项目的刷机流程会 `fastboot erase dtbo` **把它清掉**；丢了就只能从旧记录里翻
  （`persist`、`bluetooth` 分区的 `crnv21/apnv*.bin` 里都**没有明文地址**，本项目实测过）。
- 没有地址时，内核会因为"控制器上报全零 BD_ADDR"**直接关掉蓝牙**（`btmgmt` 报 `Invalid Index`）。
- **写法是设备树的小端字节序，和系统显示的是反的**：

  | 配置里写（设备树） | `bluetoothctl` 显示 |
  |:--|:--|
  | `11 22 33 44 55 66` | `66:55:44:33:22:11` |
  | `11:22:33:44:55:66`（冒号写法） | 同上，写法随意 |

  原因：`net/bluetooth/hci_sync.c` 的 `hci_dev_get_bd_addr_from_property()` 把 DT 数组
  **原样**拷进 `bdaddr_t`，而 `%pMR` 打印时反序。
- 三种给地址的方式：

  | 场景 | 做法 |
  |:--|:--|
  | 本机构建 | `config/local.conf` 里 `BT_MAC="11 22 33 44 55 66"` |
  | 云端构建 | 仓库 Secret `IMAGE_BT_MAC`（**格式写错不会报错，只会 WARN**，看构建日志「已注入…」那行） |
  | 直接刷公开镜像 | `./scripts/bt-mac.sh set boot-cache.img "11 22 33 44 55 66"` 或 `11-flash.sh --bt-mac` |

---

## 4. 关键设计决策（**为什么这么做**，改之前务必读）

### 4.1 rootfs 布局：subvol / flat，以及 fstab 必须与之一致

- `lib.sh:rootfs_layout()` 统一决定布局，结果缓存在 `work/rootfs-layout`：
  - 有 root 且能 loop 挂载 → **`btrfs-subvol`**（建 `@` / `@home`，`@` 设为默认子卷）
  - 没有 root 或内核没带 loop 模块 → **`btrfs-flat`**（`mkfs.btrfs -r` 单子卷）
- **历史事故**：缓存说 subvol，但 09 阶段 loop 挂载失败回退成 flat，
  而 fstab 早就按 subvol 写好 → 镜像里没有 `/@` 却让内核挂 `subvol=/@` → **开不了机**。
  现在 fstab 由 `lib.sh:write_root_fstab()` 生成，**06 和 09 各调一次**（09 在回退分支里
  必须先重写再 `mkfs -r`）。
- 宿主要做 subvol：`/dev/loop*` 设备节点要存在（有些机器只缺节点，`modprobe loop` 也没用，
  要 `mknod /dev/loopN b 7 N`）；**内核模块树与运行内核不匹配时（升级后没重启）也会失败**。

### 4.2 音频：不用 UCM，用 `pro-audio` + amixer 路由 + 20 秒兜底

- 厂商 UCM 里的采集设备打不开，会让 PipeWire 的 ACP **放弃整个 UCM**，声卡反而全没了。
  所以镜像**放弃 UCM**，直接把声卡切成 `pro-audio` profile，然后：
  - `QUAT_MI2S_RX Audio Mixer MultiMedia1 = on`（裸 ALSA / `aplay` 走 `hw:0,0`）
  - `QUAT_MI2S_RX Audio Mixer MultiMedia2 = on`（PipeWire 的 `pro-output-1`，KDE 走这条）
  - 由 `raphael-audio-init.service`（开机 12 s）+ `raphael-audio-routing.timer`（每 20 s 兜底，
    因为 ACP 会把这些 mixer 复位）负责。
- **WirePlumber 规则**（`51-raphael-alsa.conf`）把格式钉死成 `S16LE/48 kHz/2ch` 且不挂起：
  QUAT_MI2S 后端**不接受 8 声道**，ACP 默认会开 8 声道 → DSP 侧
  `AFE enable for port 0x1006 failed -110`，表现是**一调音量就卡、扬声器没声音**。
- 功放是 **TFA9874**（i2c `0-0034`，驱动 `tfa987x`），设备树里挂在 `speaker-dai-link` 上。
  它的 `digital_mute()` 只在有播放流时把 `SYS_CTRL0.AMPE` 置 1，所以
  **`/sys/kernel/debug/regmap/0-0034/registers` 的 `00:` 是判断"功放到底开没开"的关键证据**
  （`0x0018` = AMPE+DCDC 已开）。

### 4.3 initramfs：手工组装，且**必须有 `/lib` 软链**

- 不用 mkinitcpio 执行环境，`scripts/08-initramfs.sh` 自己拼 cpio：
  静态 busybox + 必要模块 + **固件** + `init` 脚本。
- **GPU 固件必须进 initramfs**：`msm_dpu`/`adreno` 是内建驱动，0.6 秒就 probe，
  那时 rootfs 还没挂上。但**内核的 firmware loader 只认 `/lib/firmware`**，
  所以 initramfs 里除了 `usr/lib/firmware/...` 还必须有 **`lib -> usr/lib` 软链** ——
  否则等于没放，GPU 会在没有 SQE 固件的状态下初始化 → **熄屏/开机瞬间花屏**（§5.3）。

### 4.4 qcom 用户态自己编（`scripts/05-qcom.sh`）

- ALARM 仓库里没有 `rmtfs` / `pd-mapper` / `tqftpserv` / `libqrtr`，用宿主 clang
  交叉编译（`--target=aarch64-linux-gnu --sysroot=$ROOT` + ALARM gcc 的 crt/libgcc）。
- 这几个是**必需品**：`tqftpserv` 通过 QRTR 给 ADSP/CDSP 送固件，没有它
  Wi-Fi 拿不到网卡（QRTR 里看不到 `ATH10k WLAN firmware service`，ID 69）、
  Q6 的 AFE 端口使能会 -110 超时 → **没声音**。
- `pd-mapper` 用户态**默认禁用**：内核的 `qcom_pd_mapper` 模块已经提供了必需的电源域映射。

### 4.5 阶段 02：先 `-S --needed`，再 `-Su` 全量升级

- `-S --needed` 只装列表里的包，**不升级 rootfs tarball 自带的旧包**；
  ALARM 的 tarball 常年落后仓库几周，于是会出现"新 `nftables` 配旧 `libnftnl`"
  这种**半升级**，运行时 `version 'LIBNFTNL_19' not found`，`dnsmasq` 直接起不来，
  而 **pacman 的依赖检查看不出来**。
- 所以装完列表后再 `-Su --noscriptlet --ignore linux-firmware` 对齐快照。
  `--ignore linux-firmware` 是刻意的：仓库里它已拆成 meta 包，升级会连带拉进
  `linux-firmware-{mediatek,nvidia,radeon,realtek}` **几个 GB** 的无关固件。
- 末尾还有**关键程序烟雾测试**（qemu 实跑 `bash/dnsmasq/nft/nmcli/iw/wpa_supplicant`，
  只把"库/符号加载失败"判为致命）—— 第二道防线，别删。

### 4.6 阶段 05 的 `libqrtr.so` 软链（CI 专属陷阱）

编出 `libqrtr.so.1` 后**必须**在 `$STAGE` 里建 `libqrtr.so` 软链：`-lqrtr` 只认
`libqrtr.so`/`libqrtr.a`。本地构建时 rootfs 里往往还留着上次装好的
`/usr/lib/libqrtr.so`，clang 的 sysroot 搜索路径会兜住，**所以在本地永远看不出问题**；
CI 是全新 rootfs → 后面 `rmtfs/pd-mapper/tqftpserv/qrtr-*` **全部链接失败**，
而脚本原来只 `warn` → 静默产出没有 Wi-Fi/音频的镜像。

现在产物校验改成**硬失败**（缺 `rmtfs`/`tqftpserv`/`libqrtr.so.1` 直接 `die`）。

### 4.7 设备树：厂商树 + 我们只动三处

`dtb/raphael-redmi-k20pro.dtb` 是**从运行中的设备导出 U-Boot 下发的 DT**，逐字节一致，
只做了：

1. **删掉 `slimcap-dai-link` / `slim-playback-dai-link`**：它们引用的 WCD9340 codec DAI
   常常枚举不出来（SLIMbus/ADSP 的 QMI 握手有竞态），一旦缺了就让**整块声卡**卡在
   `EPROBE_DEFER`（`aplay -l` 一个卡都没有）→ 删掉后声卡永远能注册。
   代价：**耳机通路（WCD9340）也就没了**，只留底部扬声器。
2. **删掉 `sound/audio-routing`**：之前为麦克风加的那批 `MCLK/MIC BIAS` 路由在这块
   codec 上控件不存在，会让 ASoC 报 `Failed to add route` 并**导致整块声卡注册失败**。
3. **补 `bluetooth.local-bd-address`**：构建时注入（每台设备不同，见 §3.3）。

改 DTB 的办法：`fdtget -l`/`fdtget`/`fdtput`（打包 `dtc`），或 `dtc -I dtb -O dts` 往返。
CI 的容器里要有 `dtc`（workflow 里已装）。

### 4.8 故意删掉 `regulatory.db`

内核 `CONFIG_CFG80211_REQUIRE_SIGNED_REGDB=y`，而 `wireless-regdb` 包的签名密钥
不被这个内核信任 → 加载必然失败。于是 `04-firmware.sh` **主动删掉**
`regulatory.db*`，退化成 world 域（Wi-Fi 能用，只是信道/功率按最保守来）。
dmesg 里那行 `Direct firmware load for regulatory.db failed` 是**预期的**，不用修。

---

## 5. 已修好的坑（症状 → 根因 → 修在哪 → 怎么验证）

> 这一节是全文最值钱的部分。**遇到问题先在这里找**。

### 5.1 镜像里所有文件属主变成 uid 1000 → 开机 mount 全失败

- **症状**：能开机但 `systemd-remount-fs` 等一堆服务失败；`/usr/bin/mount` 是 `setuid 1000`。
- **根因**：无 root 的 user namespace 构建里 `cp -a` 把宿主 uid 带进镜像。
- **修**：`lib.sh:normalize_ownership()` —— 灌数据前整树 chown 回 `0:0`、恢复 21 个
  setuid 清单、**断言 `/usr/bin/mount` 是 `0:0 4755`**；`/home/<user>` 单独给 1000:1000。
- **验证**：构建日志「校验通过: 0:0 4755 /usr/bin/mount」。

### 5.2 家目录属主是 root → 每次开机都弹初始设置向导

- **根因**：`/home/<user>` 是 `root:root`（userns 无法 chown 到 1000），KDE 存不了配置。
- **修**：`/etc/tmpfiles.d/raphael-home.conf` 里 `Z /home/<user> - 1000 1000 -`（**无条件写**），
  `raphael-firstboot.service` 首次开机再 `chown -R` 兜底，并预置
  `~/.config/plasmamobilerc` 的 `[InitialStart] wizardRun=true`。

### 5.3 熄屏/开机瞬间花屏 ★★★

- **症状**：开机、熄屏、亮度变化瞬间出现彩色条纹/雪花。
- **根因**：initramfs 里只有 `usr/lib/firmware/...`，**没有 `/lib -> usr/lib` 软链**，
  而内核固件加载器只按 `/lib/firmware` 找文件 →
  ```text
  [ 0.63s] msm_dpu: Direct firmware load for qcom/a630_sqe.fw failed with error -2
  [10.0s]  msm_dpu: loaded qcom/a630_sqe.fw from new location     ← 太晚了
  ```
  GPU 是在**没有 SQE 固件**的状态下初始化的。
- **修**：`08-initramfs.sh` 建 `ln -sfn usr/lib "$IR/lib"`。
- **验证（不用刷机）**：把新 initramfs 丢进手机 `/boot` 重启，`dmesg | grep -c "failed to load a630_sqe"` 应为 0，
  且 0.9 秒就出现 `loaded qcom/a630_sqe.fw`。

### 5.4 一调音量就"卡掉"、扬声器没声音 ★★★

- **症状**：拖音量条就卡几秒；扬声器始终无声；dmesg 每 3 秒刷：
  ```text
  qcom-q6afe: AFE enable for port 0x1006 failed -110          (ETIMEDOUT)
  q6afe-dai: ASoC error (-110): at snd_soc_dai_prepare() on QUAT_MI2S_RX
  ```
- **根因**：`pro-audio` 下 ACP 给 `pro-output-1` 选了 **`s16le 8ch`**，而 QUAT_MI2S 只吃 1/2 声道；
  每次 PCM 重开都重走 AFE 使能 → 卡；端口起不来 → 没声音。
- **修**：WirePlumber 规则钉死 `S16LE/48k/2ch` + `session.suspend-timeout-seconds=0`
  （避免反复重建 Q6 会话）。
- **验证（纯文本）**：`pactl list sinks | grep "Sample Specification"` 是 `s16le 2ch 48000Hz`；
  `dmesg | grep -c "AFE enable.*failed"` 为 0；播放时功放寄存器 `00:` 为 `0x0018`。

### 5.5 屏幕键盘能弹出，但字打不进输入框 / 关不掉

- **根因**：`QT_IM_MODULE`（单数）是给应用的、`QT_IM_MODULES`（复数）是给合成器的；
  全局设了 `fcitx` 之后键盘能弹但输入事件进不去；全局设 `qtvirtualkeyboard` 又会让
  plasma-keyboard 走它自己声明不支持的 client-side 路径而闪退。
- **正确组合**（三个地方都要对）：
  1. `~/.config/kwinrc` 的 `[Wayland] InputMethod[$e]=/usr/share/applications/org.kde.plasma.keyboard.desktop`
  2. **只有 KWin** 拿到 `QT_IM_MODULES=qtvirtualkeyboard`（systemd drop-in）
  3. plasma-keyboard 自己用 `Exec=env -u QT_IM_MODULES plasma-keyboard` 启动
  4. `/etc/environment` 里**不要**出现任何 `QT_IM_*`
- **不要装 fcitx5**：它和 plasma-keyboard 会互相抢输入法（真机实测：KWin 会莫名选中
  fcitx5，然后屏幕键盘反复闪退）。所以 `config/build.conf` 的 `PKGS_IME` 是空的、
  `07-desktop.sh` 也不再写 fcitx5/Rime 的任何配置。想用中州韵的用户自己装。
- **语言列表**：只能靠 KCM（系统设置 → 键盘 → 屏幕键盘 → 语言）写，
  `~/.config/plasma-keyboardrc` 的 `enabledLocales=zh_CN,en_US`
  —— **逗号后不能有空格**（KConfig 的 QStringList 不 trim，`"zh_CN, en_US"` 会变成非法的 `" en_US"`）。

### 5.6 开机 2 分钟（服务挡路）

- **根因**：`raphael-audio-init` 挂了 `Before=display-manager`（等 PipeWire/声卡，1 分 46 秒）；
  AUR 安装脚本挂在 `multi-user.target`（1 分 43 秒）。
- **修**：都改成 **timer**（`OnBootSec=12s` / `90s`），开机从 **2 分 01 秒 → 18.7 秒**
  （`systemd-analyze`：firmware 4.96 + loader 3.25 + kernel 1.70 + userspace 8.78）。

### 5.7 蓝牙完全不可用（`Invalid Index`）

- **根因链**：`btqca` 给设备设了 `HCI_QUIRK_USE_BDADDR_PROPERTY` → 内核从设备树父节点读
  `local-bd-address`；厂商 DT 里**没有**这个属性，控制器自身又上报全零 → `hci_power_on()`
  立刻关设备、不发 `Index Added`。
- **修**：① DT 注入 `local-bd-address`（§3.3）；② 用 `bluetooth` 分区里的**原厂 NVM**
  （`crnv21.bin`/`crbtfw21.tlv`）替换 `linux-firmware` 的通用版（板级校准不匹配）。

### 5.8 Wi-Fi 扫描不到任何 AP

- **根因**：`tqftpserv` 没跑 → ADSP/CDSP 拿不到固件 → QRTR 里没有 `WLFW(69)` 服务 →
  `ath10k` 拿不到网卡。另外还需要 `rmtfs` 与 `qcom_pd_mapper` 内核模块。
- **自查**：`qrtr-lookup | grep -i wlfw` 应该有 `ATH10k WLAN firmware service`。

### 5.9 有声音选项但一个输出设备都没有

- **根因**：pipewire/wireplumber 的**用户级** systemd 单元从没被 enable（镜像跳过了 pacman
  scriptlet，发行版 preset 没执行）。
- **修**：`07-desktop.sh` 里手工建 `sockets.target.wants/` 与 `pipewire.service.wants/` 的软链。

### 5.10 桌面起不来 / `plasma-bigscreen-inputhandler` 报 127

- **修**：把电视版 `plasma-bigscreen` 卸掉；`/etc/shells` 里补 `/usr/bin/zsh`（否则 SDDM 自动登录失败）。

---

## 6. 还没解决的 —— **建议从这里接着做**

| 方向 | 现状 | 建议下一步 |
|:--|:--|:--|
| **麦克风** | 采集链路已**全部上电**（`AMIC MUX0` 默认断开 + DT 缺 MCLK 都已修），但录到的**样本仍是全零** | 查 ADM/DSP 侧端口配置与模拟前端（micbias）；见 `notes/microphone-and-kernel-plan.md`。⚠️ **不要提前往 UCM 里加 `CapturePCM`**：打不开的采集设备会让 ACP 放弃整个 UCM，连扬声器一起消失 |
| **相机** | 主线没有 sm8150 的 CAMSS/CCI 设备树与 IMX586 等 sensor 驱动 | 见 `notes/camera.md`（含可行路线）。短期可用 USB(UVC) 摄像头，镜像里已有 `camera-check` 诊断脚本 |
| **耳机通路** | 为了保住声卡，已删掉 SLIMBUS 后端的 DAI link，**WCD9340 耳机输出不可用** | 想恢复要先解决 WCD9340 codec probe 竞态（QMI/SLIMbus 握手），再把 link 加回 DTB |
| **GPU** | 每次拉起 plasmashell 有 **1 次** `hangcheck recover`（可自恢复） | 属于 vendor 内核 + Mesa 层面；可试更新 Mesa/内核、或调 KWin 渲染后端（`KWIN_COMPOSE`） |
| **调制解调器** | `rmtfs`/`pd-mapper`/QRTR 都在跑，但没打通通话/数据 | 需要 modem 固件加载 + QMI 拨号栈（ModemManager）验证；`qrtr-lookup` 能看到 modem 服务是起点 |
| **蓝牙地址自动识别** | 现在靠构建/刷机时手填；公开镜像不带地址 | 在**不 erase dtbo** 的前提下，从 dtbo 里那份厂商 DT 自动读出地址并注入（或首次开机提示用户手填）。注意本项目刷机流程目前会清 dtbo |
| **挂起/休眠** | SM8150 只有 s2idle，且会出问题，已 mask | 用熄屏代替；想做得先解决 s2idle 崩溃 |
| **电源/散热** | 有 `power-profiles-daemon`、zram | 可做 CPU/GPU 频率策略、温控（thermal zones 已在 DT 里） |
| **系统更新** | 镜像里的包可与仓库同步（`pacman -Syu`） | 注意 `/boot` 上的 systemd-boot 与 rootfs 里的版本可能不同步，更新后按需重刷 `cache` |
| **双系统** | 现在是整机替换 | 可研究保留 Android + 从 cache 引导双启动 |

---

## 7. 常见改动的操作手册

| 想改什么 | 改哪里 | 怎么验证（**尽量不刷机**） |
|:--|:--|:--|
| 包列表 / 用户名 / 密码 / 镜像大小 | `config/build.conf` | `sudo ./build.sh --only 02 06 07 08 09 10` |
| 桌面/输入法/音频规则 | `scripts/07-desktop.sh` | 改完直接 `scp` 到手机 `/home/user/.config/...` 重启会话即可试 |
| 系统服务/路由/fstab | `scripts/06-config.sh` + `lib.sh` | 直接改手机上对应文件试，成了再回写脚本 |
| 内核命令行 / initramfs 内容 | `scripts/08-initramfs.sh`、`10-image-boot.sh` | **`scp` 新的 `initramfs` 到手机 `/boot` 重启**（不用刷机！） |
| 内核本身 | `config/build.conf` 的 `KERNEL_*`；内核来自 `GengWei1997/kernel-deb` 的 deb | 换 `/boot/linux.efi` + 重启；模块在 rootfs 里 |
| 设备树 | `dtb/raphael-redmi-k20pro.dtb`（`fdtget/fdtput`） | 改完 `scp` 到 `/boot/dtbs/qcom/` 重启 |
| CI 行为 | `.github/workflows/build.yml` | 手动 `gh workflow run build.yml -f upload_rootfs=true`，7 分钟出产物 |

**调试入口**：

```bash
# 手机侧（USB NCM 或 Wi-Fi 都能进）
ssh user@172.16.42.1                      # USB 直连，密码 1234
sudo dmesg | grep -iE "asoc|afe|q6|adreno|ath10k|hci"
sudo cat /sys/kernel/debug/asoc/Raphael/tfa987x.0-0034/dapm/"SPKR PWUP"   # 功放 DAPM
sudo grep '^00:' /sys/kernel/debug/regmap/0-0034/registers                # 功放 AMPE
sudo qrtr-lookup                          # qcom 各子系统服务列表
systemctl --failed ; systemd-analyze blame | head
```

```bash
# 宿主侧：读/改引导镜像里的文件（FAT32，不用挂载）
export MTOOLS_SKIP_CHECK=1 MTOOLSRC=/dev/null
M=tools/mtools/usr/bin
$M/mdir  -i out/boot-cache.img ::/
$M/mcopy -o -i out/boot-cache.img ::/dtbs/qcom/raphael-redmi-k20pro.dtb /tmp/x.dtb
fdtget /tmp/x.dtb /soc@0/geniqup@cc0000/serial@c8c000/bluetooth local-bd-address
lsinitcpio <(zstd -dc work/initramfs.img) # 看 initramfs 里到底有什么
```

---

## 8. 雷区（一碰就炸 / 一出事就很难查）

1. **别把私密值写进仓库**：Wi-Fi 密码、`BT_MAC`、设备序列号、真实邮箱 →
   放 `config/local.conf`（已 gitignore）或 CI Secret。文档里的示例一律用假值。
2. **别在 user namespace 里造 btrfs 子卷**：会退化成 flat，而且老版本会写出
   "fstab 说 subvol、镜像却是 flat"的**开不了机**镜像（现已修，但构建日志里
   出现「回退单子卷布局」时请确认 fstab 也对齐了）。
3. **loop 设备**：宿主 `/dev/loop*` 缺失 → 回退 flat。注意**内核升级后没重启**时
   `/lib/modules/$(uname -r)` 可能不存在，`modprobe loop` 会失败。
4. **`erase dtbo` 之前先记蓝牙地址**（或者改用 `bt-mac.sh` 事后注入）。
5. **CI 上的现象不代表本地**：`-lqrtr` 那种"本地能过、CI 全挂"的 bug 已经出现过两次
   （libqrtr 软链、半升级），所以**改构建脚本后务必跑一次 CI**。
6. **产物校验不要降级成 warn**：`05-qcom.sh` 的硬失败与 `02-pacman.sh` 的烟雾测试
   都是"防止静默产出残废镜像"的保险，删掉它们等于把坑留给用户。
7. **不要在手机上 `pacman -Syu` 之后立刻重启**（`/boot` 上的 systemd-boot 与 rootfs
   里的版本可能不同步）；要更新引导器就重新生成并刷 `cache`。
8. **音频相关改动的顺序**：先 `pro-audio`，再 mixer 路由，最后 WirePlumber 格式规则；
   少任何一环都会回到"没声音/一调就卡"。

---

## 9. 本轮（2026-10-02）提交清单

| 提交 | 解决了什么 |
|:--|:--|
| `27e639c` | 构建账号默认从 `winter` 改成 `user`，全流程走 `USERNAME` 变量（含两个单引号 heredoc 的占位符替换） |
| `9ba837a` | 音频：给 `MultiMedia1` 接上后端（`aplay`/`hw:0,0` 之前"播放成功但没声"） |
| `bb67f86` | fstab 与镜像布局一致性（防开不了机）+ CI 蓝牙地址格式归一化 |
| `e2c9af0` | **CI 产物没 Wi-Fi/没声音**：阶段 05 缺 `libqrtr.so` 软链 → 硬失败 |
| `9f9c3d7` | **花屏真凶**：initramfs 缺 `/lib` 软链；+ 阶段 02 关键程序烟雾测试 |
| `82d8ddb` | 关掉 `systemd-networkd-wait-online`（开机失败单元归零） |
| `4db95e1` | 阶段 02 加全量升级 `-Su --ignore linux-firmware`（修半升级） |
| `f1741ed` | README 补录三个根因（§8.12 花屏 / §8.13 CI 缺 qcom / §8.14 半升级） |
| `890dda4` `c0e5bfa` | 蓝牙地址归一化放宽 + 失败时打印"提取到几位十六进制" |
| `3105d7c` | `scripts/bt-mac.sh` + `11-flash.sh --bt-mac`：**刷机时注入地址**，公开镜像不用重新构建 |
| 本次 | 文档与示例地址脱敏（真实蓝牙地址 → 假示例 `11 22 33 44 55 66`） |

**当时真机验证结论**：GitHub 产物**原样下载、校验、直接刷入**可正常开机；
`user` 账号 / subvol 布局 / `pro-audio` 两个 sink / AFE 失败 0 条 / GPU 固件 0.915 s 加载 /
qcom 三件套齐全 + WLFW 服务在 / 开机失败单元 0 个 / 启动 18.7 s。

---

## 10. 一分钟速查

```bash
# 构建
sudo ./build.sh                                   # 全量
sudo ./build.sh --only 06 07 08 09 10             # 只重打包（约 2 分钟）
./scripts/11-flash.sh --flash --bt-mac "11 22 33 44 55 66"

# 云端
gh workflow run build.yml -f upload_rootfs=true   # 7 分钟出 boot-cache + rootfs-release

# 手机上
ssh user@172.16.42.1                              # USB NCM（密码 1234）
scp work/initramfs.img user@172.16.42.1:/tmp/ && \
  ssh user@172.16.42.1 'echo 1234 | sudo -S cp /tmp/initramfs.img /boot/initramfs && sudo reboot'
```
