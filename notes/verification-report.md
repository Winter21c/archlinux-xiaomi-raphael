# Raphael 实机验证报告

> 由自动化脚本在真机上逐项执行，输出原样附在下面。
> 生成时间：2026-10-15 21:40　仓库 HEAD：7e0a31f
> **这是设备原生构建 → 刷入真机 → 重启后的完整 46 项回归，全部通过。**
> 设备：Redmi K20 Pro (raphael)，KDE 桌面形态镜像，内核 7.2.0-sm8150-ga1573649db08
> 本轮为**麦克风修复后**的完整重跑（DTB 采集路由 + UCM 重写 + 路由保活）。

## 结果

```
【系统】
    ✓ 内核                             7.2.0-sm8150-ga1573649db08
    ✓ 系统失败单元                 0
    ✓ 用户失败单元                 0
    ✓ 普通用户 winter 存在         uid=1000(winter)
    ✓ sudo 密码                        0
    ✓ hostname                           raphael
【桌面】
    ✓ plasmashell                        active
    ✓ plasmashell D-Bus                  1
【声音 - 播放】
    ✓ 声卡 Raphael 存在              1
    ✓ wcd934x codec 加载               7
    ✓ profile 非 pro-audio/off          HiFi (Mic, Speaker)
    ✓ 扬声器 sink 存在              1
    ✓ 默认 sink 非 auto_null          alsa_output.platform-sound.HiFi__Speaker__sink
【声音 - 3.5mm 耳机通路 (静音验证)】
    ✓ 耳机未插时功放关闭        Off
    ✓ 耳机后端 mixer 关闭          1
    ✓ 扬声器后端 mixer 开启       1
【声音 - 麦克风 (本轮修复重点)】
    ✓ 麦克风 source 存在            1
    ✓ Q6 TX 路由 (MM2)                 1
    ✓ DTB 采集路由已打补丁       3647f98fc177abdd99ecc03cedd7cbce
【声音 - 实测录音 (静音测试, 1% 音量)】
    ✓ 录音帧数                       378880
    ✓ 非零采样占比                 99%
    ✓ 峰值                             32762
    ✓ 扬声器静音播放              0
    ✓ AFE 报错                         0
    ✓ underrun                           0
【服务】
    ✓ audio-init 结果                  success
    ✓ routing timer                      active
    ✓ routing service 结果             success
    ✓ 健康采样 timer                 active
【输入法 fcitx5 + Rime】
    ✓ fcitx5 已安装                   yes
    ✓ fcitx5-rime 已安装              yes
    ✓ Rime 方案文件                  12
    ✓ 默认输入法 = rime             rime
    ✓ GTK_IM_MODULE=fcitx                1
【USB 外接显示器 (MS91xx)】
    ✓ usbdisp_drm 模块已装           yes
    ✓ usbdisp_drm 已加载              1
    ✓ DRM card1 驱动                   msdisp_plat
    ✓ HDMI 输出连接器               3
    ✓ 开机自动加载已配置        yes
【GPU】
    ✓ FD_MESA_DEBUG=noubwc (全局+KWin) 3
    ✓ KWin 运行环境已继承         1
【Wi-Fi】
    ✓ wld0 存在                        1
    ✓ wld0 已获取 IP                  192.168.31.90
【存储/软件】
    ✓ btrfs @/@home/@swap 三子卷      3
    ✓ 根挂载是 btrfs                 1
    ✓ swap 已启用                     2

═══════ 结果: 通过 46, 失败 0 ═══════
```

## 本轮新增/变化的验证项

| 项目 | 说明 |
|:--|:--|
| 内置麦克风 | 开机自动到位，零人工干预录音 131072 帧（2.73s）、非零 97%、underflow 与 DSP 错误均为 0。**连续 5 次录音全部成功**（非零 91%~99%），峰值 19926~32762 |
| 扬声器与麦克风共存 | 新增。MM1 供播放、MM2 供采集，Q6 FE session 槽互不抢占；录音期间扬声器 sink 仍挂载 |
| Q6 TX 路由 (MM2) | 新增。`MultiMedia2 Mixer SLIMBUS_0_TX` 恒为 on |
| DTB 采集路由 | 新增。已打补丁的 DTB 与构建脚本产物一致 |
| KWin 环境继承 | 新增。`FD_MESA_DEBUG=noubwc` 在 `/etc/environment` 与 KWin drop-in 两处，且已被 KWin 进程继承 |
| btrfs 三子卷 | 断言改用 `fstab` + 挂载来源（该机 `findmnt -o SUBVOL` 返回空），`@`/`@home`/`@swap` 齐全 |
| 输入法 fcitx5 + Rime | 新增 5 项。已安装、12 个 Rime 方案、`DefaultIM=rime`、`GTK_IM_MODULE=fcitx` 均通过 |
| 3.5mm 耳机通路 | 新增 3 项基线断言（耳机未插时 `HPHL/HPHR PA`=Off、耳机后端 mixer=Off、扬声器后端 mixer=On），配合上一节的强制耳机路由实验，覆盖耳机通路的两种状态 |
| USB 外接显示器 (MS91xx) | 新增 5 项。`usbdisp_drm` 已装且已加载，DRM `card1` 驱动为 `msdisp_plat`，暴露 3 个 `HDMI-A-*` 连接器，开机自动加载已配置 |

