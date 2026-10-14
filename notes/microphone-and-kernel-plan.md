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

---

> **2026-10-15 更新：又推进了两步，并确认了当前的确切卡点。**
>
> 1. **上游 DTB 里其实有采集/耳机链路的完整定义**（我也一度以为要自己写）：
>    `slimcap-dai-link`（cpu=q6afe DAI 0x03、"SLIM Capture 1"）、
>    `slim-playback-dai-link`（cpu=q6afe DAI 0x02、"SLIMBUS_0 Playback"）、
>    `codec@1,0 { compatible = "slim217,250"; }`（phandle 0xed，SLIMbus 地址 217:250:1:0）。
>    但 `10-image-boot.sh` 会把这两条链路**删掉**（历史原因：那时 codec DAI 枚举不出来，
>    缺了就让整块声卡卡在 EPROBE_DEFER）。删掉后声卡永远能注册、扬声器稳定。
> 2. **实测：现在（新内核 7.2.0-sm8150-ga1573649db08）codec 能稳定枚举了** ——
>    `217:250:1:0` 绑上了 `wcd934x-slim`，模块 `snd_soc_wcd934x` 等全部加载。
>    把两条链路**加回设备树**后真机验证：
>    * 声卡组件里多出 `wcd934x-codec.1.auto` ✓（codec 进卡成功）
>    * 扬声器**依然正常**（静音播放 PCM RUNNING、AFE 报错 0 条）✓
>    * `arecord -l` 也能列出采集设备 ✓、codec 的 `AMIC MUX0`/`CDC_IF TX0 MUX` 控件都在 ✓
>    * 但 **`arecord -D hw:0,0` 仍然 EINVAL**，dmesg 里是
>      `wcd934x-slim 217:250:1:0: TX timed out:MC:0x21,mt:0x2`
>      —— **SLIMbus 上行(TX)超时**，和 §1.3 的判断一致：卡在 SLIMbus/ADSP 这条路上。
>    * 耳机侧同样不通：把 UCM 的 `Headphone`（`PlaybackPCM "hw:0,0"`）加回去后，
>      ACP 探测这个 PCM 失败 → **整块声卡的 active profile 掉成 `off`**（sink 消失）。
> 3. 因此**保留了原作者的 DTB**（不删链路的那版会带来风险却没有可见收益），
>    UCM 也只暴露 Speaker。要真正修好麦克风/耳机，需要解决 **SLIMbus TX
>    （slim-ngd QMI/ADSP 侧）**，这仍然是内核级工作。
>
> 排查中用到的现成手段（下次可直接复用）：
> * 备份：`/boot/dtbs/qcom/raphael-redmi-k20pro.dtb.safe`（原版）
> * 打补丁：`dtc -I dtb -O dts` → 在 `sound { }` 里加 `slimcap-dai-link` /
>   `slim-playback-dai-link`（phandle 用文件里现成的：q6afe=0xff、platform=0x100、
>   codec=0xed）→ `dtc -I dts -O dtb` → 覆盖回 `/boot/dtbs/qcom/`
> * 验证：`ls /sys/kernel/debug/asoc/Raphael/`（看有没有 wcd934x-codec）、
>   `arecord -l`、`arecord -D hw:0,0 ... /tmp/rec.wav` 后看峰值是否非零
> * 回滚：把 `.safe` 拷回去 + `systemctl reboot`


---

## 2026-10-15 第二轮：竞态被修好，耳机通了，麦克风仍卡在 SLIMbus TX

### 1. 真正的原因是**加载竞态**，不是 DTB 里该不该有那条链路

前一轮我以为是"slimcap 链路让声卡卡住"，其实真正的机制是：

```
开机 -> snd_soc_sm8150 自动加载 (~5s) -> qcom_snd_parse_of 找 codec
      -> codec(wcd934x) 要 ~13s 才枚举出来 -> EPROBE_DEFER -> 重试
      -> 重试耗尽 -> 要么声卡**永久注册失败**(aplay -l 一个卡片都没有),
         要么只保留 3 条链路(slimcap/slim-playback 被丢弃)
```

所以现象时好时坏(取决于 codec 那一次赶上没赶上)，而"删掉 slim 链路"只是**掩盖**
了它 —— 代价是 codec 永远进不了声卡，麦克风/耳机彻底没戏。

**修复**(`06-config.sh`，已真机验证)：把声卡也延后加载，和项目当年对 slim-ngd 的做法一样：

```conf
# /etc/modprobe.d/raphael-audio.conf
blacklist slim_qcom_ngd_ctrl
blacklist snd_soc_sm8150          # ★ 新增
```
```bash
# raphael-audio-init.sh：等 codec 就绪再加载声卡
i=0; while [ $i -lt 80 ] && [ ! -e /sys/bus/slimbus/devices/217:250:1:0/driver ]; do
  i=$((i+1)); sleep 0.5
done
modprobe snd_soc_sm8150
```

