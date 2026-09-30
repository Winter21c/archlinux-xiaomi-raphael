# 蓝牙排查记录（Redmi K20 Pro / WCN3998 / hci_qca）

> 结论：**固件和驱动都正常，卡在内核 HCI 初始化的最后一步**。
> `hci0` 从未被 open，因此内核从不向 BlueZ 发 "Index Added" → `bluetoothctl` 报
> "No default controller available"。这不是配置问题，需要内核侧调试。

## 1. 已经确认正常的部分

| 环节 | 证据 |
|:--|:--|
| 固件加载 | `QCA Downloading qca/crbtfw21.tlv` → `QCA Downloading qca/crnv21.bin` → **`QCA setup on UART is completed`**（完整成功） |
| 芯片识别 | `QCA Product ID 0x0a` / `SOC Version 0x40010224` / `ROM 0x1001` / `Patch 0x6699` |
| 设备树节点 | live DT 与内核自带 DTB **完全一致**：`compatible = "qcom,wcn3998-bt"` + `vddio/vddxo/vddrf/vddch0-supply` |
| serdev 绑定 | `/sys/bus/serial/devices/serial0-0` → 驱动 `hci_uart_qca` |
| rfkill | `0: hci0: Bluetooth  Soft blocked: no  Hard blocked: no` |
| 内核模块 | `bluetooth`(=m) / `hci_uart`(=m) / `btqca` / `btbcm` 均已加载 |

## 2. 失败点

```
$ btmgmt info
Index list with 0 items

$ btmgmt --index 0 info
Reading hci0 info failed with status 0x11 (Invalid Index)

$ bluetoothctl list
No default controller available

$ ls /sys/kernel/debug/bluetooth/hci0/
（空 —— 正常应有 features / commands / …，说明该设备从未被 open）
```

`/sys/class/bluetooth/hci0/` 里只有 `device`（→ `serial0-0`）、`power`、`reset`、`rfkillN`、
`subsystem`、`uevent`，**没有 `address`/`bus`/`type`/`name`** —— 半注册状态。

## 3. 内核代码里的因果链

来源：`net/bluetooth/hci_core.c`（Aospa `sm8150/7.2.0`）

```c
hci_register_dev()                 /* device_add + rfkill_register 都成功 */
  └─ queue_work(req_workqueue, &hdev->power_on)

hci_power_on()                     /* 约 905 行 */
  ├─ err = hci_dev_do_open(hdev);
  │    if (err < 0) { mgmt_set_powered_failed(hdev, err); return; }   ← 不发 Index Added
  └─ if (hci_dev_test_and_clear_flag(hdev, HCI_SETUP))
         mgmt_index_added(hdev);   /* 957 行：BlueZ 只有收到这个才知道有控制器 */
```

也就是说：`hci_dev_do_open()` 失败 → 没有 Index Added → BlueZ 完全看不到控制器。
而 `hci_dev_do_open()` 的失败**没有打日志**（该路径的报错在内核里是 debug 级别），
所以 dmesg 里"什么都看不到"，只有前面那两条
`Frame reassembly failed (-84)`（EILSEQ，UART 组帧异常）值得怀疑。

## 4. 排除项

- 不是模块缺失：`hci_uart` 已绑定 serdev
- 不是固件缺失/错误：rampatch 与 NVM 都下载完成
- 不是设备树：live DT 与内核 DTB 逐属性一致
- 不是 rfkill：软/硬阻塞都是 no
- 不是线程卡死：`ps -eLo comm | grep hci` 无卡住的工作队列线程；也没有 hung task 警告
- 不是 BlueZ 配置：`bluetoothd -n -d` 启动正常，只是收不到任何控制器事件

## 5. 下一步该怎么做（需要内核侧迭代）

1. 用 Aospa `sm8150/7.2.0` 源码重新编译内核，打开
   `CONFIG_DYNAMIC_DEBUG=y`（当前内核**没有**编这个，所以无法开动态调试）
   和 `CONFIG_BT_DEBUGFS=y`（已有）
2. 开机后对 `hci_qca` / `hci_core` / `btqca` 打开动态调试，观察
   `hci_dev_do_open()` 具体在哪一步返回错误（大概率在 HCI Reset /
   Read Local Version / Read BD Addr 这一串初始化命令中的某一条超时）
3. 按结果决定修法：
   - 若是初始化命令超时 → 检查 `qca_set_baudrate()` 之后的 UART 波特率切换
     （`Frame reassembly failed (-84)` 支持这个方向）
   - 若是 BD 地址读取失败 → 在设备树里补 `local-bd-address`，或用
     `qca_set_bdaddr()` 写入
4. 备选：换用 postmarketOS 的 `soc/qualcomm-sm8150/linux` 树（他们标注
   Bluetooth 可用），代价是内核基线从 Aospa 7.2 换成 pmOS 的版本

## 6. 现状

蓝牙**当前不可用**（`bluetoothctl` 看不到控制器，BLE/耳机/文件传输都不行）；
Wi-Fi（含 5GHz）、音频输出、显示、触摸、GPU、USB 网络共享、调制解调器均正常。