## 运维提示

重启 PipeWire 时**只重启 `wireplumber` 会丢 profile**（HiFi → off），重启 `pipewire`
则能保住。`raphael-audio-init.sh` 走的是后者，所以开机与异常恢复都正常。

## 3.5mm 耳机通路：软件侧完整验证

耳机输出级由 WCD9340 的 `HPHL PA` / `HPHR PA` 两个 DAPM widget 驱动。真机
实测（全程静音：全零 WAV、3% 音量），两条分支对比：

| 状态 | `HPHL PA` | `HPHR PA` | `SLIM RX0/1 MUX` | `RX INT1/2 DEM MUX` | PCM state |
|:--|:--|:--|:--|:--|:--|
| 扬声器模式（基线） | Off | Off | Off | — | — |
| 耳机路由 + 静音播放 | **On** | **On** | **On** | **On** | RUNNING |

配套指标：`pw-play` 退出码 0、AFE 报错 0、underrun 0。

结论：**耳机输出级确实上电，整条 `MultiMedia1 → SLIMBUS_0_RX → WCD9340 →
HPHL/HPHR` 通路是通的** —— 这恰好是 `pro-audio` profile 会失败的地方
（`AFE enable for port 0x1006 failed -110/-22`）。唯一剩下的只是"插上耳机
用耳朵听"，那需要物理操作。

还原后：`raphael-audio-routing.timer` = active、profile 回到
`HiFi (Mic, Speaker)`、`HPHL/HPHR PA` 回到 Off，扬声器路由恢复。

## 刷机链路的实测结论

镜像不是"构建成功"就算数 —— 走完 **构建 → 刷机 → 重启 → 回归** 才算。
两轮刷机各暴露出一批只有真机才会发现的问题（详见
[flash-checklist.md](flash-checklist.md)）：

| 轮次 | 结果 | 发现 |
|:--|:--|:--|
| 第一次刷入 | 41/46 | `raphael-audio-routing.sh` 缺 `chmod 755`（systemd 203/EXEC → 麦克风非零只剩 9%）；`loop` 模块没加载 → btrfs 静默退化 flat，丢了 `@`/`@home`/`@swap` |
| 第二次刷入 | **46/46** | 无 |

### ⚠️ 一个容易误判成"功能坏了"的运维现象

反复做录音测试（尤其被 `kill -9` 打断）会**泄漏 Q6 DSP 会话**，
`/proc/asound/card0/pcm1c/sub0/status` 卡在 `SETUP`，之后：

* `arecord` 报 `Device or resource busy`
* `pw-record` 能开、能出帧数，但**全是零**（看起来像"麦克风又坏了"）
* 更麻烦的是 ACP 探测 `hw:0,1` 失败 → **放弃整个 UCM** → profile 掉到 `off`

实测**重启即可完全复位**（重启后 `pcm1c` 回到空闲，首次录音 98% 非零）。
所以排查麦克风时先看这一条，别急着改代码 —— 这一轮我在这上面绕了很久。

## 仍需人工确认的项

| 项目 | 状态 |
|:--|:--|
| 3.5mm 耳机实际出声 | **软件侧已完整验证**：`HPHL PA`/`HPHR PA` 在耳机路由下均为 On、PCM RUNNING、AFE 报错 0、underrun 0。刷机后回归里"耳机未插时功放关闭/耳机后端 mixer 关闭/扬声器后端 mixer 开启"三项也全过。仅剩"插上耳机用耳朵听" |
| USB 外接显示器实际输出 | **软件侧已验证**（刷机后回归 5 项全过）：`usbdisp_drm` 已加载、DRM `card1` 驱动 `msdisp_plat`、暴露 3 个 `HDMI-A-*` 连接器、开机自动加载已配置。接上 MS91xx 转接器即可点亮 |
