# 蓝牙排查记录（Redmi K20 Pro / WCN3998 / hci_qca）

> **结论：已修复 ✅**
> 根因是**两个小配置**：设备树缺 `local-bd-address`，以及 `linux-firmware` 里的
> `qca/crnv21.bin` 与本机板级校准不匹配。两者都补上后蓝牙完全可用
> （真机实测扫描到 9 个设备）。修复步骤见 [README §8.9](../README.md#89-蓝牙完全不可用invalid-index--没有控制器)。

## 0. 一句话链路

控制器上报全零 BD_ADDR + 设备树没有 `local-bd-address` 覆盖 →
`hci_power_on()` 里的「地址无效就关机」分支命中 →
`hci_dev_do_close()` 立刻执行、**mgmt Index Added 从不发出** →
BlueZ 看不到任何控制器（`Invalid Index`）。固件下载其实是**成功**的。

## 1. 已经确认正常的部分

| 环节 | 证据 |
|:--|:--|
| 固件加载 | `QCA Downloading qca/crbtfw21.tlv` → `QCA Downloading qca/crnv21.bin` → **`QCA setup on UART is completed`**（完整成功） |
| 芯片识别 | `QCA Product ID 0x0a` / `SOC Version 0x40010224` / `ROM 0x1001` / `Patch 0x6699` |
| serdev 绑定 | `/sys/bus/serial/devices/serial0-0` → 驱动 `hci_uart_qca`（注意总线名是 `serial`，不是 `serdev`） |
| 供电序列 | `wcn3998-pmu`（驱动 `pwrseq-qcom_wcn`）是 `serial0-0` 的 supplier |
| rfkill | 软/硬阻塞均为 no；`/var/lib/systemd/rfkill/platform-c8c000.serial:bluetooth = 0` |
| 内核模块 | `bluetooth` / `hci_uart` / `btqca` 均已加载 |

## 2. 定位过程（可复现）

调试用内核在 `.config` 里打开 `DYNAMIC_DEBUG` + `BT_DEBUGFS` + `SND_DEBUG`
（`dsh` 构建的 `7.2.0-sm8150` 复刻版即可），然后：

```bash
# 只对蓝牙相关文件打开动态调试（带函数名+行号）
for f in net/bluetooth/hci_core.c net/bluetooth/hci_sync.c net/bluetooth/mgmt.c \
         drivers/bluetooth/hci_qca.c drivers/bluetooth/hci_uart.c drivers/bluetooth/btqca.c; do
  echo "file $f +pfl" > /sys/kernel/debug/dynamic_debug/control
done
# 触发重新探测（等价于重新下载固件）
echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/unbind
echo serial0-0 > /sys/bus/serial/drivers/hci_uart_qca/bind
```

关键日志（时间戳间隔 36 微秒）：

```
__hci_cmd_sync_sk:202: hci0: end: err 0
hdev hci0 event 3                     ← HCI_DEV_UP，open 成功
hci_dev_do_close:495: hci0 ...        ← 36 微秒后立刻关闭
hci_cmd_sync_cancel_sync:684: hci0: err 0x13   ← -ENODEV
cancel_interleave_scan:2350: hci0: cancelling interleave scan
```

`hci_core.c` 里 `hci_power_on()` 的这段就是元凶：

```c
if (hci_dev_test_flag(hdev, HCI_RFKILLED) ||
    hci_dev_test_flag(hdev, HCI_UNCONFIGURED) ||
    (!bacmp(&hdev->bdaddr, BDADDR_ANY) &&
     !bacmp(&hdev->static_addr, BDADDR_ANY))) {
        hci_dev_clear_flag(hdev, HCI_AUTO_OFF);
        hci_dev_do_close(hdev);
}
```

而 `btqca` 会设 `HCI_QUIRK_USE_BDADDR_PROPERTY`，内核于是去读
**父设备节点（也就是 DT 的 `bluetooth {}`）的 `local-bd-address`**；
我们的 DT 没有这个属性，控制器自己上报的地址又是全零 → 命中关机分支。

## 3. 修复

### 3.1 设备树补地址

```dts
bluetooth {
        compatible = "qcom,wcn3998-bt";
        vddio-supply = <&vreg_l17a_1p3>;
        ...
        local-bd-address = [<你的设备蓝牙地址>];   /* 66:55:44:33:22:11，小端序 */
};
```

`dtb/raphael-redmi-k20pro.dtb` 就是「从运行中的设备导出 U-Boot DT + 这一处 +
麦克风 MCLK 路由」得到的；`scripts/10-image-boot.sh` 会把它放进
`/boot/dtbs/qcom/` 并在引导条目里加 `devicetree` 行。地址可用本机
`wld0` 的 MAC 附近值，保持固定即可（同一台机器每次启动地址要一致）。

### 3.2 用机器自带的原厂 NVM

只补 DT **还不够**：`linux-firmware` 的 `crnv21.bin` 换上去时依然失败
（实测 `Index list with 0 items`）。设备自带的 `bluetooth` 分区（FAT16）里
`image/` 目录就是原厂固件（还有 `.b44/.b46/.b47/.b55/.b71` 等板级变体）：

```bash
mount -o ro /dev/disk/by-partlabel/bluetooth /mnt/bt
cp /mnt/bt/image/crnv21.bin   /lib/firmware/qca/crnv21.bin
cp /mnt/bt/image/crbtfw21.tlv /lib/firmware/qca/crbtfw21.tlv
umount /mnt/bt
```

`06-config.sh` 已把它做成 `raphael-bt-firmware.service`（开机自动执行、幂等；
若固件有变化且当前没有控制器，会重新探测 serdev 让它重新下载 NVM）。

## 4. 验证

```
$ btmgmt info
Index list with 1 item
hci0:  Primary controller
       addr 66:55:44:33:22:11  version 9  manufacturer 29  class 0x6c0110
       supported settings: powered connectable fast-connectable discoverable
                           bondable link-security ssp br/edr le advertising ...
       current settings: powered bondable ssp br/edr le secure-conn ll-privacy
       name raphael

$ bluetoothctl --timeout 15 scan on
[NEW] Device F8:2A:53:39:B4:A3 midea
[NEW] Device BA:23:03:00:2A:83 RUNBEN-3
...（一次扫描到 9 个设备）
```

## 5. 踩坑提示

- **不要**频繁 unbind/bind BT serdev：一次异常操作后设备卡在关机流程
  （ping 通但 sshd 已停），只能长按电源强重启。改配置优先用「替换文件 + 重启」。
- 本机 `10-raphael-watchdog.conf` 把硬件看门狗全关了（为了修 §8.2 的重启卡死），
  因此真挂起时不会自动复位 —— 记住长按电源 10 秒。
- 内核树自带的 `sm8150-xiaomi-raphael.dtb` 与**实际生效**的 U-Boot DT 不是一回事：
  `sound {}` 是空的、也没有相机节点。判断问题要看 `/proc/device-tree/` 或
  `/sys/firmware/fdt`（后者仅 root 可读）。
