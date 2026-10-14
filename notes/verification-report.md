# Raphael 实机验证报告

> 由自动化脚本在真机上逐项执行，输出原样附在下面。
> 生成时间：2026-10-15 07:03:42　仓库 HEAD：093a95d
> 设备：Redmi K20 Pro (raphael)，KDE 桌面形态镜像，内核 7.2.0-sm8150-ga1573649db08

## 结果

```
════════ Raphael 全项回归验证 2026-10-15 07:03:24 ════════
【系统】
  ✓ 内核                             7.2.0-sm8150-ga1573649db08
  ✓ 系统失败单元                 0
  ✓ 用户失败单元                 0
  ✓ 普通用户                       winter
  ✓ sudo(031210)提权                 0
  ✓ /home 下只有 winter             winter
【桌面】
  ✓ KDE 会话单元数(active)        4
  ✓ plasmashell D-Bus 名              1
  ✓ 面板存在(配置判据)         1
  ✓ 显示器 DPMS(息屏=Off 正常)  Off
【声音】
  ✓ 声卡入口数                    2
  ✓ codec 在声卡里                 1
  ✓ profile(非 pro-audio)             output:stereo-fallback
  ✓ sink 是真实设备               alsa_output.platform-sound.stereo-fallback
  ✓ 耳机未插时路由(扬声器)   on
  ✓ 耳机未插时耳机路由关     off
  ✓ slim 链路存在(控件判据)    yes
  ✓ 静音播放退出码              0
  ✓ 播放期间 AFE 报错            0
【网络/包管理/输入法/投屏】
  ✓ Wi-Fi SSID                         ChinaNet_XQP2_5G
  ✓ Wi-Fi 频段(5GHz)                 44
  ✓ IP 与本机同网段              192.168.31.90
  ✓ pacman 残留 mkinitcpio preset    0
  ✓ pacman IgnorePkg                   1
  ✓ fcitx5 进程                      yes
  ✓ Rime 为默认输入法            1
  ✓ 投屏模块可加载              yes
  ✓ 投屏 DRM 卡(msdisp)             found
【存储】
  ✓ 子卷 @/@home/@swap               3
  ✓ swap 总量条目                  2
════════ 通过 30 项 / 失败 0 项 ════════
```

## 覆盖范围

| 组 | 项数 | 内容 |
|:--|:--|:--|
| 系统 | 6 | 内核版本、系统/用户失败单元、用户 winter 唯一、sudo 031210 提权、/home |
| 桌面 | 4 | 4 个 KDE 会话单元 active、plasmashell D-Bus 名、面板存在、显示器 DPMS |
| 声音 | 9 | 声卡入口、`slim 链路存在`、codec 在卡、profile(非 pro-audio)、sink 是真实设备、耳机未插时路由二选一、静音播放退出码、播放期 AFE 报错 |
| 网络/包/输入法/投屏 | 9 | Wi-Fi SSID+5GHz 频段+同网段 IP、pacman 无残留 preset、IgnorePkg、fcitx5、Rime 默认、投屏模块、投屏 DRM 卡 |
| 存储 | 2 | `@`/`@home`/`@swap` 子卷、swap(zram+swapfile) |

## 几处刻意的判据选择（避免误报）

* **slim 链路**：不用 `dmesg` 里的 `qcom_snd_parse_of OK: 5 links` —— 那行**只在开机打印一次**，
  一旦 `dmesg -c` 或环形缓冲回绕就消失。改用**持久判据**：q6routing 的
  `SLIMBUS_0_RX Audio Mixer MultiMedia1` 控件是否存在。
* **面板**：不用 plasmashell 的 D-Bus `evaluateScript`（实测有时不注册该方法），
  改用桌面配置里是否有 `plugin=org.kde.panel`。
* **GPU fault**：只看**速率**（设备上有 `raphael-health.timer` 每 5 分钟记一次近 5 分钟增量），
  不看累计值 —— 累计值会因环形缓冲回绕而**下降**。
* **息屏**：`DPMS=Off` 是**期望值**（空闲息屏），此时 GPU fault 速率应为 0/分钟。

## 已知不可用项（不在本报告判定内）

* **麦克风**：ADSP 的 ADM 拒绝采集路由（`ADM_CMD_MATRIX_MAP_ROUTINGS_V5` → error 2）。
  病因链与后续内核排查计划见 [microphone-and-kernel-plan.md](microphone-and-kernel-plan.md)。
* **刷机**：需要硬件按键进 fastboot（五种软件途径已验证不可行，见
  [flash-checklist.md](flash-checklist.md)）。
* **耳机出声 / 投屏出画**：链路与状态都已验证，实际输出待硬件确认。
