# 麦克风 + 内核移植计划（真机实验记录）

> 本轮结论：**麦克风不是"改 UCM 就能修"的问题**。我列出并实测了 12 种采集路由组合，
> 全部是数字静音（峰值 0），说明采集后端在设备树/内核侧没有可用的配置。
> 蓝牙同样需要带调试的自编译内核。内核源码已下载就位。

---

## 1. 麦克风：已完成的工作与实测结果

### 1.1 硬件与控件（都已确认存在）

```
$ arecord -l
card 0: Raphael, device 0: MultiMedia1 (*)     ← 支持采集
card 0: Raphael, device 1: MultiMedia2 (*)

$ amixer -c 0 controls | grep -E 'ADC|DEC|TX'
'ADC MUX0'..'ADC MUX8'            enum: DMIC / AMIC / ANC_FB_TUNE1 / ANC_FB_TUNE2
'ADC1 Volume'..'ADC4 Volume'
'DEC0 Volume'..'DEC8 Volume'
'CDC_IF TX0 MUX'..'CDC_IF TX8 MUX'  enum: ZERO / RX_MIX_TX0 / DEC0 / DEC0_192
'AIF1_CAP Mixer SLIM TX0'..'SLIM TX5'      (pswitch)
'MultiMedia1 Mixer SLIMBUS_0_TX'           (FE→BE)
'MultiMedia1 Mixer TX_CODEC_DMA_TX_0..5'   (codec DMA 后端)
```

ASOC 卡片结构（`/sys/kernel/debug/asoc/Raphael/`）：
`MultiMedia1` / `MultiMedia2` / `wcd934x-codec.1.auto` / `tfa987x.0-0034` /
ADSP `apr-service@4|7|8`（q6afe / q6asm / q6routing）

### 1.2 实测过的路由组合（全部静音）

| # | 组合 | 结果 |
|:--|:--|:--|
| 1 | `ADC MUXn`=DMIC × n=0..3 → `CDC_IF TXn MUX`=`DECn` → `AIF1_CAP Mixer SLIM TXn`=1 → `MultiMedia1 Mixer SLIMBUS_0_TX`=1 | 峰值 **0** |
| 2 | 同上但 `ADC MUXn`=AMIC | 峰值 **0** |
| 3 | 同 1 但改用 `MultiMedia1 Mixer TX_CODEC_DMA_TX_n` | arecord **直接失败**（流打不开） |
| 4 | SLIM TX 全部打开 + codec DMA 同时开 | 峰值 **0** |

采集本身能跑（每次都能录到 96044 字节的合法 WAV），但**内容是全零** —— 说明
PCM 通了、ADSP 会话建立了，**但没有任何一路麦克风被真正接到这条采集通路上**。

### 1.3 判断：缺的是内核/DTS 侧的东西

- 机器驱动 `sound/soc/qcom/sm8150.c`（Aospa 7.2.0）里**没有任何 DAPM 路由宏**，
  DAI 链路完全由 `qcom_snd_parse_of(card)` 从**设备树**解析 —— 也就是 raphael 的
  `sound { }` 节点里定义了哪些 FE/BE 链路，就只能用哪些
- 现有的 `sound` 节点只提供了 **播放** 用的后端（`SLIMBUS_0_RX` / `QUAT_MI2S_RX`），
  没有任何一路采集后端（例如 WCD934x 的 `TX_CODEC_DMA_TX_n` 或 VA macro 的 TX 端口）
  在设备树里被定义为 capture 链路
- 另外 Android 侧的 `mixer_paths.xml` 里通常还有 micbias / DMIC 时钟 / ANC 之类的
  设置，这些在 vendor 的 UCM 里完全没有（vendor 的 UCM 只写了 Speaker 和 Headphone）

**所以麦克风要修，必须先在设备树里补上采集用的 BE DAI link，必要时再加 codec 侧的
DAPM 路由** —— 这是内核/DTS 工作，不是配置工作。

---

## 2. 蓝牙：同样的结论（详见 [bluetooth.md](bluetooth.md)）

固件、设备树、serdev、rfkill 全部正常，卡在 `hci_dev_do_open()` 无声失败
→ 内核不发 mgmt "Index Added" → BlueZ 看不到控制器。
现有内核**没有编 `CONFIG_DYNAMIC_DEBUG`**，无法开动态调试，必须先自编译内核。

---

## 3. 摄像头：工作量最大的一项

见 [camera.md](camera.md)。要点：
- CAMSS sm8150 支持有社区补丁（`sm8150-mainline/linux` 的 `andrew/6.16-cameras`），可移植
- 但 raphael 的 4 个 sensor（IMX586 等）**在主线/社区树里都没有驱动**，
  需要自己写，且必须真机联调

---

## 4. 内核移植计划（下一步）

### 4.1 已经就位

| 项 | 状态 |
|:--|:--|
| 内核源码 | ✅ `work/kernel/kernel.tar.gz`（Aospa `sm8150/7.2.0`，266 MB，与 vendor 内核同源） |
| 交叉编译工具链 | ✅ clang 22 + lld + dtc（构建 qrtr/rmtfs 等已用它验证过） |
| 目标 defconfig | ✅ 可从 vendor 内核的 `/boot/config-7.2.0-sm8150-g29662fdcefa9` 反推 |
| 刷内核的方式 | ✅ **不用 fastboot**：设备的 `/boot` 就是 cache 分区，直接替换 `linux.efi` 后重启即可 |

### 4.2 步骤

1. **第一次构建：完全复刻 vendor 内核**（同源码 + 同 config），验证能正常开机 ——
   这一步是基线，确保后续改动可归因
2. **第二次构建：打开调试**
   - `CONFIG_DYNAMIC_DEBUG=y`（定位蓝牙 `hci_dev_do_open()` 到底失败在哪条 HCI 命令）
   - `CONFIG_BT_DEBUGFS=y`（已有）
   - 可选：`CONFIG_SND_DEBUG=y` 看 ASOC DAPM 状态
3. **蓝牙**：按 dmesg 定位 → 修（可能是波特率切换 / BD 地址 / 初始化命令超时）
4. **麦克风**：在设备树 `sound` 节点补一个 capture 的 BE DAI link（参考同 SoC 的
   `sm8250`/`qcs615` 的 sound 节点写法）+ codec 侧路由，然后写 UCM 的
   `SectionDevice."Mic"`（`CapturePCM` + EnableSequence）
5. **摄像头**：移植 CAMSS sm8150 补丁 + 写 IMX586 驱动（独立且最耗时的一项）

### 4.3 每次迭代的成本

编译 ~20-40 分钟（12 核）、`scp` 到设备 ~10 秒、重启 ~1.5 分钟。
**每一轮都需要真机反馈 dmesg**，所以这会是多轮的过程。
