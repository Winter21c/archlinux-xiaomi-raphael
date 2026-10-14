---
type: concept
title: rootfs 布局决策与 fstab/引导参数一致性
description: lib.sh:rootfs_layout() 如何三选一（ext4 / btrfs-subvol / btrfs-flat）并把结果粘在 work/rootfs-layout，write_root_fstab() 如何作为唯一 fstab 生成点与 rootfs_uuid() 同源，以及阶段 06 的 fstab、阶段 09 实际造出的文件系统、阶段 10 的 rootfstype=/rootflags= 和运行时 initramfs 的 cmdline 解析如何被这一份决策牵住。含阶段 09 loop 回退时「先重写 fstab 再 mkfs -r」的硬顺序、四条不变量、/home 双写与 /swap 子卷、首启动 growfs 的原因。
tags: [rootfs, btrfs, fstab, subvolume, boot-parameters, image-build]
verified:
  - by: openwiki/0.7.2
    at: 2026-10-10T11:58:54.634Z
---

# rootfs 布局决策与 fstab/引导参数一致性

根文件系统的形态（`ext4` 还是 `btrfs`、有没有 `@` / `@home` / `@swap` 子卷）在本项目里**只判定一次**（[`scripts/lib.sh`](../../scripts/lib.sh#L310-L354)），然后被三处构建期消费者各自解读：阶段 06 按它写 `/etc/fstab`、阶段 09 按它造 `rootfs.img`、阶段 10 按它写 systemd-boot 条目里的 `rootfstype=` / `rootflags=`。还有第四处消费者在**运行时**：阶段 08 手工拼的 initramfs 在设备上解析内核命令行里的 `root=` / `rootfstype=` / `rootflags=`，才把根挂起来（[`scripts/08-initramfs.sh`](../../scripts/08-initramfs.sh#L114-L159)）。

这几处对布局的理解只要有一处跑偏，产出的就是**能刷进去但开不了机的镜像**——历史上真实发生过一次（见下文「历史事故」）。所以本页的重点不是「有哪几种布局」，而是布局信息怎么被单向传播、在哪些地方被兜住、哪里还没被兜住。

| 环节 | 谁写 / 谁读 | 落点 | 不一致的表现 |
|:--|:--|:--|:--|
| 布局判定 | 写 | `work/rootfs-layout`（`lib.sh:rootfs_layout()`） | 缓存粘性：一次无 root 构建落下的 `btrfs-flat` 会一直粘着 |
| fstab | 写 | `$ROOT/etc/fstab`（`lib.sh:write_root_fstab()`，阶段 06 与 09 各写一次） | 根行写 `subvol=/@` 而镜像里没有 `@` → 挂根失败 → 开不了机 |
| 镜像 | 读（决定成像方式） | [`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L103-L172) | 回退成 flat 却没重写 fstab = 那个历史事故 |
| 引导条目 | 读 | [`scripts/10-image-boot.sh`](../../scripts/10-image-boot.sh#L95-L118) 的 `rootfstype=` / `rootflags=` | 与镜像布局错位，和上面同一种失败 |
| 运行时 | 读（解析 cmdline） | [`scripts/08-initramfs.sh`](../../scripts/08-initramfs.sh#L114-L166) 里 `/init` 对 `root=` / `rootfstype=` / `rootflags=` 的解析 | 解析不到根设备或挂载失败 → 救援 shell |

## 四条不变量

改动这一带之前，先把下面四条当成硬约束。它们每一条都对应一次真实故障或一次刻意反着写的注释。

| # | 不变量 | 单一来源 | 违反后的具体症状 |
|:--|:--|:--|:--|
| 1 | **布局三处一致**：06 写进镜像的 `/etc/fstab`、09 实际造出的文件系统、10 写进 loader 条目的 `rootfstype=` / `rootflags=` 必须描述同一种布局 | `work/rootfs-layout` | 内核按 `subvol=/@` 去挂一个没有 `@` 子卷的 btrfs → initramfs 挂根失败、落进救援 shell；表现为「构建成功、刷进去起不来」 |
| 2 | **UUID 同源**：文件系统的 `-U`、fstab 的 `UUID=`、loader 的 `root=UUID=` 必须来自同一份 `work/rootfs.uuid` | `work/rootfs.uuid`（`rootfs_uuid()`） | 新的 `boot-cache.img` 配旧的 rootfs 镜像时，initramfs「无法解析根设备」→ 救援 shell。两个产物必须成套构建、成套刷写 |
| 3 | **根行不能加 `nofail`，`/home` 与 `/swap` 必须加 `nofail`** | `lib.sh:write_root_fstab()` | 根加 `nofail` → systemd 可能跳过「把根重挂成 rw」，根停在只读 → `sshd`（生成主机密钥）、`usb-ncm`（写 configfs）等一串单元失败；`/home` 不加 `nofail` → `@home` 挂不上就把整机拖进 emergency mode |
| 4 | **`@swap` 必须以 `nodatacow,compress=no` 挂载**，交换文件先 `chattr +C` 再写数据 | `write_root_fstab()` + `raphael-swapfile.sh` | btrfs 交换文件落在 cow/被压缩的数据上 → `swapon` 失败；脚本里的 `swapon` 带 `\|\| true`，所以症状是**静默地**只剩 zram 交换 |

前两条决定「能不能开机」，后两条决定「起来之后是不是半残」。

## 历史事故：缓存说 subvol，镜像里却是 flat

`lib.sh` 的注释里记着这次事故，`HANDOVER` 也把它列为「改之前务必读」的设计决策（[`scripts/lib.sh`](../../scripts/lib.sh#L395-L400)、[`HANDOVER.md`](../../HANDOVER.md#L195-L205)）：`work/rootfs-layout` 缓存里写着 `btrfs-subvol`，阶段 06 据此把 fstab 写成 `subvol=/@`；但阶段 09 的 `mount -o loop,compress=...` 失败（宿主内核没带 loop 模块等），实际回退成了 `btrfs-flat`。结果镜像里**根本没有 `@` 子卷**，内核却按 fstab/引导参数里的 `subvol=/@` 去找它——挂根失败，落进 initramfs 的救援 shell。

今天这条路径由三件事共同兜住，缺一个就会复发：

1. fstab 只有 `write_root_fstab()` 一个生成器，阶段 06 与 09 各写一次，两次都是 `> "$ROOT/etc/fstab"` 的幂等覆盖，所以不存在「谁先写谁赢」的歧义（[`scripts/06-config.sh`](../../scripts/06-config.sh#L55-L70)）。
2. 阶段 09 的回退分支**必须先重写 fstab、再 `mkfs -r`**——晚一步改就来不及了（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L137-L146)）。
3. 阶段 09 末尾把最终布局写回 `work/rootfs-layout`，让阶段 10 生成匹配的 `rootflags=`（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L183-L185)）；同时在 `btrfs-subvol` 布局里把 `@` 设为**默认子卷**（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L131-L133)），即使引导参数里的 `subvol=` 整个丢了，内核挂到的也还是 `@` 的内容——这是第二道保险。

[HANDOVER.md](../../HANDOVER.md#L445-L449) 的「雷区」一节把它列为第 2 条（「别在 user namespace 里造 btrfs 子卷」），并给出排障动作：构建日志里出现「回退单子卷布局」时，要确认 fstab 也已经对齐了。

回退时日志里会留下 `warn "loop 挂载失败 (容器缺 /dev/loop*?) -> 回退单子卷布局"` 这行。构建「成功」但出现它，意味着这次产出的不是子卷布局（snapper 随后也会在设备上自动跳过）。

## 布局只判定一次：`rootfs_layout()`

布局判定集中在 [`scripts/lib.sh`](../../scripts/lib.sh#L310-L354) 的 `rootfs_layout()`，返回值只有三种：

| 返回值 | 含义 | 什么时候得到 |
|:--|:--|:--|
| `ext4` | 传统 ext4 镜像 | `ROOTFS_TYPE` 不是 `btrfs`，或宿主没有 `mkfs.btrfs`，或强制值不是两个 btrfs 取值之一 |
| `btrfs-subvol` | btrfs + `@` / `@home` / `@swap` 子卷（参考 Shorin 指南） | 有 root（uid 0）、有 `mkfs.btrfs`，且 256 MB 探测文件能 `mount -o loop` |
| `btrfs-flat` | btrfs 单子卷，数据在顶层，无子卷 | 没有 root（建子卷必须挂载文件系统），或 loop 挂载探测失败 |

判定顺序是有意义的：`RAPHAEL_FORCE_LAYOUT` 优先于一切；`ROOTFS_TYPE` 优先于权限；权限优先于可执行文件是否存在；最后才是 loop 探测。

```mermaid
flowchart TD
  A["rootfs_layout 被调用"] --> B{"work/rootfs-layout 有缓存且未设 RAPHAEL_FORCE_LAYOUT"}
  B -- 是 --> Z["直接返回缓存值 不再探测"]
  B -- 否 --> C{"设了 RAPHAEL_FORCE_LAYOUT"}
  C -- 是 --> D["layout 取强制值 不做取值校验"]
  C -- 否 --> E{"ROOTFS_TYPE 是 btrfs"}
  E -- 否 --> F["layout = ext4"]
  E -- 是 --> G{"uid 为 0"}
  G -- 否 --> H["layout = btrfs-flat 无 root 建不了子卷"]
  G -- 是 --> I{"mkfs.btrfs 可用"}
  I -- 否 --> F
  I -- 是 --> J{"256M 探测文件能 loop 挂载"}
  J -- 是 --> K["layout = btrfs-subvol"]
  J -- 否 --> H
  D --> W["写回 work/rootfs-layout"]
  F --> W
  H --> W
  K --> W
```

上图：`rootfs_layout()` 的判定分支——短路点在最前面的缓存，出口只有 `ext4` / `btrfs-flat` / `btrfs-subvol` 三个。

### 缓存是粘性的

结果写在 `work/rootfs-layout`（`WORK="$PROJ/work"`，见 [`scripts/lib.sh`](../../scripts/lib.sh#L15-L23)）。只要该文件非空且没设 `RAPHAEL_FORCE_LAYOUT`，函数就 `cat` 它并直接返回，**不会重新探测**（[`scripts/lib.sh`](../../scripts/lib.sh#L317-L320)）。在全量构建里阶段 06 是第一个调用者（[`scripts/06-config.sh`](../../scripts/06-config.sh#L64-L69)），所以缓存通常由 06 那次调用落地；09 与 10 只读它，09 中途唯一改写它的地方是 loop 回退分支，末尾再把最终值写回一次（正常路径下就是同一个值）。由此得到几条操作事实：

- 一次无 root 构建落下的 `btrfs-flat` 会一直粘着，之后即使用 `sudo ./build.sh` 也不会自动升级成 `@` / `@home` 布局——要换布局必须删掉 `work/rootfs-layout`，或显式 `RAPHAEL_FORCE_LAYOUT=btrfs-subvol`。
- 反过来，强制值本身也会被写回缓存（[`scripts/lib.sh`](../../scripts/lib.sh#L351-L353)），所以「临时强制一次」实际上会持久化，之后的阶段（甚至之后的构建）都会读到它。`build.sh --only` / `--from` 的部分重建同样继续读 `work/` 里的旧值（[`build.sh`](../../build.sh#L51-L75)）。
- 强制值**不做取值校验**：写成 `RAPHAEL_FORCE_LAYOUT=brtfs-subvol` 这类拼写错误时，三处消费者会一致地走进各自的 `*)` 兜底分支（fstab 的 `*)` 写 ext4 行、阶段 09 的 `*)` 走 `mke2fs -d`、阶段 10 的 `*)` 给 `ext4`），结果是一个**自洽但非你所愿**的 ext4 镜像。这不会造成不一致，只会让这个调试开关容易误用。

### loop 探测自身的兜底

探测前如果宿主缺 `/dev/loop-control`，函数会自己 `modprobe loop` 并 `mknod /dev/loop0..7` 补齐设备节点（[`scripts/lib.sh`](../../scripts/lib.sh#L331-L337)），所以「容器里没有 loop 设备节点」并不必然导致退化成 flat——CI 正是用同样几个 `mknod` 预先准备 loop 设备的（[`.github/workflows/build.yml`](../../.github/workflows/build.yml#L170-L188)）。真正会让探测失败的是**内核 loop 模块不可用，或模块树与运行内核不匹配（升级后没重启）**（[`HANDOVER.md`](../../HANDOVER.md#L195-L205)）。探测文件固定 256 MB 也是有原因的：btrfs 最小设备尺寸约 114 MB，注释明确记着「给 64M 会 mkfs 失败 → 误判 flat」（[`scripts/lib.sh`](../../scripts/lib.sh#L338-L349)）。

旋钮都集中在 [`config/build.conf`](../../config/build.conf#L26-L38)：`ROOTFS_TYPE` / `BTRFS_COMPRESS` / `BTRFS_SUBVOL_ROOT` / `BTRFS_SUBVOL_HOME` / `BTRFS_SUBVOL_SWAP` / `BTRFS_SWAP_SIZE`，默认 `btrfs` + `@` / `@home` / `@swap` + `zstd:3`；`IMAGE_SIZE`（默认 8G）只是**下限**，阶段 09 会按实际内容放大（[`config/build.conf`](../../config/build.conf#L43-L47)、[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L44-L60)）。`ROOTFS_UUID_FILE` 也在这里定义为 `work/rootfs.uuid`（[`config/build.conf`](../../config/build.conf#L47-L47)）。

## 一个决定，三处构建期消费 + 一处运行时消费

```mermaid
sequenceDiagram
  participant L as lib.sh rootfs_layout
  participant S06 as 阶段 06 写 fstab
  participant S09 as 阶段 09 造镜像
  participant S10 as 阶段 10 写引导参数
  participant RT as initramfs 运行时
  L->>S06: 布局 + rootfs UUID
  S06->>S06: write_root_fstab 写 etc/fstab
  L->>S09: 同一份缓存
  alt btrfs-subvol 且 loop 挂载成功
    S09->>S09: 建 @ @home @swap 并带 compress 挂载后 cp -a 灌数据
  else loop 挂载失败
    S09->>S09: 改写 work/rootfs-layout 为 btrfs-flat
    S09->>S09: 重写 etc/fstab 必须早于 mkfs -r
    S09->>S09: mkfs.btrfs -r 把 ROOT 整棵树写进镜像
  else btrfs-flat
    S09->>S09: 幂等重写 etc/fstab 再 mkfs.btrfs -r
  else ext4
    S09->>S09: mke2fs -d 不重写 etc/fstab
  end
  S09->>L: 末尾写回最终 LAYOUT 与 UUID
  L->>S10: 修正后的布局
  S10->>S10: rootfstype 与 rootflags 由 btrfs_opts 同源生成
  S10->>RT: root=UUID 与 rootflags 随 loader 条目上机
  RT->>RT: 解析 cmdline 后把根挂到 newroot 再 switch_root
