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
