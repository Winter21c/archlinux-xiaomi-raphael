# 桌面环境多选（Plasma Mobile / Plasma / Phosh / GNOME / 纯命令行）

> 2026-10-10 实施。这份笔记记录"为什么这么做"和"验证过的事实"，改这块之前先看它。
> 配置入口：`config/build.conf` 的 `DESKTOPS`；落地脚本：`scripts/07-desktop.sh`
> （`scripts/02-pacman.sh` 负责装包与硬检查，`scripts/09-image-rootfs.sh` 负责按内容放大镜像）。

---

## 1. 一句话题目

同一个镜像构建流程里**可多选桌面**，也可以**一个都不选（纯命令行）**：

```bash
DESKTOPS="plasma-mobile" ./build.sh          # 默认
DESKTOPS="phosh gnome" ./build.sh            # 手机外壳 + 桌面
DESKTOPS="" ./build.sh                       # 纯命令行
```

`DESKTOPS` 的**顺序 = 自动登录优先级**；先归一小写/别名/去重/校验（写错直接 `exit 1`），
再派生一组布尔标志给脚本用：

| 标志 | 含义 |
|:--|:--|
| `HAVE_PLASMA_MOBILE` / `HAVE_PLASMA_DESKTOP` / `HAVE_PHOSH` / `HAVE_GNOME` | 逐个桌面 |
| `HAVE_KDE` | 前两个之一（决定 kwin / breeze 主题 / PowerDevil / Konsole 那套） |
| `HAVE_MOBILE_SHELL` | `plasma-mobile` 或 `phosh`（决定手机字体、手机应用、yay、是否精简） |
| `HAVE_ANY_DE` | 有没有选桌面（=0 就是纯命令行） |
| `PRIMARY_SESSION` | 自动登录的 SDDM 会话名（纯命令行时为空） |
| `DE_SUMMARY` | 日志/引导菜单/发布说明用的人话摘要 |

---

## 2. 验证过的上游事实（2026-10-10，ALARM extra 仓库）

| 事实 | 怎么验证的 |
|:--|:--|
| `phosh` 0.57 / `phoc` / `squeekboard` / `feedbackd` / `phosh-mobile-settings` / `phosh-tour` / `gnome-calls` / `chatty` / `callaudiod` 都在 extra | 下载 `extra.db` 按 `%NAME%` 查 |
| **没有** `phosh` 包组，也没有 `phosh-osk-stub` | 同上（所以 phosh 用显式包列表，不用组名） |
| `phosh` 自带 `usr/share/wayland-sessions/phosh.desktop`，`Exec=phosh-session`，而 `phosh-session` 内部跑 `phoc` + `gnome-session` | 解包 `phosh-0.57.0-1-aarch64.pkg.tar.xz` |
| `phosh` 依赖里已经含 `gnome-shell` / `gnome-session` / `phoc` / `xdg-desktop-portal-phosh` —— 装 phosh 等于已经拖进来半个 GNOME | 看包目录里的 `depends` 文件 |
| GNOME 侧：`gnome` 组有 **63** 个包（含 `gnome-boxes`、`orca`、`gnome-user-docs`、`gdm`），`gnome-session` 提供 `gnome.desktop`（`Exec=/usr/bin/gnome-session`） | `extra.db` 的 `%GROUPS%` + 解包 `gnome-session` |
| **SDDM 默认 `DisplayServer=x11`**，Wayland 登录界面的默认 `CompositorCommand="weston --shell=kiosk"` | `man 5 sddm.conf`（包里自带） |
| `sddm` 包只带 `elarun` 主题；**breeze 主题不在 sddm 包里**（KDE 那边提供） | 解包 `sddm` 列出 `usr/share/sddm/themes/` |
| `dconf` 包**不带** `/etc/dconf/profile/user`，要用 system-db 必须自己建这个 profile | 解包 `dconf` 列 `etc/` |
| `phosh` 的 gsettings：`sm.puri.phosh`（`enable-suspend` 默认 false、`shell-layout=device`）、`sm.puri.phosh.lockscreen.require-unlock` 默认 true | 解包看 `mobi.phosh.shell.gschema.xml` |
| 直接包体积很小（phosh 10 包 17 MB、GNOME 精选 20 包 122 MB）——大头在依赖，实测整机 Plasma Mobile 7.0 GB | `extra.db` 的 `%ISIZE%` + `du -sh work/root` |

