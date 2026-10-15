# 刷机就绪清单（2026-10-15）

> 这份清单是给"准备把镜像刷进手机"这一刻用的。设备侧的一切都已经实机验证过，
> 镜像内容与当时验证的设备状态**逐项等价**（已核对：构建后 scripts/config/dtb 零改动）。

## 1. 前置：让手机进入 fastboot

**只能靠硬件按键**（软件途径全部验证无效，见下面"为什么不能自动进"）：

```
手机关机 → 按住【音量减 + 电源】不放 → 出现 fastboot 界面
然后在电脑上确认：  fastboot devices      # 应列出 f710764a 之类
```

## 2. 刷入

```bash
cd ~/Documents/VSCode/raphael-arch
echo yes | ./scripts/11-flash.sh --flash        # 需要 sudo 密码 031210
```

脚本会做：`erase dtbo / boot / cache / userdata` → 刷 U-Boot、cache(引导)、userdata(rootfs)。
**userdata 会被清空**（用户已确认接受）。

### 构建产物与校验和（刷前可核对）

| 文件 | 大小 | 说明 |
|:--|:--|:--|
| `out/rootfs.sparse.img` | 3368260532 字节 | 根分区（sparse，fastboot 直接刷）|
| `out/boot-cache.img` | 268435456 字节 | FAT 引导分区（内核/initramfs/DTB/loader）|

md5（每次重新构建后会变，刷前用 `md5sum out/*.img` 重新取即可；本轮记录值：
`rootfs.sparse.img = 45c31c31b1329083f206f4c7578e2343`、
`boot-cache.img = df23120dd8941ca124807c62b51b2c5f`）。

## 3. 首次开机（约 1-2 分钟，属正常）

会自动完成：根分区扩容、pacman 密钥环初始化、在 `@swap` 子卷建 4G 交换文件、
拉起 `raphael-audio-init`（它会**等 SLIMBUS codec 就绪再加载声卡**，最多 40 秒）。

## 4. 刷后验证（一条命令）

```bash
# 电脑侧（手机走 USB 网卡 172.16.42.1，用户 winter / 密码 031210）
# 说明: SSH 登录用户**就是 winter**, 所以 systemctl --user 直接可用;
#       dmesg / aplay 需要 root, 先 sudo -v 缓存一次凭据。
ssh winter@172.16.42.1 'sudo -v && bash -s' <<'EOF'
echo "桌面单元: $(systemctl --user is-active plasma-kwin_wayland plasma-plasmashell \
  plasma-ksmserver plasma-kded6 | tr '\n' ' ')"
echo "链路: $(sudo dmesg | grep -oE 'OK: [0-9]+ links' | tail -1)  卡片: $(sudo aplay -l | grep -c '^card')"
echo "失败单元: 系统 $(systemctl --failed --no-legend | wc -l)"
echo "GPU fault: $(sudo dmesg | grep -c 'source=CCU')  屏幕: $(cat /sys/class/drm/card0-DSI-1/dpms)"
echo "面板: $(qdbus6 org.kde.plasmashell /PlasmaShell \
  org.kde.PlasmaShell.evaluateScript 'print(panels().length)')"
EOF
```

**实测输出参考**（本机刚跑的结果）：

```
桌面单元: active active active active
链路: OK: 5 links  卡片: 2
失败单元: 系统 0
GPU fault: 138  屏幕: Off        ← 138 是**累计**值; 息屏时**速率**为 0/分钟
面板: 1
```

> `GPU fault` 计数会随屏幕活动累积（dmesg 环形缓冲回绕后甚至会下降），
> 所以**不要拿累计值做对比** —— 要看速率就用设备上装的
> `raphael-health.timer`（每 5 分钟记一次"最近 5 分钟增量"，见
> `/var/log/raphael-health.log`）。

期望值：桌面 4 个单元都是 `active`、链路 `OK: 5 links`、卡片 2、失败单元 0。
（GPU fault 数量会随屏幕活动变化，**息屏时应为 0/分钟**，见 README 的花屏一节。）

## 4.5 出问题时的回退（不用刷机）

引导菜单里有 **known-good** 条目（`arch-good.conf`），指向镜像里另存的一份
已验证可用的内核 + initramfs + DTB。以后换内核 / 改设备树后如果起不来，
**开机时在 menu 里选 known-good** 即可回到可用状态。

