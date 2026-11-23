# LG V50 ThinQ（flashlmdd / LM-V500N）主线 Linux 移植

目标：把主线 Linux 跑在 LG V50 ThinQ（SM8150）上，保留 Android 双系统可来回切换。

## 当前阶段

**第 0 步：立项评估中** —— 正在建资料池、核对硬件、做复用调研。
内核构建走 GitHub Actions，不在本机构建机做全量编译。

## 设备事实（已在本机核实）

| 项 | 值 |
|---|---|
| 型号 | LM-V500N（韩版），`ro.boot.vendor.lge.product.name=flashlmdd_lao_com.OPEN_KR` |
| 代号 | `flashlmdd` |
| SoC | Qualcomm SM8150（Snapdragon 855），msmnile |
| bootloader | 已解锁（`unlocked: yes`），A/B 双槽（`_a` / `_b`）|
| 现系统 | LineageOS 22.2（Android 15），`_b` 槽，Magisk root |
| 内核（原厂侧） | `4.14.355-openela-perf+`（`nobody@android-build`，clang 19.0.1）|
| 存储 | UFS（`soc/1d84000.ufshc`），A/B + 动态分区（super）|
| 显示 | 6.2" P-OLED 1440x3120，PAGESIZE 4096 |
| PMIC | PM8150 / PM8150B / PM8150L（SPMI SID0 / SID2 / SID4）|
| 按键 | 音量上 → `gpio-keys`（code 115）；音量下 → PM8150 `pon_2`（RESIN，code 114）；电源 → `pon_1`（code 116）|
| 触摸 | `touch_dev`（LGE synaptics / FT3518 多模组）|
| 槽位 backup | `boot_a`=`e3301193…`（docker 定制内核）、`boot_b`=`477ce8ba…`（LOS22+Magisk）|

## 复用调研（重点）

同 SoC（SM8150）已有两个近期的主线移植项目，是本项目的主要参考：

