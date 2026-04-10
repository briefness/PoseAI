# 工程经验沉淀 (Lessons Learned)

> 记录具有“复利价值”的填坑记录与架构权衡决策，作为开发团队的最佳实践参考。

---

## 1. AVFoundation 相机高频流处理最佳实践

**背景**：在使用 `VNDetectHumanBodyPoseRequest` 等高频（30fps）计算时，如果处理计算能力无法跟上帧率，会导致严重的延迟甚至内存溢出 (OOM)。

**错误做法 (Anti-pattern)**：
在 `AVCaptureVideoDataOutputSampleBufferDelegate` 的 `captureOutput` 回调中，获取到 `pixelBuffer` 后使用 `.async` 分派给子队列（如 `visionQueue.async`）去执行推理：
```swift
// ❌ 灾难性的错误做法
func captureOutput(...) {
    visionQueue.async {
        try? handler.perform([request])
    }
}
```

**深层原理与致命坑点**：
AVFoundation 提供了 `alwaysDiscardsLateVideoFrames = true`（迟到过载就丢帧），但它的生效条件是：**Delegate 线程必须被阻塞**。一旦使用了 `.async`，`captureOutput` 方法会在瞬间结束，使得丢帧保护完全失效。
此时 30fps 的 `CVPixelBuffer` 会源源不断积压在异步队列的闭包中，底层 Buffer Pool 会快速耗尽，继而造成长达数秒的视觉推理滞后（Pose overlay 等待积压的旧帧处理）。

**正确做法 (Best Practice)**：
强制在专用的帧接收队列（Serial Queue）内**同步**执行 Vision 请求，以此主动挂起线程让底层的硬丢帧逻辑真正生效：
```swift
// ✅ 生产级正确做法（配合 alwaysDiscardsLateVideoFrames = true）
func captureOutput(..., didOutput sampleBuffer: CMSampleBuffer, ...) {
    // 省略：提取 pixelBuffer...
    // 强制同步阻塞
    try? handler.perform([request])
}
```

---

## 2. AVCaptureDevice 对焦点/测光点的物理坐标系陷阱

**背景**：在使用 Vision 或 UI 点击获取到面部包围盒后，需要将 `CGRect` 或 `CGPoint` 传给 `AVCaptureDevice.exposurePointOfInterest` 来进行自动测光调整。

**陷阱与填坑**：
即使我们通过设置 `videoOutput.connection.videoOrientation = .portrait` 或在 `VNImageRequestHandler` 中声明了转正，**AVCaptureDevice 的硬件 API 设置（`exposurePointOfInterest` 和 `focusPointOfInterest`）只认 Sensor 的底层物理坐标系！**
对常见的 iPhone 来说，其实际 Sensor 始终为 Landscape（横屏模式）。
因此，将竖屏的左下角推算的横向 X 与纵向 Y，传给物理传感器时，必须做对应的转置倒换。

**校准坐标映射（竖屏 Portrait 下向底层的映射）**：
```swift
// Vision 返回的经过处理的归一化竖屏坐标 (rect.midX, rect.midY) 实际上：
let sensorX: CGFloat
let sensorY: CGFloat

if isFront {
    // 前置镜头物理上是 LandscapeRight 但带镜像
    sensorX = 1.0 - rect.midY
    sensorY = 1.0 - rect.midX
} else {
    // 后置镜头
    sensorX = rect.midY
    sensorY = rect.midX
}
device.exposurePointOfInterest = CGPoint(x: sensorX, y: sensorY)
```
使用上述数学法则，才能保证动态设定的对焦或防闪光曝光框精准匹配 UI 视觉中的人脸位置。