设备上还有只读健康日志（每 5 分钟一行）：
`sudo cat /var/log/raphael-health.log | column -t | tail -20`

## 5. 想回 Android

`fastboot flash boot <备份的boot.img>`，或用小米线刷包恢复（脚本会提示备份路径）。

## 6. 为什么不能让 agent 自己进 fastboot（已逐一验证）

| 途径 | 结果 |
|:--|:--|
| Android BCB（misc 分区写 `boot-fastboot` / `boot-bootloader`）| bootloader **不读** misc ✗ |
| `systemctl reboot bootloader` | systemd 262 无此参数 ✗ |
| U-Boot 环境变量 | 环境编译在内核里，无可写存储 ✗ |
| EFI 启动项（`Boot####`）| 只有固件内部 `csi 0-5` / `lkmap 0`，无 fastboot 入口 ✗ |

## 7. 已知限制（刷完仍然存在）

| 项 | 状态 |
|:--|:--|
| **麦克风** | ✗ ADSP 的 ADM 拒绝采集路由（`ADM_CMD_MATRIX_MAP_ROUTINGS_V5` → error 2）。病因链见 [microphone-and-kernel-plan.md](microphone-and-kernel-plan.md)，需要带调试的自编译内核，**且必须在能进 fastboot 时做** |
| 3.5mm 耳机 | 链路与自动切换都验证过（插=走 WCD9340 并静音扬声器），**实际出声待插耳机确认** |
| 投屏 | 驱动会注册 DRM 卡、热插拔不会崩桌面；**实际出画待转接器确认** |
| GPU | CCU fault 只在屏幕活跃时出现（息屏 0/分钟）；用户实测无可见花屏 |

---

## 构建阶段的环境坑（2026-10-15 记录）

### ⚠️ 不要在开发机上跑全量镜像构建

在开发机上跑 `./build.sh` 会让**整台机器重启**。原因是阶段 02 用
`pacman --arch aarch64 -r <rootfs>` 安装 145 个 aarch64 软件包，**每个包的
安装脚本都要经 qemu-user 模拟执行**，再加上 3.5G 包缓存和 bwrap
（`--unshare-pid --die-with-parent`）嵌套，负载和内存压力会把宿主机压垮。
实测连续三次都在阶段 02 中途整机重启。

**绕过去的办法：在设备本机原生构建。** 设备就是 aarch64，不需要 qemu：

```
# 设备上（raphael），资源充足
根分区 469G / 可用 460G     内存 7.2G / 可用 5.2G
git / pacman / make / gcc / clang 均已就绪（只缺 dtc，pacman -S dtc 即可）
```

把仓库和 `dl/` 缓存（约 1.4G）传到设备后直接 `./build.sh`，全程原生执行，
没有模拟开销，也不会影响开发机。

### 若一定要在开发机上跑，至少保证可断点续跑

本轮为此加了三个防御（都已入仓）：

1. **`scripts/02-pacman.sh` 缓存体检** —— 把解不开的包直接删掉再装。
   之前 `work/pkgcache` 里有 13 个属主异常/损坏的包，pacman 报
   "无效或已损坏的软件包(检验值)"，而 `--noconfirm` 是**开始安装之后**才逐个
   删除，第一个坏包就让整个事务提交失败，于是每次重跑都卡在同一处。
2. **`--overwrite '*'`** —— 这是"往已解包的 rootfs 里补软件"，不是全新安装。
   rootfs tarball 里已带 giflib 等包的部分文件，仓库版本换了路径就会以
   "文件已存在"拒绝整个事务（实测卡在 giflib，后面 144 个包一个都装不上）。
3. **自动清理 `db.lck`** —— 上一次被中断的构建会留下数据库锁，下次同步直接报
   "无法锁定数据库"。

另：`work/` 下若混入了 root/nobody 属主的文件（早先某次构建用 sudo 跑过），
`rm -rf` 会因目录非本人所有而失败。开发机 sudo 被 `no new privileges` 拦住时，
把这些目录 `mv` 到一边（`mv` 只需要父目录写权限）比 `chown` 更可行。

### 已验证：关键脚本产物与真机一致

