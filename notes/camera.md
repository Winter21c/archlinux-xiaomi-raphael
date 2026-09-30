# 摄像头适配结论与路线图（K20 Pro / SM8150 / raphael）

> 结论先说：**安卓那套相机栈搬不过来；而主线这边缺的是更底层的东西 —— sm8150 的相机控制器
> 驱动、设备树节点、以及 sensor 驱动都不存在。** 目前能达到的最好状态是"硬件基础可移植，
> 但需要月级别的内核开发 + 真机联调"，不是刷个包就能出图。
>
> 本文把"为什么"和"要做到需要什么"逐条写清楚，方便你决定投多少精力，也方便以后直接照着做。

---

## 1. 现状：三层缺口

| 层次 | 需要什么 | 现状 | 证据 |
|:--|:--|:--|:--|
| ① SoC 相机控制器驱动 | `drivers/media/platform/qcom/camss` 里的 **sm8150** 资源表（CSIPHY/CSID/VFE 寄存器、时钟、互联） | ❌ 我们的 7.2 内核里**没有** sm8150 | `camss.c` 的 `camss_dt_match[]` 支持 19 个 SoC（msm8916…sm8250/sm8550/sm8650/x1e80100），**没有 sm8150** |
| ② SoC 设备树节点 | `sm8150.dtsi` 里的 `camss@ac65000`、`cci@ac4a000/ac4b000`、`csiphy`、`csid`、`vfe` | ❌ 全都没有 | 反编译本机内核实际使用的 `sm8150-xiaomi-raphael.dtb`：`camss/csiphy/csid/cci/camera` 关键字命中 **0~1 处**（只是无关字符串） |
| ③ sensor 驱动 | raphael 的 4 个摄像头 sensor 驱动 + 对焦马达 + EEPROM | ❌ **一个都没有** | 主线 + 社区树 `drivers/media/i2c/` 里有 imx363（为 Pixel 4 加的）、imx412、ov5640 等，**没有 imx586 / s5k3l6 / ov8856 / s5k3t1** 中的任何一个 |
| ④ 用户态 3A/ISP | libcamera 的 sm8150 VFE pipeline | ❌ 不存在 | postmarketOS 的 SM8150 页面把 Camera 标为 **WIP**：`qcom,sm8150-camss — Some progress is being made here` |

**内核配置里唯一"看起来有戏"的部分**（容易误判，特别说明）：
编译出来的模块里有 `qcom-camss.ko`、`i2c-qcom-cci.ko`、`v4l2-cci.ko`，
但驱动**没有 sm8150 资源表** → 设备树里也没有节点 → 它们永远不会 bind，等于不存在。
配置里开的 sensor 驱动（`imx412`/`ov5640`/`s5kjn1`）都是给开发板用的，跟这台机器无关。

---

## 2. 为什么"把安卓的搬过来"不行

安卓（小米 MIUI / 任何 K20 Pro 的 ROM）的相机是这样工作的：

```
App → Camera2 API → camera provider (HIDL/AIDL) → CAMX/CHI (闭源 blob, camera.msm8150.so)
    → /dev/v4l-subdev* 私有 ioctl → techpack/camera (msm_camera/cam_req_mgr/cam_sync/
      cam_sensor/cam_isp/cam_jpeg/cam_cpas/cam_smmu ...)
    → 硬件 (CSIPHY/CSID/VFE/ISP)
```

要把它搬到 Arch Linux，需要同时满足：

1. **内核侧**：把 `techpack/camera`（十万行量级）从 downstream 4.14/4.19 移植到 7.2 主线。
   它依赖一大堆主线没有的框架：`msm_ion`、`msm_bus`（已被 interconnect 取代）、
   `cam_smmu` 自建 IOMMU 封装、`cam_cpas`、downstream 的 clock/regulator API，
   而且暴露的是**私有 V4L2 ioctl ABI**（`msm_camera`、`cam_req_mgr`）。
2. **用户态**：CAMX/CHI 是**闭源 blob**，依赖 Android Binder、gralloc、
   camera provider HAL、ION/dmabuf heaps、Android 的 libhardware —— 在 Arch 上没有这些。
3. **数据面**：安卓相机走 Android 的 buffer 管理（gralloc/ION handle），
   要让 PipeWire/libcamera 消费这些 buffer 需要重写整条零拷贝通路。

结论：这不是"移植"，而是"在 Linux 发行版上重建一个 Android 相机运行时"。
**没有任何开源项目做到过**（postmarketOS 对 sm8150 也是走主线 CAMSS，而不是搬安卓）。

---

## 3. 现在就能用的（已内置到镜像里）

| 能力 | 说明 | 命令 |
|:--|:--|:--|
| **闪光灯 / 手电筒** ✅ | `&pm8150l_flash` 节点在设备树里已是 `okay`，`leds-qcom-flash.ko` 存在 → 手电筒可用 | `shoudian on\|off\|toggle\|status`（KDE 应用菜单里也有"手电筒"） |
| **USB 摄像头** ✅ | 内核带 `uvcvideo`（UVC 类设备通用） | 插 USB-C 摄像头/采集卡 → `/dev/video0`，KDE 里用 `plasma-camera`/VLC/`mpv av://v4l2:/dev/video0` |
| **网络摄像头** ✅ | 用另一台安卓手机装 IP 摄像头 App，本机浏览器/VLC 看流 | 无需移植 |
| **诊断** ✅ | 一条命令看清相机卡在哪一层 | `camera-check` |
| 视频**硬解**（Venus）| 内核有 `venus-*.ko`，但**设备树里没有 venus 节点** → 目前只能软解 | `mpv --hwdec=no`；想硬解也要先补 DT 节点 |