---

## 3. 关键设计决定

### 3.1 登录器统一 SDDM
- 只用一个显示管理器：多选时 SDDM 会自动列出 `/usr/share/wayland-sessions/` 下所有会话，
  登录时随便切（`RememberLastSession=true`）。避免了 sddm/gdm/greetd 抢
  `display-manager.service` 的组合爆炸。
- `CompositorCommand`：有 KDE 用 `kwin_wayland`，没有就显式写 `weston --shell=kiosk`
  —— 非 KDE 的镜像里**必须装 weston**，否则登录界面起不来（`PKGS_DM_GREETER_COMPOSITOR`）。
- `[Theme] Current=breeze` 只在 `$ROOT/usr/share/sddm/themes/breeze` 真存在时才写：
  写一个不存在的主题会直接黑屏。
- 自动登录的会话名 = `.desktop` 文件去掉后缀：`plasma-mobile` / `plasma` / `phosh` / `gnome`
  （注意 Plasma 桌面的会话名是 **`plasma`**，不是 `plasma-desktop`）。

### 3.2 纯命令行 = 不装也不留
`DESKTOPS` 为空时：不装 `sddm`/字体/wayland 那一坨，并且**显式清理**增量重建留下的
`/etc/systemd/system/display-manager.service` 软链和 sddm 配置，再把默认目标设成
`multi-user.target`。不清理的话，旧软链会让开机去拉一个已经不存在的单元（多一个 failed）。

### 3.3 触屏输入（这台机器没有物理键盘）
| 桌面 | 屏幕键盘 | 配置位置 |
|:--|:--|:--|
| Plasma Mobile / Plasma | `plasma-keyboard` | `~/.config/kwinrc` 的 `[Wayland] InputMethod[$e]=...plasma.keyboard.desktop`，**只写这一个键**（再写 `VirtualKeyboardEnabled` 会互相抢输入，见 HANDOVER §5.5） |
| Phosh | `squeekboard`（提供 `phosh-osk-provider`） | phosh 自己管 |
| GNOME | gnome-shell 自带 OSK | dconf `org.gnome.desktop.a11y.applications screen-keyboard-enabled=true` |
| SDDM 登录界面 | `qt6-virtualkeyboard` | `/etc/sddm.conf.d/10-raphael.conf` 的 `InputMethod=qtvirtualkeyboard` |

### 3.4 GNOME 系用 dconf 系统默认值，不用 gsettings
构建期没有 dbus 用户会话，`gsettings set` 写不进去。做法是
`/etc/dconf/profile/user`（`user-db:user` + `system-db:local`）+ 
`/etc/dconf/db/local.d/00-raphael`，然后 qemu 里跑 `dconf update` 编译。
只写"功能必需"的键，不预设审美类配置（缩放只打开分数缩放特性，比例让用户自己选）。

### 3.5 电源键
KDE 有 PowerDevil（`powerdevilrc` 的 `PowerButtonAction=128`），所以**不启用**自研守护，
避免重复触发；GNOME / Phosh / 纯命令行都没有 PowerDevil，于是 `raphael-power-key.service`
默认启用。守护内部三级回退：`org.freedesktop.ScreenSaver` → logind `lock-session`/`unlock-session`
（GNOME/Phosh 一定支持）→ `kscreen-doctor --dpms`。注意守护以 root 运行，
不能用 `loginctl ... self`，要先用 `loginctl show-user <user> -p Display` 拿会话 id。

### 3.6 镜像体积
`IMAGE_SIZE`（默认 8G）改成**下限**：阶段 09 按 `du -sm --apparent-size $ROOT × 1.15 + 512MB`
自动放大。原因：单装 Plasma Mobile 实测就 7.0 GB，全选四个桌面会明显超过 8 GB，
死守配置值会做出"装不下"的镜像（mkfs 报 no space / 设备上写不进日志）。
镜像本身是稀疏文件，多要的空间不占宿主磁盘，首启动还会 growfs 到 userdata 全尺寸。

---

## 4. 踩过的坑 / 注意点