```

上图：布局信息的传播路径、阶段 09 每个成像分支是否重写 fstab、回退时的落盘时点，以及它最终经内核命令行抵达 initramfs 的运行时。

- **阶段 09 造镜像的方式随布局而变**：`btrfs-subvol` 走「空文件系统 → 带 `compress=` loop 挂载 → `btrfs subvolume create` 建三个子卷 → `cp -a` 灌数据」，只有这样写进去的数据才真正被 zstd 压缩；`btrfs-flat` 与 `ext4` 分别用 `mkfs.btrfs -r` / `mke2fs -d` 直接把 `$ROOT` 树写进镜像，即**裸块写入、不压缩**（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L106-L172)）。
- **阶段 09 的回退顺序是硬约束**（下节单独展开）：loop 挂载失败时先改缓存、再改 fstab，**然后才** `mkfs.btrfs -r`。
- **阶段 09 末尾把最终 `LAYOUT` 与 UUID 写回 `work/`**（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L183-L185)），于是成套构建时**阶段 10 读到的必然是修正后的布局**。
- **同一布局决定 loader 参数**：阶段 10 按布局算出 `rootfstype=`，`btrfs-subvol` 额外把 `btrfs_opts "@"` 作为 `rootflags=`，`btrfs-flat` 用不带 `subvol=` 的 `btrfs_opts`，`ext4` 干脆不写 `rootflags=`（[`scripts/10-image-boot.sh`](../../scripts/10-image-boot.sh#L95-L118)）。fstab 里的 btrfs 选项和这里的 `rootflags=` 来自**同一个** `btrfs_opts()`（[`scripts/lib.sh`](../../scripts/lib.sh#L434-L439)），即 `compress=<BTRFS_COMPRESS>,noatime,ssd,discard=async,space_cache=v2`，有子卷时前面再加 `subvol=/<名字>`，所以两者不会各写一套 `compress=` / `noatime`。
- **initramfs 是唯一的运行时消费者**：它自己解析 `/proc/cmdline` 里的 `root=` / `rootfstype=` / `rootflags=`（再按 `rw` / `ro` 决定读写，缺省当 `rw`），用 `findfs` 或 `by-partlabel` 解析设备、最多轮询 10 秒（40 × 0.25 s），挂到 `/newroot` 后 `switch_root`（[`scripts/08-initramfs.sh`](../../scripts/08-initramfs.sh#L114-L166)）。也就是说 `rootflags=` 是布局进入运行时的第一道门；解析不到设备或挂载失败就落进 `rescue()` 的救援 shell。
- 一个容易读错的细节：`lib.sh` 的函数头注释把「06 fstab / 08 initramfs / 09 镜像 / 10 引导参数」并列成同一份结果的消费者（[`scripts/lib.sh`](../../scripts/lib.sh#L310-L316)），但阶段 08 **并不调用** `rootfs_layout()`——它产出的 `/init` 只在运行时读命令行。这也说得通：作者内核把 btrfs 内建（`modinfo btrfs` → `(builtin)`），busybox 的 `findfs` 也认得 btrfs，所以 btrfs 布局不需要任何文件系统模块进 initramfs，`rootfstype=` 只是被原样交给 `mount -t`（[`README.md`](../../README.md#L109-L110)、[`scripts/08-initramfs.sh`](../../scripts/08-initramfs.sh#L152-L159)）。阶段 08 自己带的那几个模块（`ufs-qcom` / `phy-qcom-qmp-ufs` / `scsi_common` / `ext4`）是给根块设备与兜底用的，与布局无关（[`scripts/08-initramfs.sh`](../../scripts/08-initramfs.sh#L50-L63)）。因此改布局不需要动阶段 08，需要动的是 06 / 09 / 10 和 `btrfs_opts()`。

### 回退分支的落盘顺序

```mermaid
flowchart TD
  A["09: 带 compress 的 loop 挂载失败"] --> B["改写 work/rootfs-layout = btrfs-flat"]
  B --> C["write_root_fstab 用 flat 版覆盖 etc/fstab"]
  C --> D["mkfs.btrfs -r 把 ROOT 整棵树写进镜像"]
  D --> E["成像末尾写回 LAYOUT 与 UUID 供 10 读取"]