结果：**`qcom_snd_parse_of OK: 5 links`** —— 5 条链路稳定全部解析成功，
声卡组件里出现 `wcd934x-codec.1.auto`（1251 个控件），扬声器依旧正常(0 报错)。

### 2. 3.5mm 耳机 —— **通了**

耳机是 WCD9340 的 HPHL/HPHR 模拟通路，走 SLIMBUS_0_RX。要点两条：

1. codec 必须进声卡（上面已解决）
2. **打开 `SLIMBUS_0_RX Audio Mixer MultiMedia1` 之前，必须先把 codec 的 HPH 通路
   上电**（`SLIM RX0/1 MUX` → `RX INT*_1 MIX1 INP0` → `COMP1/2 Switch` →
   `RX INT* DEM MUX`）。不上电就开路由，播放会**卡住**（pw-play 超时 124），
   因为 DSP 一直在等一个没上电的后端。

上电后的实测：

```
HPHL = HPHL: On  in 1 out 1        ← 耳机左声道功放已上电
HPHR = HPHR: On  in 1 out 1        ← 右声道
静音播放: 退出码=0, 期间报错 0 条, 播放中 pcm0p: state RUNNING
```

这两步都写进了 `raphael-audio-init.sh` 和 `raphael-audio-routing.sh`（幂等，每 20 秒兜底）。

### 3. 麦克风 —— 仍然不行，卡点精确到 SLIMbus 上行

- 保留 slimcap 链路后 `arecord -D hw:0,0` 直接 **EINVAL**（采集会走到 SLIMBUS_0_TX
  这个后端）；不保留该链路时能打开但**样本全零**。
- dmesg 里的直接证据：`wcd934x-slim 217:250:1:0: TX timed out:MC:0x21,mt:0x2`
  —— **SLIMbus 上行(TX)超时**，codec 的采集方向根本没起来，所以模拟前端不出信号。
- 这与 §1.3 的判断一致（缺的是内核/固件侧的采集后端），现在是**可复现的精确卡点**：
  要修得从 qcom slim-ngd / ADSP 的 TX 通道下手，属内核级工作。

### 4. DTB 的最终选择

用**内核作者 deb 里那份** `qcom/sm8150-xiaomi-raphael.dtb`（已替换 `dtb/`），
它与项目原先"从 U-Boot 导出"的那份相比只有 46 行差异，其中
**panel/dsi/touchscreen/backlight/mdss 零差异**（已逐项 diff 确认），
其余差异是 U-Boot 自带的 serial-number/uefi-mmap/bootargs/内存 reg —— 内核走 EFI
启动时内存由固件提供（`/sys/firmware/efi` 存在），实测多次启动正常。


---

## 2026-10-15 第三轮：把采集链路彻底钉死（能开、能录、恒为 0）

这一轮把麦克风问题从"打不开"推进到"打得很开，但样本恒为 0"，卡点范围缩到最后一环。

### 1. 采集其实是能打开的 —— 关键是**顺序**

`arecord -D hw:0,0` 报 EINVAL 有两个前提条件，缺一个就打不开：

```bash
# 必须先把采集路由设上, 再打开 PCM
amixer -c 0 cset "name='AMIC MUX0'" 1                        # 选 ADC1（主麦 AMIC1）
amixer -c 0 cset "name='CDC_IF TX0 MUX'" DEC0
amixer -c 0 cset "name='AIF1_CAP Mixer SLIM TX0'" 1
amixer -c 0 cset "name='MultiMedia1 Mixer SLIMBUS_0_TX'" 1    # FE→BE
arecord -D hw:0,0 -f S16_LE -r 48000 -c 2 -d 2 /tmp/rec.wav   # 此时能开
```

顺序对了以后 `arecord` 稳定打印 `Recording WAVE ... 48000 Hz Stereo`，
文件大小正常（192044 字节 / 2 秒 ✓）。**但解码出来是精确的全零**：峰值 0、
非零样本 0、RMS 0.0 —— 连本底噪声都没有。

### 2. 项目 §8.10 的"MCLK 依赖"方案：控件全都存在，但补上之后仍然是 0

先确认过 DAPM 部件名**全部存在**（`wcd934x-codec.1.auto` 共 247 个部件）：

```
MCLK 存在 ✓   AIF1 CAP ✓   AIF2 CAP ✓   AIF3 CAP ✓   SLIM TX0 ✓
MIC BIAS3/4 ✓  AMIC1 ✓  AMIC3 ✓  RX_BIAS ✓   （ANA_BIAS 不存在）
```

于是按 §8.10 的方案把采集侧时钟依赖写进设备树的 `audio-routing`：

