# 为什么主线内核起不来 —— 排查记录

设备：LG V50 ThinQ（flashlmdd / LM-V500N，SM8150，ARMv8.2-A）
测试方式：真 bootloader fastboot 下 `fastboot boot <boot.img>`（内存启动，不写分区）

## 已排除的原因

| # | 假设 | 验证方式 | 结论 |
|---|---|---|---|
| 1 | boot.img 布局不对 | 逐字段对比原厂 `boot_b_orig.img` | 已修：`dtb_addr` 必须 `0x1f00000`（不是 `0x100`）、`recovery_dtbo` 必须保留（6 MB 原厂 overlay）、AVB vbmeta+`AVBf` footer 必须嫁接 |
| 2 | DTB 被 magiskboot 改写 | 对比打包前后 DTB md5 | 已避免：改为自己构造 boot header，DTB 字节原样写入 |
| 3 | 板级 DTB 有问题 | 用上游 `sm8150-mtp.dtb` 做对照测试 | **同样失败** → 排除板级 DTB |
| 4 | EFI stub 让 LK 无法进入 | 反汇编 Image 头 | **不是原因**：`code0=0xfa405a4d` 是 `ccmp x18,#0,#0xd,pl`（"MZ" 签名 NOP），`code1` 才是 `b primary_entry`，LK 从 +0 执行会先跑无害的 ccmp 再分支，路径是通的 |
| 5 | 52 位 VA + LPA2 | 对比原厂 `/proc/config.gz` | **确实不对，已修**（见下） |

## 关键证据：原厂内核是 39 位 VA，我们编成了 52 位

```
原厂 4.14（能启动）            我们 7.3.6（起不来）
CONFIG_ARM64_VA_BITS=39        CONFIG_ARM64_VA_BITS=52
CONFIG_ARM64_VA_BITS_39=y      CONFIG_ARM64_VA_BITS_52=y
（无 LPA2 选项）                CONFIG_ARM64_LPA2=y
（无 MTE/BTI/POE/HAFT/EPAN）    MTE/BTI/POE/HAFT/EPAN 全 y
```

SM8150 是 ARMv8.2-A：LPA2 需要 ARMv8.7（FEAT_LPA2），MTE/BTI 需要 v8.5，POE 需要 v8.6，HAFT 需要 v8.7 —— 全都没有。内核按 52 位页表格式启动会在 MMU 初始化阶段死，那时 console 和 pstore 都还没初始化，所以：

- `pstore` 全空
- 秒失败、ABL 判定启动失败
- recovery 正常（跑的是原厂 4.14）

**已修**（commit `402f1ea`）：强制 `VA_BITS_48` / `PA_BITS_48`，关掉 `LPA2`/`MTE`/`BTI`/`POE`/`HAFT`/`EPAN`，并加了 CI 门禁（不满足直接 fail）。

修复后 CI 通过（run 45216489104），产物核对：
```
CONFIG_ARM64_VA_BITS=48  PA_BITS=48  VA_BITS_52 不存在  LPA2 不存在
Image: code0=0xfa405a4d  code1=0x14a2f427(分支)  magic=ARMd
DTB: ufshc@1d84000/phy@1d87000 均 okay
```

**但 48 位版实测仍然起不来**（`fastboot boot` 后进 recovery）。

## 还没排除的原因（按可能性排序）

### 1. LK 把 dtbo 分区叠加到我们的 DTB 上，叠加失败

原厂 cmdline 带 `androidboot.dtbo_idx=1` —— ABL 会从 `dtbo` 分区取 overlay 叠加到 boot.img 的 DTB 上。那份 overlay 是针对**厂商 DTB 的节点名**编译的，叠加到主线 DTB 上必然找不到目标节点。

主线 DTB 虽然用 `DTC_FLAGS=-@` 生成了 `__symbols__`，但 overlay 引用的 label（厂商私有）不存在 → 叠加失败 → LK 可能直接拒绝启动（且不报错）。

**验证办法**：往 `dtbo_b` 写一个空的/最小 dtbo，让叠加变成 no-op，再测。
（写分区有风险，但 dtbo 可完整备份恢复）

### 2. 没有可用的输出通道，看不到内核死在哪

设备上唯一可用的输出通道是：
- USB gadget ACM（需要内核跑到 initramfs 的 init）
- 显示（需要 DRM/panel 驱动起来）

如果内核死在 initramfs 之前，就完全没有输出。pstore 需要 ramoops 注册成功，而它属于较晚的 initcall。

**已修的 bug**：`gen-board-dts.sh` 里我最初写的 ramoops 是 `0xb0000000 + 0x400000`，而原厂 reserved-memory 里是 `0xb0000000 + 0x300000` —— **重叠会让 ramoops 注册失败**。已改为与原厂完全一致。

### 3. 主线 SM8150 平台支持本身还不完整

同 SoC 的两个近期项目都**没有走 LK + boot.img 路线**：
- `xiaomi-cepheus-linux`（小米9 / SM8150）：**edk2-msm UEFI** → 从 recovery 分区读 `Image`
- 主线 SM8150 的 rpmh/clk/regulator 依赖链在陌生板级上可能 probe 失败

如果 dtbo 和 ramoops 都排除后仍失败，应该转 edk2-msm UEFI 路线（借用 cepheus 的 payload 结构）。

## 下一步（按顺序）

1. **给 dtbo 做空 overlay**，排除 LK 叠加失败（需备份 `dtbo_b` 后写入）
2. 修正后的 ramoops 生效后，若内核 panic 发生在 ramoops 之后，重启即可在 `/sys/fs/pstore` 读到日志（需要能进 Android/recovery 并有 root 或 ADB）
3. 若仍无输出，改用 **edk2-msm UEFI** 引导（参考 `xiaomi-cepheus-linux` 的 `boot.img`/payload 组织方式）
4. 长期：把 `flashlmdd` 的 UFS/PMIC/面板参数补进主线 DTS，逐步上游化

## 现有可复现资产

- CI：`.github/workflows/build-kernel.yml`（含 4 道门禁：dtbs、DTB ufshc/phy、48 位 VA、Image 入口）
- 打包：`scripts/mkbootimg-v50.py`（原厂布局 + AVB 嫁接 + recovery_dtbo）
- 板级 DTS 生成：`scripts/gen-board-dts.sh`（上游 mtp + V50 增量）
- 维护 initramfs：`/opt/lgv50/images/v50-maint.cpio.gz`（含 parted、USB 串口控制台、30 分钟超时自动重启）