```

上图：回退路径的顺序硬约束——`mkfs -r` 是「把 `$ROOT` 当前内容整棵写进镜像」，所以要进镜像的 fstab 必须在这之前落盘。

`write_root_fstab` 写的是**构建树里的** `$ROOT/etc/fstab`（[`scripts/lib.sh`](../../scripts/lib.sh#L431-L431)），`mkfs.btrfs -r` 读的也是同一棵树——这就是「顺序反了就来不及」的机制：`mkfs -r` 一旦跑完，镜像里的 fstab 已经固化了。

## fstab：全仓库唯一的生成点

`/etc/fstab` 只由 `lib.sh:write_root_fstab()` 写（[`scripts/lib.sh`](../../scripts/lib.sh#L401-L432)）：阶段 06 在写系统配置时调一次（[`scripts/06-config.sh`](../../scripts/06-config.sh#L58-L70)），阶段 09 在实际确定布局后再调（回退分支与 flat 分支各一次）。它有两个默认参数，都回落到同一份状态——布局默认取 `rootfs_layout()`（即缓存），UUID 默认取 `rootfs_uuid()`（即 `work/rootfs.uuid`）——因此调用方即使不传参也不会与缓存跑偏（[`scripts/lib.sh`](../../scripts/lib.sh#L401-L403)）。

子卷名同样是单一来源：fstab 里的 `subvol=/@`、`subvol=/@home`、`subvol=/@swap` 来自 `config/build.conf` 的 `BTRFS_SUBVOL_ROOT` / `_HOME` / `_SWAP`，而阶段 09 建子卷用的是**同一组变量**（[`config/build.conf`](../../config/build.conf#L34-L37)、[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L117-L120)），所以改名不会只改一半。

按布局打三种行组合：

| 布局 | 根行 | 其它行 |
|:--|:--|:--|
| `btrfs-subvol` | `UUID=… / btrfs rw,subvol=/@,…(btrfs_opts),x-systemd.growfs 0 1` | `/home`（`subvol=/@home` + `nofail,x-systemd.device-timeout=10`）、`/swap`（`subvol=/@swap` + `nodatacow,compress=no,nofail,x-systemd.device-timeout=10`） |
| `btrfs-flat` | `UUID=… / btrfs rw,…(btrfs_opts，不带 subvol),x-systemd.growfs 0 1` | 只有这一行 + `/boot` |
| `ext4` | `UUID=… / ext4 rw,errors=remount-ro,x-systemd.growfs 0 1` | 只有这一行 + `/boot` |

```text
# btrfs-subvol（BTRFS_COMPRESS 默认 zstd:3；/home、/swap 只有这一种布局才有）
UUID=<uuid> /       btrfs   rw,subvol=/@,compress=zstd:3,noatime,ssd,discard=async,space_cache=v2,x-systemd.growfs  0      1
UUID=<uuid> /home   btrfs   rw,subvol=/@home,compress=zstd:3,noatime,ssd,discard=async,space_cache=v2,nofail,x-systemd.device-timeout=10  0      0
UUID=<uuid> /swap   btrfs   rw,subvol=/@swap,compress=zstd:3,noatime,ssd,discard=async,space_cache=v2,nodatacow,compress=no,nofail,x-systemd.device-timeout=10  0      0
PARTLABEL=cache     /boot   vfat    umask=0077,nofail,noatime,x-systemd.device-timeout=10       0      0
```

三个细节值得单独记住：

- **根那一行用 `UUID=` 定位，不用 `PARTLABEL=`**。原因写在注释里：`PARTLABEL` 解析不到时 `systemd-remount-fs` 会失败，根可能停在只读，随后一串服务跟着挂（[`scripts/lib.sh`](../../scripts/lib.sh#L404-L407)）。三种布局的根行都带 `x-systemd.growfs`、`pass` 列为 `1`。
- **`/boot` 行对所有布局都一样**：`PARTLABEL=cache` + `vfat` + `umask=0077,nofail,noatime,x-systemd.device-timeout=10`。分区名解析不到时只让这一个单元失败，不会拖垮启动（[`scripts/lib.sh`](../../scripts/lib.sh#L429-L430)）。
- `/swap` 行里同时出现共享选项里的 `compress=zstd:3` 和追加在后面的 `compress=no`（共享选项在前、覆盖项在后）；改这一行时不要调换这个次序，`nodatacow,compress=no` 必须留在共享 `btrfs_opts` 之后。

`nofail` 的分工是刻意的，方向相反：

| 行 | `nofail` | 为什么 |
|:--|:--|:--|
| `/` | **不加** | 加了 systemd 可能跳过「把根重挂成 rw」，根一直只读 → `sshd`（生成主机密钥）、`usb-ncm`（写 configfs）等一连串失败（[`scripts/lib.sh`](../../scripts/lib.sh#L408-L411)） |
| `/home` | **加** | `@home` 万一挂不上，系统仍能起来并使用 `@/home` 里那份副本，不会掉进 emergency mode（[`scripts/lib.sh`](../../scripts/lib.sh#L413-L418)） |
| `/swap` | **加** | 交换文件可用性不该阻塞启动；btrfs 上放交换文件还需要 `nodatacow,compress=no`（[`scripts/lib.sh`](../../scripts/lib.sh#L419-L420)） |

## 残留缺口：只重跑某个阶段时没人兜底

第二次落笔只覆盖 btrfs 的两条分支——回退分支与 flat 分支各调一次 `write_root_fstab`（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L137-L152)），而 **`btrfs-subvol` 成功路径和 `ext4` 分支都不重写 fstab**（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L106-L172)）。所以「只重跑阶段 09」这类操作不被兜住：`RAPHAEL_FORCE_LAYOUT=ext4 ./build.sh --only 09` 时，阶段 06 早先按 `btrfs-subvol` 写好的 fstab（含 `subvol=/@` 与 `/swap` 行）会被原样塞进 ext4 镜像；同理，用不同的 `BTRFS_SUBVOL_*` 只重跑 09 也不会更新镜像里的 fstab。

改动这一带时要记住兜底机制的前提：**兜底靠的是「06 和 09 读同一份缓存、且 09 在落盘前把不一致纠正掉」**，一旦跳过其中一个阶段，这个前提就只剩缓存文件本身在撑。`work/rootfs-layout` 与 `work/rootfs.uuid` 都是 `work/` 下跨阶段复用的状态文件，部分重建既不会重新探测布局，也不会换 UUID（[`build.sh`](../../build.sh#L51-L75)）。

## 首启动扩容：`x-systemd.growfs` 与 `raphael-growfs.service` 兜底

三种布局的 fstab 根行都带 `x-systemd.growfs`，由 systemd 在首启动把根文件系统撑满 `userdata` 分区（8 GiB 下限镜像 → 设备实际容量），所以扩容这件事**与布局无关**——这解释了为什么 `IMAGE_SIZE` 只是下限却不必精确。

兜底关系是「systemd 原生优先、缺了才自建」：阶段 06 只在镜像里找不到 `systemd-growfs@.service` 时才安装 `raphael-growfs.service` + `/usr/local/sbin/raphael-growfs.sh`，后者按 `blkid` 判断文件系统类型，分别执行 `btrfs filesystem resize max /` 或 `resize2fs`，并 `enable` 到 `multi-user.target`（[`scripts/06-config.sh`](../../scripts/06-config.sh#L71-L105)）。自建单元本身是 `DefaultDependencies=no` + `After=local-fs.target` + `Before=sysinit.target`（`Requires=local-fs.target`），比普通服务排得早。

扩容与首启动建交换文件的时序也对得上：交换文件服务是 `RequiresMountsFor=/swap`、`After=local-fs.target` 的 oneshot，没有 `DefaultDependencies=no`，所以按默认依赖排在 `basic.target` 之后（[`scripts/06-config.sh`](../../scripts/06-config.sh#L441-L455)）；而 `x-systemd.growfs` 触发的扩容发生在挂载根这一阶段（在 `local-fs.target` 之前完成），兜底单元也显式排在 `sysinit.target` 之前。于是正常路径上根文件系统先被撑到 `userdata` 全尺寸，才轮到在上面建那 4 GB 交换文件（这也解释了为什么下限 8 GiB 的镜像里塞得下一个 4 GB 文件）。两个单位之间**没有**显式的 `After=` 关系——次序来自各自的目标依赖，改其中一个的排序时要意识到这一点。

## `/swap` 子卷与首启动交换文件

btrfs 上的交换文件有两个硬要求——**不能被压缩**、**必须 nocow**（`chattr +C`），所以单独开一个 `@swap` 子卷并按 `nodatacow,compress=no` 挂到 `/swap`（[`scripts/lib.sh`](../../scripts/lib.sh#L419-L420)）。

镜像里**不预置** 4 GB 的交换文件（免得镜像白胖），改由首启动的 `raphael-swapfile.sh` 创建：先建 nocow 空文件再 `fallocate` 写大小（失败回退 `dd`）、`chmod 600`、`mkswap`，把 `/swap/swapfile none swap defaults 0 0` 追加进 `/etc/fstab`，`swapon`，最后 `systemctl disable` 自己；`BTRFS_SWAP_SIZE=0` 时整套脚本与单元都不生成（[`scripts/06-config.sh`](../../scripts/06-config.sh#L412-L458)）。

两类退化行为值得记住：

- 脚本对「`/swap` 没挂上」是安全的：`mountpoint -q /swap || { echo "/swap 未挂载, 跳过交换文件"; exit 0; }`（[`scripts/06-config.sh`](../../scripts/06-config.sh#L424-L425)）。因此 `btrfs-flat` / `ext4` 布局（fstab 里没有 `/swap` 行）下 `/swap` 不会被挂载、交换文件也就不会被创建，系统只剩 `zram-generator` 那个 10 GB `zram0` 交换（[`scripts/06-config.sh`](../../scripts/06-config.sh#L316-L326)）。换句话说，**4 GB 磁盘交换文件只存在于 `btrfs-subvol` 布局**，与 `/home` 双写一样是子卷布局独有的行为。另外，脚本与单元**生成与否只看 `BTRFS_SWAP_SIZE` 是否为 0，与布局无关**（[`scripts/06-config.sh`](../../scripts/06-config.sh#L418-L419)）：flat / ext4 镜像里它们照样存在，只是首启动一进门就退出。
- 首启动脚本会**追加**一行到设备上的 `/etc/fstab`；这发生在设备上，与构建期的 `write_root_fstab()` 不冲突，但意味着设备上的 fstab 可能比 `lib.sh` 生成的多一行。

## 为什么 `/home` 的数据要写两遍

在 `btrfs-subvol` 路径里，阶段 09 把 `@/home` 里的内容 `cp -a` 复制进 `@home`，**两份都在镜像里**（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L123-L129)）。这不是冗余失误，而是配合 `nofail` 的设计：挂上 `@home` 时用的是 `@home`；万一挂载失败，`@/home` 里的同一份数据照样能让用户登录进桌面。

触发这个设计的是实测故障：单独挂 `@home` 时出现过 `user@1000` 的 `Dependency failed` → SDDM respawn 循环，根因是 `@home` 里**没有家目录**（[`scripts/lib.sh`](../../scripts/lib.sh#L413-L418)）。所以「双写」和「`nofail`」是一对：只有副本存在，`nofail` 才真的安全。

## UUID 必须成套：`work/rootfs.uuid`

`rootfs_uuid()` 只生成一次并缓存到 `work/rootfs.uuid`（文件为空时用 `python3 -c 'import uuid;print(uuid.uuid4())'` 现生成），同一份值进入三个地方（[`scripts/lib.sh`](../../scripts/lib.sh#L157-L166)）：

- `mkfs.btrfs -U` / `mke2fs -U`（镜像）——[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L113-L113)、[`#L164`](../../scripts/09-image-rootfs.sh#L164)；
- fstab 的 `UUID=…`（镜像内文件系统）；
- loader 的 `root=UUID=…`（[`scripts/10-image-boot.sh`](../../scripts/10-image-boot.sh#L111-L112)）——注意这是**另一个产物** `boot-cache.img`。

由此得到一条操作不变量：`rootfs.sparse.img` / `rootfs.img` 与 `boot-cache.img` 必须来自同一次 `work/`（成套构建、成套刷写）。删掉 `work/` 后只重跑阶段 09/10 会生成新 UUID，新的 `boot-cache.img` 配上旧的 rootfs 镜像时，initramfs 会「无法解析根设备」并落到救援 shell（[`scripts/08-initramfs.sh`](../../scripts/08-initramfs.sh#L125-L150)）。[`scripts/11-flash.sh`](../../scripts/11-flash.sh#L36-L39) 只是从 `out/` 取 `rootfs.sparse.img`（没有则退回 `rootfs.img`）与 `boot-cache.img` 刷进去，**不校验它们是否同源**。

## 谁还依赖布局：snapper 为什么自动跳过

首启动的 `raphael-snapper-setup.sh` 自己探测布局：`findmnt -no FSTYPE /` 不是 btrfs 就打印「根文件系统不是 btrfs, 跳过 snapper」并退出；是 btrfs 但 `btrfs subvolume show /` 失败（即单子卷 `btrfs-flat`）也会说明「snapper 需要 `@` 子卷」并退出；只有真的在 `@` 子卷里，才 `snapper -c root create-config /`（`/home` 也只在它本身是 btrfs 时才建一份配置）（[`scripts/06-config.sh`](../../scripts/06-config.sh#L1130-L1160)）。所以「想要快照」实际等价于「要有 `@` 子卷」，也就是要用有 root 的构建（CI 或 `sudo ./build.sh`）并清掉旧的 `work/rootfs-layout` 缓存。

顺带一提，`README.md` §1.1 展示的 fstab 仍是旧的 `PARTLABEL=userdata` 形式、`pass` 列写 `2`、也没有 `/swap` 行（[`README.md`](../../README.md#L97-L127)），排障与改动一律以 `write_root_fstab()` 为准。

## 验证：没有自动交叉校验，只能手工或刷机

**这一带没有任何自动化步骤把 loader 条目里的 `rootflags=` 与镜像里 `/etc/fstab` 的内容对比。** CI 只在构建前探测一次 loop 挂载能力并给出 `::warning::`（[`.github/workflows/build.yml`](../../.github/workflows/build.yml#L170-L188)），构建后只打印 `boot-cache.img` 的 FAT 目录列表与 `arch.conf` 原文供人眼比对（[`.github/workflows/build.yml`](../../.github/workflows/build.yml#L354-L367)）；成品侧只有阶段 09 的 `btrfs check` / `dumpe2fs` 与阶段 10 的 FAT 内容列表（[`scripts/09-image-rootfs.sh`](../../scripts/09-image-rootfs.sh#L156-L171)、[`scripts/10-image-boot.sh`](../../scripts/10-image-boot.sh#L186-L192)）。这些都是「镜像结构没坏」的检查，不是「三处说法一致」的检查。

可行的核对手段只有两种：

1. **手工挂载成品镜像**：`sudo mount -o loop,ro,subvol=/@ out/rootfs.img /mnt`（`btrfs-flat` 去掉 `subvol=`，`ext4` 直接 `-o loop,ro`）读出 `/mnt/etc/fstab`，再用 `mdir -i out/boot-cache.img ::/loader/entries/arch.conf`（或仓库自带的 `tools/mtools/usr/bin/mdir`）读出 `rootflags=` 原文，逐项人眼比对。注意只能挂 `out/rootfs.img`——`rootfs.sparse.img` 是 fastboot 用的 sparse 格式，不能直接 loop 挂载。
2. **刷机启动**：`arch-direct.conf`（不加载 initramfs，由内核直接挂根）与 `arch-debug.conf`（`loglevel=7` + `systemd.log_level=debug`）两个备用条目就是排障入口（[`scripts/10-image-boot.sh`](../../scripts/10-image-boot.sh#L135-L150)、[`scripts/11-flash.sh`](../../scripts/11-flash.sh#L127-L130)）。挂根失败时 initramfs 会列出 `/dev/sd*` / `/dev/mmcblk*` 并给出救援 shell，那是「布局与 fstab 对不上」最典型的现场。

## 改动清单

- **改布局**要同时动的地方：`config/build.conf` 的 `ROOTFS_TYPE` / `BTRFS_*` 旋钮、`lib.sh:rootfs_layout()`、`lib.sh:write_root_fstab()`、`btrfs_opts()`、阶段 09 的成像分支与回退分支、阶段 10 的 `rootfstype=` / `rootflags=`。任何一处单独改都会破坏上面四条不变量。
- **调试用敲门砖**：`RAPHAEL_FORCE_LAYOUT=ext4|btrfs-flat|btrfs-subvol` 可跳过探测；注意它会写回缓存（见「缓存是粘性的」），而且它只保证 09 与 10 一致，**不会重写 06 写过的 fstab**（见「残留缺口」）。
- **改缓存就要成套重跑**：改了 `work/rootfs-layout` 或删了 `work/rootfs.uuid` 之后，至少要从阶段 06 重新跑（fstab 在 06 落盘），且 09/10 必须同一次跑完，否则 UUID 与布局会分散在两个产物里。

相关背景：布局判定与无 root 约束的关系见[构建运行环境与无根构建](../architecture/rootless-build-runtime.md)，布局旋钮的下游效果见[配置模型](./configuration-model.md)，三处不一致在故障语义里的位置见[失败模式与不变量](./failure-modes-and-invariants.md)，`root=` / `rootflags=` 在启动链里的整体位置见[启动链与镜像布局](../architecture/boot-chain-and-image-layout.md)，各阶段契约与子集重建语义见[构建阶段流水线](../architecture/build-pipeline-stages.md)，产物怎么刷到设备上见[刷机与恢复](../operations/flashing-and-recovery.md)，设备起来之后谁负责挂载与扩容见[启动后系统与单元归属](../runtime/boot-sequence-and-service-ownership.md)，手工核对手法见[验证与排障](../testing/verification-and-debugging.md)，全景见[系统总览](../architecture/overview.md)。