```bash
fdtput -t s <dtb> /sound audio-routing \
  "RX_BIAS" "MCLK" "AMIC1" "MIC BIAS3" "AMIC3" "MIC BIAS4" \
  "AIF1 CAP" "MCLK" "AIF2 CAP" "MCLK" "AIF3 CAP" "MCLK" "SLIM TX0" "MCLK"
```

结果：声卡照常注册（**5 条链路全在**，没有 "Failed to add route"），
`MCLK` 部件也确实出现在 DAPM 图里（`widget-type supply`，`out "static" "SLIM TX0"`），
**但录音仍然是全零**。也就是说 §8.10 当年补的时钟依赖不是最后那一环。

> 设备树最终**保留了内核作者 deb 里那份**（不加这几条额外路由）：加了没有可见收益，
> 而它曾一度让我误判"播放坏了"（真实原因是我的测试文件放在 /tmp，重启后被 tmpfs
> 清掉了，`pw-play` 报的是 `failed to open audio file`，不是音频问题）。

### 3. 现在的确切结论

* 采集链路的**软件部分全部就位**：FE(q6asm MultiMedia1) → `MultiMedia1 Mixer
  SLIMBUS_0_TX` → BE(q6afe SLIMBUS_0_TX) → SLIMbus → codec TX0 → DEC0 → ADC1 → AMIC1，
  每一段的控件都能设上、DAPM 图里都有对应部件。
* 采样**精确为 0**（不是噪声、不是静音段），说明数据从模拟前端出来就是 0 ——
  卡在 **codec 的模拟前端（AMIC/MIC BIAS/ADC）或 ADSP 的 ADM/采集会话**这一环。
* 下一步值得试的方向（留给后续）：
  1. 用 `debugfs` 看采集时 ADM/ASM 的会话是否真的建立（`q6asm` 的 `MM_UL1` 端口）；
  2. 对照 Android 的 `mixer_paths.xml` 检查 AMIC 的 micbias 电压/时钟档位；
  3. 抓 codec 寄存器（`wcd934x` 的 ADC/AMIC 寄存器）看在录音时有没有被真正打开。


### 4. 补充证据（同一轮稍后）：DAPM 图里采集通路**从未上电**

关键控件的真实语义（别再猜了）：

```
$ amixer -c 0 cget "name='AMIC MUX0'"
  ; type=ENUMERATED,values=1,items=5
  ; Item #0 'ZERO'  #1 'ADC1'  #2 'ADC2'  #3 'ADC3'  #4 'ADC4'
  : values=1        ← 当前 = ADC1（主麦 AMIC1 那一路）
```

也就是说 §8.10 里 `cset name='AMIC MUX0' 1` 是对的（`1` = ADC1），不是这里的问题。

再看 DAPM 部件的真实状态（挂载后直接读 debugfs）：

```
AMIC1    AMIC1: Off  in 1 out 0
ADC1     ADC1: Off  in 1 out 0 - R1550(0x60e) mask 0x80
MCLK     MCLK: On  in 0 out 0          ← 时钟在（audio-routing 起效了）
```

`out 0` = 这两个部件的**输出端没有任何激活的下游** —— 采集通路没有形成一条
"源(AMIC1) → 汇(DAI)" 的完整激活路径，所以 DAPM 压根不给它上电。
而它上不了电的原因又回到同一件事：**采集 PCM 打不开**（EINVAL），没有流就没有
DAPM 触发；打不开又可能和路由 mixer 未就位有关 —— 这次实测到的规律是：

* 先设好 `AMIC MUX0=ADC1` + `CDC_IF TX0 MUX=DEC0` + `AIF1_CAP Mixer SLIM TX0=1`
  + `MultiMedia1 Mixer SLIMBUS_0_TX=1`，**再** arecord → 能打开（表现为 Recording WAVE）
* 顺序反了、或中间被 ACP 复位 → EINVAL
* 即便打开了，样本也**精确为 0**（峰值 0 / RMS 0.0 / 非零样本 0）

所以采集这条链现在有三层，一层比一层深：

1. **打开 PCM** —— 顺序敏感，能过（需要把路由 mixer 在打开前设好并防 ACP 复位）
2. **DAPM 上电** —— 从没观察到 `AMIC1/ADC1` 变 On（`out 0`），说明软件侧的
   DAPM 图没把采集通路接起来
3. **模拟前端出信号** —— 即便前两层都过了也还是 0，卡在 codec AMIC/MIC BIAS/ADC
   或 ADSP 的采集会话（`q6asm` 的 MM_UL 端口）

下一步具体建议：录音时读 `wcd934x` 的寄存器（`/sys/kernel/debug/regmap/*/registers`
或 codec 的 `codec_reg`），比对 ADC1/AMIC1/MIC BIAS 那几位的实际值 ——
能直接判定是"寄存器没开"还是"开了但没信号"。