即使不跑完整构建，也能确认修复会正确进镜像 —— 本地用构建脚本的逻辑
（`patch_sound_routing` + UCM heredoc）生成产物，再与设备上**已验证可用**的
文件逐字节比对：

| 产物 | 构建脚本 | 设备（已验证） | 结论 |
|:--|:--|:--|:--|
| `raphael-redmi-k20pro.dtb` | md5 `3bcded4b80a5` | md5 `3bcded4b80a5` | **完全一致** |
| `raphael-audio-routing.sh` | — | — | **逐字节一致** |
| `raphael-audio-init.sh` | — | — | 去注释后可执行行完全一致 |
| `HiFi.conf` | 3489 字节 | 3101 字节 | 规范化后语义完全一致（仅空列表排版差异） |
| `<card>.conf` | `SectionUseCase."HiFi"` | 同左 | 一致 |

---

## 设备原生构建实战记录（2026-10-15）

### 结论

在设备上原生构建**完全可行**，全程 **11 分 8 秒**跑完 `00 → 10`，
产出可直接刷写的镜像，且开发机零负载。

```
开发机 (x86_64 + qemu):  三次都在阶段 02 把整机压重启
设备   (aarch64 原生):   11 分 8 秒跑完, 一次通过
```

### 步骤

```bash
# 1) 设备装构建依赖 (系统里没有的)
sudo pacman -S --needed dtc fakeroot mtools cpio android-tools

# 2) 克隆仓库 (只有 3.6M, .git 才 7.2M)
git clone https://github.com/Winter21c/archlinux-xiaomi-raphael.git ~/raphael-build
cd ~/raphael-build

# 3) 写本机私有配置 (决定桌面形态 / 用户 / 蓝牙地址)
cat > config/local.conf <<'CONF'
DESKTOPS="plasma-desktop"          # KDE 桌面形态 -> 自动带 fcitx5 + Rime
BT_MAC="f0 04 e0 78 00 02"
USERNAME="winter"
USER_PASSWORD="031210"
ROOT_PASSWORD="031210"
CONF

# 4) ★ 必须用真 root: 非 root 时无法把属主归一回 root:root,
#    产出的镜像 setuid 全失效 (sudo/mount/sshd 全挂, 进不了桌面)
sudo ./build.sh                    # 00 -> 10, 约 11 分钟
```

产物在 `out/`：

| 文件 | 大小 | 刷到 |
|:--|:--|:--|
| `out/rootfs.sparse.img` | 5.4G | `userdata` |
| `out/boot-cache.img` | 256M | `cache` |
| `work/uboot/u-boot.img` | 656K | `boot` |

`rootfs.sparse.img` 由 `img2simg out/rootfs.img out/rootfs.sparse.img 4096` 生成
（需要 `android-tools`；没有它阶段 09 只会留下 14G 的 raw 镜像）。

### 本轮为"能在 aarch64 上原生构建"修的 5 个 bug

这套脚本原本只在 x86_64 开发机上跑过，搬到设备上暴露了一串硬编码假设：

| # | 位置 | 症状 | 修法 |
|:--|:--|:--|:--|
| 1 | `lib.sh` `setup_mtools` | 无条件下 x86_64 的 mtools 包 → `mcopy: cannot execute binary file` | 先找宿主自带 → 再按 `uname -m` 选仓库 |
| 2 | `lib.sh` `setup_qemu_shim`/`gq` | 无条件 `cp /usr/bin/qemu-aarch64` → `No such file` | 原生 aarch64 直接 `chroot`, 不装垫片 |
| 3 | `08-initramfs.sh` | 写死 `/usr/bin/qemu-aarch64` 读 busybox applet → 空列表 → "缺少 applet: mount" | 新增 `gbin()` 按宿主架构执行 |
| 4 | 宿主依赖 | 跑到阶段 08 才发现没装 `cpio` | 新增 `require_host_tools()` 开头一次性检查并给出安装命令 |
| 5 | `config/build.conf` | `local.conf` 里写 `DESKTOPS` **不生效** (它被放在文件最后 source, 而 DESKTOPS 早就归一化完了) | source 两次: 开头(让 DESKTOPS 生效) + 末尾(让 USERNAME 等被覆盖) |

### ★ 最严重的一个：补丁没进"真正被引导的那份 DTB"

这个**只有把镜像真做出来、拆开看才会发现** —— 构建全程 0 错误、产物齐全。