1. **个人化那段（07 的 13.1~13.9）只在 KDE 时跑**：它是 Konsole/kdeglobals/kwin/plasma-keyboard
   那套，紧接着 13.10 又会撤掉；放给 phosh/GNOME/纯命令行 白跑一遍（git clone、下配色、
   下 50 MB 字体）没意义。`06-config.sh` 的霞鹜文楷也只在 `HAVE_ANY_DE=1` 时才下载。
2. **13.10 必须继续覆盖 kwinrc**：13.7 会写一份带 wobbly 特效的 kwinrc，13.10 负责把它
   拉回"只有 InputMethod"的版本。重构时如果把这段删了，KDE 镜像会悄悄把特效又带回来
   （已经踩过一次：集成测试里"kwinrc 只有 3 行"断言变红）。
3. **`pacman -Si <组名>` 会失败**：`gnome`/`plasma` 是**包组**，不是包。`02-pacman.sh` 的
   校验改成 `-Si` 不行就试 `-Sg`（`-S` 本身能整组装）。另外选中桌面的关键包缺失时
   直接 `die`，不要"警告后跳过"——那会做出进不去桌面的镜像。
4. **镜像自检**：`scripts/07-desktop.sh` 跑完 6 种组合（空/四个单选/三个全选）都应退出 0；
   改动后建议照 `notes/` 里的做法用假 rootfs + stub lib.sh 跑一遍，断言产物文件对不对
   （sddm 配置/会话名/kwinrc/dconf/电源键单元/纯命令行的清理）。
5. **CI 的四个复选框在 push 触发时是空的**：这时要落回历史默认（Plasma Mobile），
   否则自动构建会悄悄变成纯命令行镜像。判定顺序：旧 `session`（非 auto）> 复选框 >
   默认值。

---

## 5. 真机实测结果（2026-10-10，镜像 `DESKTOPS="plasma-mobile plasma-desktop phosh gnome"`）

构建：本机 sudo 干净构建 11.5 分钟；`@`/`@home` 子卷布局；镜像按内容自动放大到 8701 MB。
刷机：`11-flash.sh`，userdata 6 个 sparse 分片全部 OKAY（约 3 分钟）。
首启动：growfs 到 469 GB ✓、pacman 密钥环 69 个公钥 ✓、snapper 6 个快照 ✓、
蓝牙控制器地址已注入 ✓（`bluetoothctl` 显示 `02:00:78:E0:04:F0` = DT 值 `f0 04 e0 78 00 02` 的反序，符合 §8.9 的约定）、0 个失败单元 ✓。

| 会话 | SDDM 启动的会话命令 | 结果 |
|:--|:--|:--|
| `plasma-mobile` | `startplasmamobile` | ✅ `kwin_wayland` + `plasmashell` 正常，默认自动登录 |
| `plasma` | `startplasma-wayland` | ✅ 同上（桌面外壳） |
| `gnome` | `/usr/bin/gnome-session` | ✅ `gnome-shell --mode=user` 起来，用户确认屏幕正常 |
| `phosh` | `phosh-session` → `phoc` | ❌ **起不来**（见下） |

### 5.1 Phosh 失败的根因（已验证，不是构建配置问题）

1. SDDM 侧一切正常：自动登录触发，`phoc` 真的启动了
   （`Output 'DSI-1' added` → `Enabling shell mode`）。
2. 随后 **wlroots 的 DRM atomic 提交在这块 DSI 屏上失败**：
   ```
   phoc: [backend/drm/atomic.c:82] connector DSI-1: Atomic commit failed
   phoc: [wayland] error in client communication (pid 8411)
   ```
   → phoc 崩，SDDM 退回登录界面（看起来像"没有自动登录"，其实是会话起来又死了）。
3. 加 `WLR_DRM_NO_ATOMIC=1` 能过 modeset 这一关
   （`connector DSI-1: Modesetting with 1080x2340 @ 60.000 Hz`），
   `phosh` 甚至打印了 `Phosh ready after 1.98s`，但紧接着：
   ```
   phosh: Error 71 (协议错误) dispatching to Wayland display.
   phoc: [wayland] error in client communication (pid 9424)
   ```
