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