| 项目 | 路线 | 与本案的关系 |
|---|---|---|
| [`Bronya-Hacker/xiaomi-cepheus-linux`](https://github.com/Bronya-Hacker/xiaomi-cepheus-linux) | edk2-msm UEFI → 从 recovery 分区读 `Image`，无头服务器，6.17-sm8150，WiFi/蓝牙/充电/RTC/看门狗可用 | **最贴近的同类项目**：同 SoC、同 PMIC 家族、同 bootloader 类型；DTS 片段、payload、看门狗/自愈设计可直接借鉴 |
| [`HemangKumawat/omarchy-mobile-coral`](https://github.com/HemangKumawat/omarchy-mobile-coral) | Pixel 4 XL（coral，同为 SM8150）主线 6.17.0-sm8150，DTS + patches + initramfs | 同为手机形态（有屏有触控），可参考显示/触控路径 |

上游：`arch/arm64/boot/dts/qcom/sm8150*.dtsi` 已在上游，SM8150 板级支持（mtp/hdk）存在；
LG V50 没有上游板级 DTS，需要自写。

## 构建（CI）

`.github/workflows/build-kernel.yml`：

- 手动触发（可指定 kernel tag / defconfig）+ push 自动触发
- `concurrency` 自动取消同分支旧 run
- 拉取稳定的 mainline 内核 → 应用 `patches/` → 安装 `dts/` → 编译 `Image.gz dtbs modules`
- 产物：`Image.gz`、`config`、`sm8150*.dtb`、内核 commit

`dts/` 为空时只构建上游 sm8150 目标，用于验证工具链与流水线。

## 目录

```
.github/workflows/build-kernel.yml   CI
dts/                                 板级 DTS（待写：flashlmdd）
patches/                             内核补丁
```

## 打包与启动（研究结论）

### boot.img 的硬参数（来自本机原厂 `BoardConfigCommon.mk`，不是猜的）

```
BOARD_BOOT_HEADER_VERSION    := 2
BOARD_KERNEL_PAGESIZE        := 4096
BOARD_KERNEL_BASE            := 0x00000000
BOARD_KERNEL_OFFSET          := 0x00008000
BOARD_RAMDISK_OFFSET         := 0x01000000
BOARD_KERNEL_TAGS_OFFSET     := 0x00000100
BOARD_DTB_OFFSET             := 0x01f00000
BOARD_KERNEL_IMAGE_NAME      := Image.gz
BOARD_INCLUDE_DTB_IN_BOOTIMG := true      # DTB 必须放进 boot.img
BOARD_KERNEL_SEPARATED_DTBO  := true
BOARD_USES_RECOVERY_AS_BOOT  := true      # 无独立 recovery 分区
TARGET_NO_RECOVERY           := true
```

`scripts/mk-bootimg.sh` 用这些参数调 AOSP `mkbootimg.py` 生成 boot.img。

### 三个会让人白折腾一整天的坑（同 SoC 项目实测）

1. **DTB 里 `ufshc@1d84000` / `phy@1d87000` 默认是 `disabled`**
   上游 `sm8150.dtsi` 把 UFS 关着，板级 DTS 不覆写就没有 `/dev/sd*`。
   现象极具误导：屏幕上有企鹅、日志停在原地、USB 也扫不到，看起来像"内核崩了"，
   实际是 initramfs 在等一个永不出现的根设备。
   → `scripts/check-dtb.sh` 做编译期门禁，不 okay 就不许打包。

2. **`console=` 取最后一个，指向 USB 串口会把整机冻住**
   若 cmdline 写成 `console=tty0 console=ttyGS0`，userspace 的 `/dev/console` 是 ttyGS0；
   PC 侧没人读 COM 口 → ACM 缓冲灌满 → printk/写控制台阻塞 → systemd 全体卡死
   （实测 `dev-sda31.device` 用了 9 分钟，dbus 超时连带 NetworkManager 永远不起）。
   → 正常启动只用 `console=tty0`；USB 串口只给 userspace 的 getty/维护 shell 用。

3. **改了 DTB 必须重新打包 boot.img**
   DTB 在 boot 镜像里，不刷 boot 等于没改。刷前核对文件 mtime/md5，
   别把旧的 boot 镜像刷进去（同 SoC 项目踩过一次）。

### 三条启动路径（按风险从低到高）

| 路径 | 命令 | 风险 | 用途 |
|---|---|---|---|
| 内存启动 | `fastboot boot boot.img` | 不写分区，重启即回 Android | **首选**，迭代内核 |
| 写非活动槽 | `fastboot flash boot_a boot.img` | 活动槽仍是 `_b`，坏了不影响 | 验证接近真机 |
| 写活动槽 | `fastboot flash boot_b boot.img` | 起不来就进不了 rec（本案 rec 在 boot ramdisk 里） | 最后一步 |

⚠️ `fastboot boot` 在 **fastbootd**（从 recovery 起的 userspace fastboot）**不支持**，
会报 `Unrecognized command boot`。必须进**真 bootloader 的 fastboot**（音量下 + 插线）。

### DTB 与 bootloader 的关系（待验证）

LG 的 ABL 会把 `dtbo` 分区叠加到内核 DTB 上，叠加需要设备树里有 `__symbols__`。
主线设备树默认不带符号表，叠加失败时 bootloader **可能静默拒绝**（不报错）。
首启若出现"`fastboot boot` 返回 OKAY 但完全没反应"，优先怀疑这一点，
按 `references/bootloader-and-boot.md` 的做法在打包期注入符号占位节点。

## 待办（按顺序）

1. 上游 `sm8150-mtp` 基线构建通过（本 CI）
2. 第 2 步取证：提取 `/sys/firmware/fdt`、PMIC 电压、面板参数、分区布局
3. 写 `flashlmdd` 板级 DTS（以上游 dtsi + 本机取证为准，不从别家设备抄数值）
4. 内存启动（`fastboot boot`）验证：USB 网络 + shell + 超时回 Android
5. 显示 / 触控 / RAM 桌面
6. 安装到存储 + 双系统切换

## 风险

- 主线内核与 Android vendor 模块 ABI 不兼容（`CONFIG_MODVERSIONS` CRC），不能热替换现有内核，必须走独立启动镜像
- `fastboot boot` 在 fastbootd 下不可用（`Unrecognized command boot`），需在真 bootloader fastboot 下验证
- 改槽状态只能经 bootloader 自己的命令；不要手改 `misc`