4. 内核侧同时能看到 GPU 故障，说明不只是 DRM 平面问题：
   ```
   adreno 2c00000.gpu: [drm:a6xx_irq] *ERROR* gpu fault ring 0 fence 1ad5 status 00800005 ...
   msm_dpu ae01000.display-controller: [drm:recover_worker] *ERROR* 06040001: hangcheck recover!
   ```
   （hangcheck 的 offending task 出现过 `sddm-greeter-qt6`，即 X11 登录界面也踩到过。）
5. `WLR_DRM_NO_MODIFIERS=1`、`WLR_RENDERER=pixman`（软件渲染）都**没有**救回来
   —— 软件渲染也起不来，说明不是单纯的 GL/modifier 问题。
6. 另一个（非致命）现象：`phoc` 报 `No panel found for compatibles` +
   `gm_display_panel_get_name: assertion ... failed`，即 gnome-desktop 的 panel 表里没有这块屏，
   phosh 拿不到面板信息（只影响旋转/面板名之类）。

### 5.2 结论与后续

- **这台设备上 Phosh 目前不可用**，需要在内核 DRM（msm/dpu + DSI atomic）或 wlroots/phoc
  层面继续查；构建侧（包、会话文件、SDDM、dconf、触屏键盘）都是对的，别在 build.conf 里找原因。
- 想要能用，下一步可以试：换 phoc/wlroots 版本、抓 `dmesg` 看具体哪个 atomic 属性被拒、
  或者对 `phoc` 用 `WLR_DRM_NO_ATOMIC=1` + 更细的日志（`phoc -d`）逐条 diff 内核返回值。
- 已经在本 PR 里做的适配（`Exec` 用绝对路径等）**不必要**：`Exec=phosh-session` 的相对写法
  SDDM 照样能启动（之前的误判来自"会话崩溃后回到登录界面"）。

---

## 6. Phosh 深挖：三个拦路虎（2026-10-11 真机实测，逐个定位）

> 结论：**还差最后一个**。前两个已经修好并在真机上验证过；第三个精确定位到了
> wlroots 的 layer-shell 协议校验，需要 phosh/phoc 层面的修法。

### 6.1 拦路虎一：我们内核的 DRM atomic 提交（已绕过 ✓）

干净启动（没有其它会话）也一样复现，所以不是"残留会话"：

```
phoc: connector DSI-1: Modesetting with 1080x2340 @ 60.000 Hz
phoc: Enabling shell mode
phoc: [backend/drm/atomic.c:82] connector DSI-1: Atomic commit failed: ...
```

**绕过办法**：`WLR_DRM_NO_ATOMIC=1`（走 legacy DRM 路径）。加上它以后 phoc 能完整
modeset、添加输出、进 shell 模式 ✓。

### 6.2 拦路虎二：phosh 的用户服务拿不到 Wayland display（已修 ✓）

```
squeekboard[1623]: 无法打开显示：        → SIGABRT
systemd[675]: mobi.phosh.OSK.service: Failed with result 'exit-code'
```
根因：`systemctl --user show-environment` 里只有 `XDG_RUNTIME_DIR`，**没有
`WAYLAND_DISPLAY`**；而 squeekboard / xdg-desktop-portal-* 都是 systemd **用户服务**。

**修法**（`/usr/local/bin/phosh-session-wrapper`，会话 Exec 指向它）：后台等 phoc 建好
`wayland-N` socket，再 `systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR`
（顺带 `reset-failed`）。修完 squeekboard 确实起来了：`Started Squeekboard ... Loaded layout Resource: us` ✓。

### 6.3 拦路虎三：phosh 自己要了一个 0 高度的 layer surface（未修 ✗）

`WAYLAND_DEBUG=1` 抓到的**协议错误原文**：

```
-> wl_display#1.error(zwlr_layer_surface_v1#78, 1,
     "height 0 requested without setting top and bottom anchors")
```

wlroots 的 `zwlr_layer_surface_v1` 校验：没有同时设 top+bottom 锚点时高度必须 > 0。
phosh 违反了这个规则 → wlroots 按协议断开该客户端 → phosh 掉线：

```
phoc: [wayland] error in client communication (pid 851)
phosh: Phosh ready after 4.06s
phosh: Error 71 (协议错误) dispatching to Wayland display.
```

排除过的可能：
- ❌ 不是 dmabuf/GPU：`WLR_RENDERER=pixman` + `GSK_RENDERER=cairo` + `GDK_DEBUG=gl-disable`
  全软件渲染时 **GPU 故障 0 次**，照样在 "ready" 后 1 秒被断开。