拆开 `out/boot-cache.img`：

```
dtbs/qcom/raphael-redmi-k20pro.dtb        108477  SLIMBUS_0_TX=0   <- arch.conf 用的
dtbs/qcom/raphael-redmi-k20pro-good.dtb   108477  SLIMBUS_0_TX=0
dtbs/qcom/sm8150-xiaomi-raphael.dtb       108460  SLIMBUS_0_TX=1   <- 补丁在这儿
```

`03-kernel.sh` 补的是 `sm8150-xiaomi-raphael.dtb`，而
`loader/entries/arch.conf` 里写的是 `raphael-redmi-k20pro.dtb` ——
**补丁打在一份永远不会被引导的 DTB 上**，刷进去麦克风照样不可用。

根因是 `10-image-boot.sh` 无条件优先了仓库自带的 `dtb/raphael-redmi-k20pro.dtb`
（早期从 U-Boot 导出、还把 slim 链路删掉的版本），而旁边的注释写的却是
"直接用内核作者 deb 里那份" —— 代码和注释矛盾。

修法：`patch_sound_routing()` 移到 `lib.sh`，阶段 10 改为
**优先内核 deb 那份 DTB**（真机验证过能用的就是它），并在阶段 10
**再补一次**采集路由，保证"被引导的那份"一定带 `SLIMBUS_0_TX`。

修后复查：

```
启动 DTB 来源: usr/lib/modules/7.2.0-.../dtbs/qcom/sm8150-xiaomi-raphael.dtb
采集路由补丁: DTB 里已存在 SLIMBUS_0_TX<->AIF1 CAP, 跳过
设备树: 使用修补版, 并已注入本机蓝牙地址 (f0 04 e0 78 00 02)

dtbs/qcom/raphael-redmi-k20pro.dtb        108497  SLIMBUS_0_TX=1  蓝牙=1  ✓
dtbs/qcom/raphael-redmi-k20pro-good.dtb   108497  SLIMBUS_0_TX=1  蓝牙=1  ✓
```

108497 字节与真机上那份**已验证可用**的 DTB 完全同尺寸，只多注入了蓝牙地址。

### 镜像内容核验

| 项目 | 结果 |
|:--|:--|
| `sudo`/`passwd`/`su`/`mount` | `root:root -rwsr-xr-x`（setuid 完好）|
| 桌面 | `plasma-desktop 6.7.5-1`，**没有** plasma-mobile |
| 输入法 | `fcitx5 5.1.23-1` + `fcitx5-rime 5.1.16-1` + `fcitx5-qt` |
| 用户 | `winter:x:1000:1000` |
| 自动登录 | `User=winter` |
| UCM | `HiFi.conf` 3489 字节，含 `SectionDevice."Mic"` |
| `<card>.conf` | `Syntax 3` + `SectionUseCase."HiFi"`（引号正确）|
| 采集路由保活 | `raphael-audio-routing.sh` 里 2 处 |
| 投屏驱动 | `updates/msdisp/usbdisp_drm.ko` |
| 启动 DTB | 采集路由 = 1，蓝牙地址 = 1 |

### 传到开发机

USB NCM 链路实测 **43 MB/s**，5.4G 约 3 分钟：

```bash
scp winter@172.16.42.1:~/raphael-build/out/rootfs.sparse.img   out/
scp winter@172.16.42.1:~/raphael-build/out/boot-cache.img      out/
scp winter@172.16.42.1:~/raphael-build/work/uboot/u-boot.img   work/uboot/
```

三个文件的 md5 两端逐字节一致：

```
c8cc529ce1ea237018b1ede1630a83d4  boot-cache.img
556990e364c4b2c290859add5844c0a1  rootfs.sparse.img
f6db3e66b6dffc8d1cbd7322978b6516  u-boot.img
```

### 刷机（需要人工按键）

```bash
echo yes | ./scripts/11-flash.sh --flash          # 或先 --dry-run 看计划
```

手机关机后按住 **音量- + 电源** 进 fastboot，然后执行上面的命令。
镜像里已注入蓝牙地址，**不需要**再加 `--bt-mac`。

---

## 第二轮：刷完第一次镜像后发现的 2 个问题（2026-10-15 夜）

第一次刷入后跑 46 项回归，41/46。逐条查下来是 2 个真实缺陷 + 3 个预期行为。

