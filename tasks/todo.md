# PoseAI 商用化路线图

> 状态标记：`[ ]` 待执行 · `[x]` 已完成 · `[~]` 进行中 · `[!]` 阻塞/需决策

---

## P0 — 上线合规（必须修复，否则审核被拒）

- [x] **P0-1** 修复相册权限文案为空（`NSPhotoLibraryAddUsageDescription`），Apple 审核必拒
- [x] **P0-2** 摄像头权限被拒后，增加「去设置开启」按钮，恢复用户路径
- [x] **P0-3** 锁定竖屏（Info.plist 已配置 Portrait Only，确认有效）
- [x] **P0-4** 添加首次启动引导（Onboarding）：3 步动画引导，AppStorage 记录，只展示一次

---

## P1 — 核心体验缺口（上线后用户会立刻流失）

- [x] **P1-1** 拍照成功后弹出照片预览（全屏缩略图 + 「保存 / 重拍 / 分享」三个操作）
- [x] **P1-2** 倒计时自拍模式（3s / 5s / 10s 循环切换，午倒计时数字大字显示，再点可取消）
- [x] **P1-3** 暗光环境提示：Vision 有效关节点 < 4 时触发，顶部滑入黄色 Banner，5 秒节流
- [x] **P1-4** 姿势亲近度自动推荐：0.5s 节流对所有方案打分，高出 8 分且 > 15 才切换（无需训练模型，复用 PoseMatcher）
  - 用户手动选择后 8s 内屏蔽自动切换

---

## P2 — 差异化与留存（决定口碑和复购）

- [x] **P2-1** 连拍模式：姿势匹配后自动连拍 3 张，进入照片回顾页横向选片
- [x] **P2-2** 本次拍摄历史：Session 内拍摄的照片可在底部小缩略图回顾
- [x] **P2-3** 扩充方案库：新增「城市街道 / 公园 / 室内家居 / 夜晚霓虹」场景（各 3 套方案），并增强了 MobileNet 的关键词匹配器
- [x] **P2-4** 社交分享：连拍选片及保存时提供带"Shot on PoseAI"专属水印的快速分发菜单，结合 UIActivityViewController 支持系统内完整生态分享
- [-] **P2-5** 英文本地化

---

## P3 — 商业化准备

- [x] **P3-1** 隐私政策页面：在首次启动引导页新增必读及必须勾选的交互逻辑，连接到外部文档
- [-] **P3-2** App Store 资产：需由设计或实际真机录屏完成，已保证当前 UI 及全流程可用
- [x] **P3-3** 内购方案设计：免费版（单次连拍 + 水印强制 / Pro 版全场景 + 阵发连拍 + 免水印），已接入 `PaywallView` 主动阻断弹出逻辑

---

## P4 — 稳定性与体验加固（按 ROI 由高到低排序）

- [ ] **P4-1 后台自动暂停** `30min` `Bug修复级`
  - 监听 `UIApplication.willResignActiveNotification` → `manager.stop()` + `synthesizer.stopSpeaking()`
  - 监听 `UIApplication.didBecomeActiveNotification` → `manager.start()`
  - 当前仅依赖 `onDisappear`，SwiftUI 切后台时不一定触发，用户后台持续耗电
- [ ] **P4-2 性能降级策略** `1h` `稳定性`
  - `ProcessInfo.processInfo.thermalState` >= `.serious` 或 `UIDevice.current.batteryLevel` < 0.1 时启用降级
  - 在 `captureOutput` 中引入帧计数器做 frame skip（隔帧丢弃），而非修改 Session 帧率（避免预览层也降帧）
  - Vision 推理频率从 30fps → 15fps，场景分类间隔从 2s → 4s
- [ ] **P4-3 Review Prompt 打分拦截** `30min` `商业化`
  - 保存照片计数 >= 3 且最近一次匹配度 > 85% 时调用 `SKStoreReviewController.requestReview()`
  - `@AppStorage("reviewRequestCount")` 控制每月最多请求 2 次
- [x] **P4-4 自动生成带特定水印图处理**（已随 P2-4 和 P3-3 完成基本业务闭环）
- [ ] **P4-5 关节坐标 EMA 平滑** `1h` `体验优化`
  - 对 `VisionService.handlePose` 输出的 13 个关节坐标做指数移动平均：`smoothed = old * 0.6 + new * 0.4`
  - 替代原计划的 Kalman Filter，实现更简单且覆盖 90% 场景
  - 主要收益在暗光环境下抑制骨架抖动
- [ ] **P4-6 剪影左右标注** `30min` `体验优化`
  - 替代原镜像模式（Mirror Mode）：在剪影上直接标注「左手」「右手」文字
  - 成本远低于完整镜像翻转，解决前置摄像头下用户分不清左右的痛点

---

## P5 — 出片质感与差异化功能

> 聚焦"一键出大片"的核心体验，已移除性能风险高或设备兼容性差的功能。