- ❌ 不是屏幕键盘时序：dconf 里 `screen-keyboard-enabled=false` 也一样复现；
  另外 phoc 一直报 `No panel found for compatibles`（gnome-desktop 的面板库里没有这块屏）。

**下一步建议**（按性价比）：
1. 在 `WAYLAND_DEBUG=1` 下抓 `zwlr_layer_surface_v1#78` 的 `get_layer_surface`/`set_size`/
   `set_anchor` 三个请求，确认是 phosh 的哪个图层（面板 / 锁屏 / OSK）以及高度为什么算成 0；
2. 对照 phosh 0.57 的 `PhoshLayerSurface` 里高度来源（`phosh_panel` 的高度取自 GTK 分配，
   若主题/CSS 没给尺寸就可能为 0）；
3. 给 phoc 打个宽容补丁（height==0 时按 1 处理）验证是否只是这一个点 —— 只能用于定位，
   不能当正式修法。

### 6.4 顺带验证过、但与 phosh 无关的两件事

- **他的 6.16.9 内核确实修掉了 atomic 问题**（phoc 能 modeset），但 GPU 起不来：
  `msm_dpu: [drm:adreno_load_gpu] *ERROR* Couldn't power up the GPU: -22`。
  已排除：DTB（两边 GPU/GMU 节点逐字节相同，只差 zap 固件路径大小写，已用软链接补上）、
  模块缺失（把他的 143 个模块全装进 rootfs，无效）、固件来源（设备上就是
  linux-firmware 20260916 的原版）。→ 是**他内核自己的问题**，所以"换他的内核修 phosh"
  这条路暂时走不通。
- **实验设施已留在设备上**（不影响正常使用）：
  `/usr/local/sbin/raphael-phosh-experiment.sh` + systemd 单元（只在非 7.2.0 内核时自跑），
  cache 分区里多了一个 `arch-6169.conf` 引导项（默认仍是 arch.conf），
  `/lib/firmware/qcom/sm8150/xiaomi -> Xiaomi` 软链接。

---

## 7. Phosh 修复落地（2026-10-11，构建脚本已固化）

§6 定位出的三个拦路虎，现在都由构建脚本自动处理，**真机验证 Phosh 界面可用**。

| # | 修复 | 落在哪 |
|:--|:--|:--|
| ① | 内核 atomic 提交失败 → 走 legacy DRM 路径 | `scripts/07-desktop.sh` §4b 写 `/usr/local/bin/phosh-session-wrapper`（内含 `WLR_DRM_NO_ATOMIC=1`），并把 `phosh.desktop` 的 `Exec=` 指过去 |
| ② | 用户服务拿不到 `WAYLAND_DISPLAY` → squeekboard/portal abort | 同一个包装脚本：后台等 `wayland-N` socket 出现后 `systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR` + `reset-failed` |
| ③ | wlroots 的 layer-shell 校验拒绝 Phosh 的 home bar（`height 0` 且只锚 BOTTOM） | `scripts/lib.sh` 的 `patch_wlroots_layer_shell()`：2 字节二进制补丁把校验放宽成"至少锚定一个垂直边"，原始库备份为 `*.raphael-orig`，找不到特征序列时只告警不中断构建 |

修复后的真机状态（用户确认屏幕可用）：

```
loginctl show-session 1 -p Type -p Active -p State  →  Type=wayland Active=yes State=active
mobi.phosh.Shell.service   active running   Phosh, a shell for mobile phones
mobi.phosh.OSK.service     active running   Squeekboard（不再崩循环）
xdg-desktop-portal-gtk     active running
systemctl --failed         → 0 个
```

**想让 Phosh 当默认会话**：`config/build.conf` 的 `DESKTOPS` 里把它写在第一个即可
（顺序 = 自动登录优先级，例如 `DESKTOPS="phosh plasma-mobile"`）。

**将来升级 wlroots 时**：`patch_wlroots_layer_shell()` 会打不上补丁并告警 —— 那时重新
按 §6.3 的方法定位特征序列即可；也可以考虑改成从源码打补丁重编 wlroots（更正规，但要
在构建里引入 meson 工具链）。