---

## 4. 真正做相机需要做什么（可执行路线）

好消息：**第 1 步的补丁已经有人写好了**，只是没进主线。
社区树 `gitlab.com/sm8150-mainline/linux` 的分支 **`andrew/6.16-cameras`**（2025-08）里有：

| 提交 | 内容 |
|:--|:--|
| `8060f266` | `media: qcom: camss: add support for SM8150` —— camss 里的 sm8150 资源表（csiphy/csid/vfe/icc） |
| `2bad4cc1` | `arm64: dts: qcom: sm8150: add CAMSS and CCI nodes` —— sm8150.dtsi 的 camss/cci 节点 |
| `6a75df54` | `dt-bindings: media: qcom: add SM8150 CAMSS binding` |
| `334cbb36` | `media: i2c: Add imx363 image sensor driver`（为 Pixel 4 写的，raphael 用不上但可当模板） |
| `78c568fa` | `arm64: dts: qcom: google-flame: add camss/cci ... ov7251/imx363`（**同 SoC 的板级例子，写 raphael 板级 DTS 时照这个抄**） |

### 路线（按依赖顺序，每步都要真机验证）

**Step 1 — 内核：合并 CAMSS sm8150 支持**（可以离线做，1-2 天）
1. `git clone -b sm8150/7.2.0 https://github.com/Aospa-raphael-unofficial/linux`（≈6 GB，和作者内核同源，
   保证触摸/显示等现有功能不丢）
2. 把上面 3 个补丁 rebase 到 7.2（`camss.c` 在 6.16→7.2 之间结构有改动，需要手工适配）
3. 用 defconfig 编译（`LLVM=1 ARCH=arm64`，本机 clang 22 就够了）
4. 产出：`Image` + 模块 → 作为**可选启动项**保留原厂内核，出问题能切回来
   > 判定标准：`dmesg | grep -i camss` 出现 probe 成功；`/dev/media0` 出现；
   > `media-ctl -p` 能看到 CSIPHY/CSID/VFE 实体

**Step 2 — 设备树：raphael 板级相机节点**（1 周，需要真机反复试）
- 4 个 sensor 挂在哪条 CCI 总线/哪个 CSIPHY lane、上电时序（regulator）、
  MCLK 时钟源、reset/pwdn GPIO —— 这些要从安卓的 kernel dts 抄
  （小米内核源码 `arch/arm64/boot/dts/qcom/sm8150-camera-sensor-*.dtsi`，
   或从设备的 `vendor_boot`/`dtbo` 分区反编译）
- 判定标准：`i2cdetect` 能在 CCI 总线上看到 sensor 地址（0x1a/0x10/0x36…）

**Step 3 — sensor 驱动：最硬的骨头**（每个 sensor 1-3 周）
- 优先主摄 **IMX586**：可以照 mainline 的 `imx412.c`/`imx577.c`（同为索尼 12bit RAW、
  CCI 寄存器风格接近）+ 安卓驱动里的寄存器序列来写
- 需要：上电序列、PLL 配置、模式表（1080p/4K 的时序）、V4L2 subdev 实现、
  链接频率、lane 数
- 其余：超广角/长焦/前摄（S5K3L6 / OV8856 / S5K3T1 之类）——逐个来，工作量线性叠加
- 对焦马达（VCM，如 DW9768/GT9764）与 EEPROM 也要单独写

**Step 4 — 用户态**（1-2 周）
- 给 libcamera 写 sm8150 的 pipeline handler（参考 `libcamera` 里 qcom 的 `qcom_camss` pipeline，
  sm8250 已有支持可借鉴），或者先用 `v4l2-ctl --stream-mmap` 抓 RAW 验证硬件通路
- 3A（自动曝光/对焦/白平衡）在没 ISP 的情况下要么用 sensor 自带 AE，要么软件 3A

**Step 5 — 集成**：PipeWire/KDE 里出图（`plasma-camera` 或 `angelfish` 调 libcamera）

### 现实预期
- 只做 Step 1+2：相机**依然不能出图**，但能验证 CAMSS/CCI 硬件通路（对社区有价值）
- 做到 Step 3（只做 IMX586）：**主摄可能出 RAW/预览**，但颜色/对焦要额外调
- 全部做完：接近 postmarketOS 上"相机基本可用"的水平，工作量以**人月**计
- **必须有真机反复联调**（dmesg、i2c 抓包、寄存器读写），离线无法验证

---

## 5. 务实的替代方案

1. **保留 Android 双系统**：相机/支付/银行类 App 仍然用 Android —— 这是最省事的
2. **USB 摄像头**：几十块的 USB-C 摄像头/采集卡，插上就能用（已内置 uvcvideo）
3. **另一台手机当网络摄像头**：IP Webcam 类 App + VLC/浏览器
4. **只想拍文件/扫码**：用 USB 采集卡接一个廉价模组

---

## 6. 一句话总结

| 问题 | 答案 |
|:--|:--|
| 能把安卓相机移植过来吗？ | **不能**。那是十万行 downstream 内核驱动 + 闭源 CAMX blob + Android 运行时，史上没人做到过 |
| 主线能做吗？ | **能，但没做完**。CAMSS sm8150 有 WIP 补丁（未进主线），sensor 驱动完全空白 |
| 现在能用什么？ | 手电筒 ✅、USB 摄像头 ✅、网络摄像头 ✅、软解视频 ✅ |
| 要我推进吗？ | 可以从 Step 1（内核合并 CAMSS）开始，但需要你当测试者逐轮反馈 dmesg |