- [ ] **P5-1 仪式感物理反馈与柔和补光** `1h` `快速收益`
  - **快门音**：`AVAudioPlayer` 播放复古机械快门音效（需准备 .wav 资源文件）
  - **精准震动**：匹配 > 85% 瞬间用 `UIImpactFeedbackGenerator(style: .rigid)` 给确认感（复用已有 `hapticCooldown`）
  - **柔和屏幕补光**：将已有 `showShutterFlash` 从纯白改为暖白色 `Color(red:1.0, green:0.95, blue:0.88)` + 持续 0.3s + 临时 `UIScreen.main.brightness = 1.0`
- [ ] **P5-2 智能裁切双底片 + 画幅适配** `2h` `差异化`
  - **Auto-Crop**：利用 Vision bbox 一次快门保存两张底片（全身原图 + 胸腰特写版），用 `CGImage.cropping(to:)` 实现
  - **社交画幅预设**：提供 16:9 / 4:3 / 1:1 / 2.35:1 画幅遮罩选择（合并原 P2-4.1 社交安全区需求）
- [ ] **P5-3 留白智能提醒** `1h` `体验优化`
  - 基于已有 `bodyBoundingBox` 计算人像在画面中的水平偏移量
  - 当 bbox 中心偏离画面中心 < 5% 时，UI 浮现提示"尝试向左右平移增加留白氛围感"
  - 零额外性能开销（复用已有数据）
- [ ] **P5-4 拍后调色预设 (CIFilter)** `3h` `差异化`
  - 仅在 `PhotoPreviewView` 对已拍照片应用 4 套 CIFilter 预设：
    1. `胶片感 Film`：`CIColorCurves` 青暗部 + 暖高光（复刻柯达调性）
    2. `高级黑白 B&W`：`CIPhotoEffectNoir` + `CISharpenLuminance` 大反差强锐度
    3. `日系清透 Light`：`CIExposureAdjust(+0.3)` + `CIVibrance(-0.2)` 低对比过曝
    4. `城市霓虹 Neon`：`CIColorMatrix` Teal & Orange 青橙赛博朋克
  - 实时预览 LUT（V2）需自定义 Metal 渲染层替换 AVCaptureVideoPreviewLayer，暂不纳入
- [ ] **P5-5 人脸 EV 曝光补偿** `2h` `进阶`
  - 利用 Vision 人脸检测锁定坐标后，通过 `AVCaptureDevice.setExposureTargetBias(+0.3~0.7)` 提供人脸提亮
  - 人脸检测必须节流至每 2s 一次（与场景分类同频），避免与 30fps 姿态检测叠加
  - `setExposureTargetBias` 设置一次即持续生效，无需高频更新
  - 不依赖深度 API，兼容所有 A12+ 机型
- [ ] **P5-6 黄金螺旋线构图** `1h` `可选`
  - 匹配卧姿/侧向姿势时可选替代三分法网格
  - 仅绘制 UI 装饰线，无额外计算

---

## 已移除项（审查后决定不做）

| 原编号 | 功能 | 移除原因 |
|--------|------|----------|
| 原 P5-1 | 深度 API 虚化提示 | `AVCaptureDepthDataOutput` 需双摄设备 + 改 Session preset，GPU 与 Vision 争抢，A12/A13 帧率降至 15fps 以下 |
| 原 P5-2 | 消失线探测 | 需额外 Vision 请求或 Hough 变换，与 30fps 姿态检测并行不可接受 |
| 原 P5-4 | 字幕情绪渲染 | Gimmicky，无实际用户价值 |
| 原 P4-3 | 完整镜像模式 | 替换为 P4-6 剪影左右标注，成本更低效果更好 |
| 原 P2-4.1 | 社交安全区（独立） | 合并到 P5-2 智能裁切中统一实现 |

---

## 执行记录

| 时间 | 任务 | 结果 |
|------|------|------|
| 2026-04-10 | 规划创建 | ✅ |
| 2026-04-10 | P0-1 相册权限文案 | ✅ |
| 2026-04-10 | P0-2 权限恢复路径 | ✅ |
| 2026-04-10 | P0-4 Onboarding 三步引导 | ✅ |
| 2026-04-10 | P1-1 照片预览弹窗 | ✅ |
| 2026-04-10 | P1-2 倒计时自拍 | ✅ |
| 2026-04-10 | P1-3 暗光环境提示 | ✅ |
| 2026-04-10 | P1-4 姿势亲近度自动推荐 | ✅ |
| 2026-04-10 | P2-1 阵发连拍支持与选片界面重构 | ✅ |
| 2026-04-10 | P2-2 Session 历史缩略图及相册浮层 | ✅ |
| 2026-04-10 | P2-3 扩充四大场景库及关键词分类 | ✅ |
| 2026-04-10 | P2-4 一键社交分享及品牌水印生成 | ✅ |
| 2026-04-10 | P3-1 隐私协议界面拦截验证接入 | ✅ |
| 2026-04-10 | P3-3 内购设计：权限阻断、全屏 Paywall 推广页及无水印特权 | ✅ |
| 2026-04-10 | P4/P5 路线图审查重构 | ✅ 移除 5 项不合理需求，重排优先级 |
