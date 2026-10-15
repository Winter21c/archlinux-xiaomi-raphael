# Raphael 实机验证报告

> 由自动化脚本在真机上逐项执行，输出原样附在下面。
> 生成时间：2026-10-15 11:51　仓库 HEAD：1542a81（重启后重跑）
> 设备：Redmi K20 Pro (raphael)，KDE 桌面形态镜像，内核 7.2.0-sm8150-ga1573649db08
> 本轮为**麦克风修复后**的完整重跑（DTB 采集路由 + UCM 重写 + 路由保活）。

## 结果

```
═══════ Raphael 全项回归 2026-10-15 11:51:34 ═══════
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
【声音 - 麦克风 (本轮修复重点)】
    ✓ 麦克风 source 存在            1
    ✓ Q6 TX 路由 (MM2)                 1
    ✓ DTB 采集路由已打补丁       3bcded4b80a581e765b975335e9263b6
【声音 - 实测录音 (静音测试, 1% 音量)】
    ✓ 录音帧数                       133120
    ✓ 非零采样占比                 96%
    ✓ 峰值                             9361
    ✓ 扬声器静音播放              0
    ✓ AFE 报错                         0
    ✓ underrun                           0
【服务】
    ✓ audio-init 结果                  success
    ✓ routing timer                      active
    ✓ routing service 结果             success
    ✓ 健康采样 timer                 active
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

═══════ 结果: 通过 33, 失败 0 ═══════
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

## 运维提示

重启 PipeWire 时**只重启 `wireplumber` 会丢 profile**（HiFi → off），重启 `pipewire`
则能保住。`raphael-audio-init.sh` 走的是后者，所以开机与异常恢复都正常。

## 仍需人工确认的项

| 项目 | 状态 |
|:--|:--|
| 3.5mm 耳机实际出声 | 未确认。切换逻辑与 codec 上电均已验证（插=走 SLIMBUS_0_RX、扬声器静音），但**没有真正插耳机听** |
| USB 外接显示器实际输出 | 未确认。移植资料已就位，未接实机验证 |
