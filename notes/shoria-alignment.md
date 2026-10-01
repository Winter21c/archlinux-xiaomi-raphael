# 对齐 Shorin 指南的改造方案

> 阅读来源（5 篇全文已读）：
> [安装桌面环境前的准备](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/blob/main/wiki/archlinux/安装桌面环境前的准备.md)、
> [快照和系统维护](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/blob/main/wiki/archlinux/快照和系统维护.md)、
> [中文输入法](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/blob/main/wiki/archlinux/中文输入法.md)、
> [终端美化](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/blob/main/wiki/archlinux/终端美化.md)、
> [我的 KDE 自定义设置](https://github.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide/blob/main/wiki/archlinux/我的KDE自定义设置.md)
>
> 原则：**只做加法**，蓝牙 DT 补丁 + 原厂 NVM、麦克风 MCLK 路由、UCM、NCM、zram、手电筒等既有适配一律不动。

---

## 0. 先回答你的两个问题

**显卡驱动好了吗？** —— **基本好了，但有一个缺口**：

| 项 | 状态 |
|:--|:--|
| GPU 渲染（Adreno 640 / freedreno） | ✅ 好：`mesa` + `vulkan-freedreno` + 固件 `a640_gmu.bin`/`a630_sqe.fw`，Wayland 桌面正常 |
| 屏幕 / 触摸 / 亮度 | ✅ 好 |
| **视频硬解（Venus）** | ❌ **不行**：内核有 `venus-*.ko`，但设备树里**没有 venus 节点** → 只能软解（1080p 软解够用，4K 会卡） |
| 相机 | ❌ 没做（见下） |

**"蓝牙、相机、音频、麦克风之前已经适配好了"—— 实际状态（必须说清）**：

| 硬件 | 真实状态 |
|:--|:--|
| 蓝牙 | ✅ **真修好了**（DT 补 `local-bd-address` + 原厂 NVM，实测扫到 9 个设备） |
| 音频输出 | ✅ 正常（UCM：Speaker/Headphone，`hw:0,1` 扬声器 / `hw:0,0` 耳机） |
| **麦克风** | ⚠️ **还没通**：采集链路已修到全部上电（`AMIC MUX0` 默认断开 + DT 缺 MCLK 路由，两处已修），但录出来**仍然是全零** —— 差 DSP/ADM 或模拟前端最后一层 |
| **相机** | ❌ **完全没开始**：主线缺 sm8150 的 CAMSS/CCI 设备树与驱动，也没有 IMX586 系列 sensor 驱动，需要从 `andrew/6.16-cameras` 分支移植（本项目里最大的一块） |

---

## 1. 准备篇 → 要改的

| 指南条目 | 本项目动作 | 位置 |
|:--|:--|:--|
| `EDITOR` 环境变量 | 设为 **`nvim`**（`VISUAL=nvim` 一起设） | `06-config.sh` `/etc/environment` |
| 普通用户 + wheel sudo | ✅ 已有（`winter`，密码 1234，密码每月重建） | 已有 |
| faillock `deny = 0` | 由现在的 `deny=10` 改成 **`deny=0`**（按指南，牺牲安全性换日用体验） | `06-config.sh` |
| **开启 32 位源 multilib** | 新增：pacman.conf 里放开 `[multilib]` + `-Sy` | `02-pacman.sh` |
| archlinuxcn 源 + keyring | ✅ 已有（ustc/tuna/官方三源 + `archlinuxcn-keyring`） | 已有 |
| AUR 助手 `base-devel yay paru` | ✅ 有 `paru`，**补 `yay`** | `config/build.conf` |
| 字体 `noto-fonts / -cjk / -emoji` + `ttf-jetbrains-mono-nerd` | 补 `noto-fonts noto-fonts-cjk noto-fonts-emoji`（Nerd 已有） | `config/build.conf` |
| **你的字体：霞鹜文楷** | 构建时从 `lxgw/LxgwWenkai` release 下 `LXGWWenKai-Regular.ttf` + **`LXGWWenKaiMono-Regular.ttf`**（终端用 Mono）→ `/usr/share/fonts/TTF/` + `fc-cache`；fontconfig 里把中文首选设为 WenKai | 新增 `scripts/07b-fonts.sh`（或并入 07） |
| sof-firmware / alsa-firmware | ❌ 不需要（那是 Intel/AMD SOF 用的）；`alsa-ucm-conf` ✅ 已有（我们还打了补丁） | —— |
| PipeWire 全家桶 | ✅ 已有（`pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber`） | 已有 |
| **性能模式 `power-profiles-daemon`** | **加**：装 + `systemctl enable`；启动前探测 `/sys/devices/system/cpu/cpufreq`，没有 cpufreq 就自动跳过（"适配就要"） | `config/build.conf` + `06-config.sh` |
| 蓝牙 bluez | ✅ 已有 + 已修好 | 已有 |
| Flatpak（可选） | 加 `flatpak` + flathub（上交大镜像），**可选** | `config/build.conf` |
| 休眠到硬盘 | ❌ SM8150 只有 s2idle 且已被 mask，不做（指南里的 hibernate 不适用） | 已在 README 说明 |

## 2. 快照篇（snapper）→ 要做的

| 指南条目 | 本项目动作 |
|:--|:--|
| `snapper btrfs-assistant inotify-tools` | `snapper`/`inotify-tools` 进镜像；**`btrfs-assistant` 在 AUR** → 首启动用 `paru` 装 |
| 可选 `snap-pac` | 加上（pacman 钩子自动快照，滚挂回档神器，也在 AUR/extra） |
| `grub-btrfs` + `grub-btrfsd` | ❌ **不适用**：我们是 U-Boot → systemd-boot，不是 GRUB。**快照本身、回档、btrfs-assistant 都照常可用**，只是没有"GRUB 菜单里选快照启动"那一项 |
| `snapper -c root create-config /` + `-c home create-config /home` | 做成**首启动服务**自动执行（幂等） |
| 策略：`ALLOW_GROUPS="wheel"`、`NUMBER_LIMIT=10`、`TIMELINE_LIMIT_HOURLY=3`、`TIMELINE_LIMIT_DAILY=1`，其余 TIMELINE 归零 | 首启动服务里按这套写 `/etc/snapper/configs/{root,home}` |
| 开启 `snapper-timeline.timer` / `snapper-cleanup.timer` | 首启动服务里 enable |
| 回档方法（`btrfs-assistant -l/-r`、手动 `btrfs subvolume snapshot`） | 写进 README 新章节 |

> ⚠️ **snapper 需要 `/` 是一个子卷（`@`）**。CI 构建（有 root）产出的是 `@`+`@home` 布局 ✅；
> 本机无 root 构建产出的是**单子卷**布局，snapper 的 `create-config /` 可能拒绝 ❌。
> 所以：**要用 snapper，就刷 CI 出的镜像**（或本机用 sudo 构建）。首启动服务会自己探测并跳过不适用的项。

## 3. 中文输入法 → 要改的（Fcitx5 + 中州韵 + 雾凇）

| 指南条目 | 本项目动作 |
|:--|:--|
| `fcitx5-im`、`fcitx5-rime` | 补 `fcitx5-im`（`fcitx5-rime` 已有） |
| `rime-ice-git`（雾凇，AUR） | 已有 `rime-ice`；**首启动再用 paru 补 `rime-ice-git` 与可选方案**（万象、五笔、Mozc） |
| `~/.local/share/fcitx5/rime/default.custom.yaml` → `__include: rime_ice_suggestion:/` | 按指南写（**注意路径是 `~/.local/share/fcitx5/rime/`**，不是 `~/.config`） |
| 可选：`schema_list`（F4 切换多方案） | 写入（`luna_pinyin_simp`/`rime_ice`/`double_pinyin_flypy`/`wubi86`/`bopomofo`） |
| 可选：万象语法模型 `rime-wanxiang-gram-zh-hans` + `rime_ice.custom.yaml` | 首启动 paru 装 + 写 `"grammar/language": wanxiang-lts-zh-hans` |
| 可选：默认英文标点 `"switches/@1/reset": 1` | 按指南写入 `rime_ice.custom.yaml` |
| 可选：`custom_phrase.txt` 自定义词库 | 建空模板 + 注释说明格式 |
| 环境变量：`~/.config/environment.d/ime.conf`（`XMODIFIERS`/`QT_IM_MODULES`/`QT_IM_MODULE`/`SDL_IM_MODULE`） | 按指南写（**不再往 `/etc/environment` 塞 GTK_IM_MODULE**） |
| GTK：`~/.gtkrc-2.0` + `~/.config/gtk-3.0/settings.ini` + `gtk-4.0/settings.ini` → `gtk-im-module=fcitx` | 按指南写（写在 GTK 配置里而不是环境变量，避免 Wayland 下闪烁/错位） |
| KDE：虚拟键盘选 `fcitx5 wayland 启动器` | `07-desktop.sh` 已设 `VirtualKeyboardEnabled`，改为 `fcitx5` 启动器 |
| 右 Shift 切不回中文的修法 | 写 `~/.config/fcitx5/config` 的 `[Hotkey/AltTriggerKeys]` = `Shift_L`/`Shift_R` |
| 漏字/大写锁定异常的 `fcitx5-shorin-patched-git` | 列为**首启动可选安装**（AUR） |

## 4. 终端美化 → 要做的

| 指南条目 | 本项目动作 |
|:--|:--|
| zsh + `chsh -s /usr/bin/zsh` | 装 `zsh`，默认 shell 设为 zsh（**bash 仍然完整可用**，按你的要求两个都配好） |
| `zsh-syntax-highlighting zsh-autosuggestions zsh-completions` | 全装 + `~/.zshrc` 按指南写（历史记录选项、插件 source、`menu select`） |
| **oh-my-zsh / oh-my-bash**（你的额外要求） | 构建时 `git clone` 到 `/usr/share/oh-my-zsh`、`/usr/share/oh-my-bash`（离线可用），`~/.zshrc` 与 `~/.bashrc` 分别加载；主题用 `robbyrussell` 之类轻量款，**提示符交给 starship** 避免打架 |
| `starship` + `ttf-jetbrains-mono-nerd` | 装 + `eval "$(starship init zsh)"` / `bash` + 写一份 `~/.config/starship.toml`（Nerd 图标预设） |
| **Konsole 美化** | 写 Konsole **profile**：隐藏工具栏/标题栏（"移除窗口标题和框架"）、**Catppuccin Frappe** 配色（构建时抓 catppuccin/konsole 的配色文件）、**20% 透明度**、字体 **LXGW WenKai Mono 15pt**、边距、隐藏滚动条、取消"高亮新行"、取消 resize 提示；`konsolerc` 里设为默认 |
| Ghostty / Kitty | 不用（你指定 konsole），但同样配置留空不装 |

## 5. KDE 自定义设置 → 能落文件的落文件，其余给清单

指南这一篇大半是**手动点系统设置**，我按"能否写进配置文件"分两类：

**能预置进镜像的**（写 `kdeglobals`/`kwinrc`/`kglobalshortcutsrc`/`kcminputrc`/`plasmashellrc` 等）：

| 项 | 值 |
|:--|:--|
| 字体 | 界面 **LXGW WenKai** 11pt、等宽 **JetBrainsMono Nerd Font** 10pt（对齐你选的中文字体 + 指南的 11pt） |
| 颜色/风格 | Breeze 微风经典 + Plasma 深色（指南就是"不装第三方主题，Breeze 够漂亮"）+ 壁纸取色强调色 |
| 光标 | Breeze 微风深色，**大小 30** |
| 窗口装饰 | Breeze，标题栏按钮按指南 |
| 快捷键 | KRunner `Meta+Z`、Konsole `Meta+T`、系统设置 `Ctrl+Alt+S`、关窗 `Meta+Q`、强杀 `Meta+Ctrl+Q`、最大化 `Meta+F`、最小化 `Meta+H`、移动窗口到中央 `Meta+C`、显示桌面 `Meta+M`、快速铺放 `Meta+W/A/S/D`、剪贴板 `Meta+V`、全屏 `Meta+Alt+F` |
| 桌面特效 | 窗口惯性晃动 25/70/15、窗口透明度开启、几何变化动画 500ms |
| 虚拟桌面切换提示 500ms | ✅ |
| 面板 | 半透明、悬浮"仅小程序"、显示隐藏"避开窗口" |
| Spectacle | 保存到默认文件夹 + 复制到剪贴板 |
| 触摸优化 | **手机场景追加**：预设 Plasma Mobile 会话、虚拟键盘、单指点击（指南是鼠标桌面，这里必须兼顾触屏） |

**只能你自己点/或首启动装的**（我会写进 README 清单）：

- 桌面右键操作（中键启动器、滚轮切桌面）、面板拖拽布局、壁纸/锁屏壁纸挑选、用户头像
- AUR 挂件与特效：`plasma6-applets-wallpaper-effects`（模糊半径 30/圆角 15）、`kwin-effects-geometry-change`、`kwin-effect-rounded-corners-git`（圆角 15 + 轮廓 2/0）、`missioncenter`
- `kdeconnect`（手机互传，装进镜像）

---

## 6. 实施顺序（我接下来怎么做）

1. **包清单 + 32 位源 + AUR 助手**：`config/build.conf`、`02-pacman.sh`
2. **字体**：新增下载+安装（霞鹜文楷 Regular/Mono + noto 三件套）+ fontconfig
3. **shell/终端**：zsh(+插件) / bash / oh-my-zsh / oh-my-bash / starship / Konsole profile(+配色) / `chsh`
4. **输入法**：fcitx5-im、rime 配置（default.custom.yaml / rime_ice.custom.yaml / custom_phrase.txt）、environment.d、GTK 配置、KDE 虚拟键盘
5. **snapper**：首启动服务（探测 btrfs 布局 → create-config → 策略 → 定时器）+ snap-pac
6. **KDE 预置**：kdeglobals/kwinrc/快捷键/特效/光标/字体
7. **AUR 首启动安装服务**：`btrfs-assistant`、`snap-pac`、`plasma6-applets-wallpaper-effects`、`kwin-effects-geometry-change`、`kwin-effect-rounded-corners-git`、`rime-ice-git`、`rime-wanxiang-gram-zh-hans`、`downgrade`、可选 `fcitx5-shorin-patched-git`（有网才跑、失败不影响系统、写日志）
8. **文档**：README 增加「日常维护（快照/滚挂口诀/downgrade）」章节
9. 提交推送 → CI 构建验证 → 出镜像

## 7. 需要你拍板的三件事

1. **snapper** 依赖 `@` 子卷 → 要用它就刷 CI 镜像（本机无 sudo 构建是单子卷）。是否可以？
2. **faillock `deny=0`**（指南做法，牺牲安全性）—— 手机上要不要这么放开？（我建议 `deny=0` 但保留 `unlock_time`，或折中 `deny=5`）
3. **AUR 首启动自动安装**（约 10 个包，手机会编译几分钟到十几分钟，期间可正常用）—— 接受吗？还是只装清单、你自己按需 `paru -S`？