### 缺陷 1：`raphael-audio-routing.sh` 少了执行位

```
✗ routing service 结果   exit-code (期望 success)
✗ 非零采样占比           9% (期望 >50%)
```

systemd 报 `status=203/EXEC`、`Permission denied`。同目录其它脚本都是 755，
只有它是 644 —— `06-config.sh` 生成完这个脚本后只做了 `sed` 替换 `@USER@`，
**漏了 `chmod 755`**。

后果不止"服务失败"：这个服务是采集路由的保活器，它不跑，PipeWire/ACP 就会
把 MM2 的 TX 路由复位，录音只剩个位数百分比非零 —— 看起来像"麦克风又坏了"。

⚠️ 特别阴的一点：手工 `bash /usr/local/sbin/raphael-audio-routing.sh` 是**能跑通**的
（bash 不需要 +x），所以只读脚本逻辑怎么查都查不出来，必须看 `status=203/EXEC`。

补上后真机复测：**非零 9% → 96%**，峰值 1001，0 失败单元。

### 缺陷 2：btrfs 子卷退化成 flat

第一次构建出来是单子卷（`fstab` 里只有 `/`，没有 `subvol=`），
而你要求的 `@`/`@home`/`@swap` 没了。

原因：`09-image-rootfs.sh` 建子卷需要 `mount -o loop`，而设备上 **loop 模块没加载**
（`lsmod | grep loop` = 0，`/dev/loop0` 不存在），于是脚本自动回退成
`btrfs-flat` 并把 fstab 重写 —— 这是它的正常兜底，不是 bug。

修法：构建前 `modprobe loop` + 写 `/etc/modules-load.d/raphael-loop.conf`。
重建后日志：

```
子卷完成: /@ (默认子卷) + /@home (/home) + /@swap (/swap)
(布局 btrfs-subvol; ...)
```

fstab 三条都对（swap 子卷还带 `nodatacow,compress=no`，交换文件必须如此）。
镜像也从 5.4G 缩到 **3.45G**（子卷 + 压缩更省）。

### 三个"预期行为"，不是缺陷

| 回归项 | 说明 |
|:--|:--|
| `wld0 已获取 IP` 无 | 新镜像里**不该**有 Wi-Fi 密码（镜像里塞密码是安全问题）。重新 `nmcli device wifi connect` 即可 |
| `btrfs @/@home/@swap 三子卷` 0 | 就是缺陷 2 |
| `swap 已启用` | 首启动由 `raphael-swapfile.sh` 在 `@swap` 里建 `/swap/swapfile`，正常 |

### ★ 设备端构建的完整依赖（新镜像里默认没有，必须先装）

```bash
sudo pacman -S --needed \
    dtc fakeroot mtools cpio android-tools \
    make clang lld llvm bc flex bison pahole
sudo modprobe loop && echo loop > /etc/modules-load.d/raphael-loop.conf
```

第一次刷完的镜像里这些**一个都没有**（`make: command not found`），
所以第二轮构建是一边失败一边补出来的：

| 缺什么 | 报错 |
|:--|:--|
| `make` / `clang` / `lld` | `编译 fixdep` → `fixdep 没编出来` |
| `bc` `flex` `bison` `pahole` | 同上（内核 scripts 编译需要）|
| `cpio` | 阶段 08 打包 initramfs 时 `command not found` |
| `loop` 模块 | 阶段 09 静默退化 flat 布局（不报错，只在日志里写一行）|

### ⚠️ 千万不要 `chown -R` 构建目录

我在补依赖的脚本里顺手写了 `chown -R winter:winter "$D"`，结果把
`work/root` 也一起改了 —— **`chown` 会清掉 setuid 位**，于是阶段 09 的
安全检查正确地拒收：

```
ERROR: 属主归一化失败: setuid 程序属主不对, 这样的镜像刷进去开不了机
```

（`sudo` 变成 `-rwxr-xr-x` 而不是 `-rwsr-xr-x`。）
只 chown `config/` `scripts/` `logs/` `dl/` 这些，**别碰 `work/root`**。
恢复办法：`rm -rf work/root` 后从阶段 01 重新解包（以真 root）。

这个检查本身很值得保留 —— 它挡住的正是"刷进去开不了机"的镜像。
