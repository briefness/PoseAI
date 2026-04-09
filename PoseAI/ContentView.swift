import SwiftUI
import AVFoundation
import AVFAudio

struct ContentView: View {

    // MARK: - 摄像头 & 视觉
    @StateObject private var manager = CameraManager()

    // MARK: - 场景与方案状态
    @State private var scene: SceneType = .unknown
    @State private var currentPlanIndex: Int = 0
    @State private var isSceneReady: Bool = false
    @State private var scanPulse: Bool = false

    // MARK: - 姿势匹配状态
    @State private var points: [String: CGPoint] = [:]
    @State private var isHalfBody: Bool = false
    @State private var score: Double = 0

    // MARK: - 拍摄状态
    @State private var stableStartTime: Date? = nil
    @State private var showShutterFlash: Bool = false
    @State private var hapticCooldown: Bool = false
    @State private var breathingPulse: Bool = false

    // MARK: - UI 状态
    @State private var showGuide: Bool = false
    @State private var showCompositionTip: Bool = false
    @State private var compositionTipTask: DispatchWorkItem? = nil
    @State private var scanTimeoutTask: DispatchWorkItem? = nil  // 识别超时降级

    // MARK: - 语音
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - 常量
    private let successThreshold: Double = 85

    // MARK: - 当前方案（计算属性，只读）
    private var currentPlan: ShootingPlan? {
        let plans = scene.plans
        guard !plans.isEmpty, currentPlanIndex < plans.count else { return nil }
        return plans[currentPlanIndex]
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            // 层1：摄像头预览
            cameraLayer

            // 层2：构图辅助线（极淡，场景就绪后显示）
            if isSceneReady {
                CompositionGuideLines()
            }

            // 层3：场景扫描引导 / 剪影引导（互斥）
            if !isSceneReady {
                sceneScanningOverlay
            } else if let plan = currentPlan {
                SilhouetteGuideOverlay(
                    isAligned: Binding(
                        get: { score > successThreshold },
                        set: { _ in }
                    ),
                    plan: plan
                )
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.4), value: currentPlanIndex)
            }

            // 层4：AR 地面脚印（全身方案时显示）
            if isSceneReady, currentPlan?.frameRatio == .fullBody {
                arFootprintsOverlay
            }

            // 层5：顶部信息栏
            VStack {
                topBar
                    .padding(.top, 60)
                    .padding(.horizontal, 20)
                Spacer()
            }

            // 层6：构图原因浮层提示（方案切换时短暂显示）
            if showCompositionTip, let plan = currentPlan {
                compositionTipOverlay(plan: plan)
            }

            // 层7：底部控制区
            VStack {
                Spacer()
                bottomControls
                    .padding(.bottom, 40)
            }

            // 层8：俯拍警告
            if manager.devicePitch < -0.35 {
                pitchWarningOverlay
            }

            // 层9：快门闪光
            if showShutterFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.85)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            bind()
            startScanTimeout()
        }
        .onDisappear { manager.stop() }
        .sheet(isPresented: $showGuide) {
            PoseGuideSheet(plan: currentPlan, scene: scene)
        }
    }

    // MARK: - 摄像头层
    private var cameraLayer: some View {
        Group {
            if manager.authorizationStatus == .authorized {
                CameraPreview(manager: manager).ignoresSafeArea()
            } else if manager.authorizationStatus == .denied {
                permissionDeniedView
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }

    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("需要摄像头权限")
                .font(.headline).foregroundColor(.white)
            Text("请在「设置 › 隐私 › 摄像头」中开启权限。")
                .font(.caption).foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - 顶部信息栏
    private var topBar: some View {
        HStack(alignment: .center) {
            // 左侧：场景 + 方案信息
            if isSceneReady, let plan = currentPlan {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: scene.icon)
                            .font(.system(size: 11))
                        Text(scene.displayName)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.7))

                    Text("\(plan.poseEmoji) \(plan.poseName)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .cornerRadius(14)
            }

            Spacer()

            // 右侧：帮助按钮 + 得分环
            HStack(spacing: 12) {
                if isSceneReady {
                    scoreRing
                }
                Button { showGuide = true } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }

    // MARK: - 得分环（极简，右上角）
    private var scoreRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 4)
            Circle()
                .trim(from: 0, to: score / 100)
                .stroke(scoreColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: score)
            Text("\(Int(score))")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: 46, height: 46)
        .scaleEffect(score > successThreshold ? 1.12 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: score > successThreshold)
    }

    // MARK: - 构图原因浮层
    private func compositionTipOverlay(plan: ShootingPlan) -> some View {
        VStack {
            Spacer().frame(height: 140)
            HStack(spacing: 10) {
                Image(systemName: plan.composition.icon)
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("📐 \(plan.composition.displayName)构图")
                        .font(.system(size: 13, weight: .bold))
                    Text(plan.composition.reason)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.65))
            .cornerRadius(14)
            .padding(.horizontal, 30)
            .transition(.move(edge: .top).combined(with: .opacity))

            Spacer()
        }
    }

    // MARK: - AR 地面脚印
    private var arFootprintsOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 40) {
                Image(systemName: "shoe.fill")
                    .resizable().scaledToFit()
                    .frame(width: 28)
                    .rotationEffect(.degrees(-10))
                Image(systemName: "shoe.fill")
                    .resizable().scaledToFit()
                    .frame(width: 28)
                    .rotationEffect(.degrees(10))
            }
            .foregroundColor(.white.opacity(0.3))
            .padding(.bottom, 230)
        }
    }

    // MARK: - 场景扫描引导
    private var sceneScanningOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                        .frame(width: 180, height: 240)
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(scanPulse ? 0.85 : 0.15), lineWidth: 2.5)
                        .frame(width: 180, height: 240)
                        .scaleEffect(scanPulse ? 1.07 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                            value: scanPulse
                        )
                    VStack(spacing: 10) {
                        Image(systemName: "viewfinder.trianglepath")
                            .font(.system(size: 36, weight: .thin))
                            .foregroundColor(.white.opacity(0.7))
                        Text("正在分析背景…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                    }
                }

                Text("请让镜头看到拍摄背景\n（咖啡馆 / 海边 / 森林）")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 200)
        }
        .onAppear { scanPulse = true }
    }

    // MARK: - 底部控制区
    private var bottomControls: some View {
        VStack(spacing: 16) {
            // 方案卡片选择器（场景就绪后显示）
            if isSceneReady {
                PlanPickerView(
                    plans: scene.plans,
                    selectedIndex: $currentPlanIndex
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 快门行：切换镜头 + 快门按钮 + 比例提示
            HStack(spacing: 0) {
                // 前后置切换
                Button {
                    manager.isFront.toggle()
                } label: {
                    Image(systemName: "camera.rotate.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                .frame(maxWidth: .infinity)

                // 快门按钮
                shutterButton
                    .onTapGesture { triggerManualPhoto() }

                // 距离提示
                if let plan = currentPlan {
                    VStack(spacing: 4) {
                        Image(systemName: plan.frameRatio.icon)
                            .font(.system(size: 14))
                        Text(plan.frameRatio.displayName)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                } else {
                    Spacer().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 30)
        }
    }

    // MARK: - 快门按钮
    private var shutterButton: some View {
        let isReady = score > successThreshold
        return ZStack {
            Circle()
                .fill(Color.white.opacity(isReady ? 0.95 : 0.3))
                .frame(width: 72, height: 72)
            Circle()
                .strokeBorder(Color.white, lineWidth: 3.5)
                .frame(width: 82, height: 82)
                .scaleEffect(isReady && breathingPulse ? 1.18 : 1.0)
                .opacity(isReady && breathingPulse ? 0.0 : 1.0)
                .onChange(of: isReady) { ready in
                    if ready {
                        withAnimation(.easeOut(duration: 1.0).repeatForever(autoreverses: false)) {
                            breathingPulse = true
                        }
                    } else {
                        withAnimation { breathingPulse = false }
                    }
                }
            if isReady {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.black)
            }
        }
        .scaleEffect(isReady ? 1.1 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: isReady)
    }

    // MARK: - 俯拍警告
    private var pitchWarningOverlay: some View {
        VStack {
            Spacer()
            Text("⚠️ 请平行或低角度拍摄，显腿更长")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.red.opacity(0.85))
                .cornerRadius(8)
                .shadow(radius: 5)
                .padding(.bottom, 180)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut, value: manager.devicePitch < -0.35)
    }

    // MARK: - 分数颜色
    private var scoreColor: Color {
        if score > 80 { return .green }
        if score > 50 { return .yellow }
        return .red
    }

    // MARK: - 绑定回调
    private func bind() {
        manager.visionService.onUpdate = { [self] pts, half in
            self.points = pts
            self.isHalfBody = half

            guard let plan = self.currentPlan else { return }
            let newRaw = PoseMatcher.calculateSimilarity(
                current: pts,
                preset: plan.posePoints,
                isHalfBody: half
            )
            let smoothed = (self.score * 0.7) + (newRaw * 0.3)
            withAnimation(.linear(duration: 0.1)) { self.score = smoothed }

            // 自动快门：达标保持 0.8 秒触发
            if smoothed > successThreshold {
                if self.stableStartTime == nil {
                    self.stableStartTime = Date()
                    if !self.hapticCooldown {
                        self.hapticCooldown = true
                        speak("对齐啦，保持不动！")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            self.hapticCooldown = false
                        }
                    }
                } else if let start = self.stableStartTime,
                          Date().timeIntervalSince(start) > 0.8 {
                    self.stableStartTime = nil
                    triggerAutoPhoto()
                }
            } else {
                self.stableStartTime = nil
            }
        }

        manager.visionService.onSceneChange = { [self] newScene in
            guard newScene != .unknown else { return }
            // 识别成功，取消超时降级
            self.scanTimeoutTask?.cancel()
            self.scanTimeoutTask = nil

            let isNew = (self.scene != newScene)
            withAnimation(.easeInOut(duration: 0.5)) {
                self.scene = newScene
                self.isSceneReady = true
                if isNew { self.currentPlanIndex = 0 }
            }
            if isNew {
                self.score = 0
                self.stableStartTime = nil
                if let plan = self.scene.plans.first {
                    speak("识别到\(newScene.displayName)，推荐\(plan.poseName)，\(plan.composition.voiceHint)")
                    showTipBriefly()
                }
            }
        }

        manager.start()
    }

    // MARK: - 识别超时降级：8 秒内未识别出场景，进入「通用模式」
    private func startScanTimeout() {
        let task = DispatchWorkItem { [self] in
            guard !self.isSceneReady else { return }  // 已识别则忽略
            // 降级到咖啡馆（方案最丰富，通用性最强）
            withAnimation(.easeInOut(duration: 0.5)) {
                self.scene = .coffee_shop
                self.isSceneReady = true
                self.currentPlanIndex = 0
            }
            speak("未能识别背景，展示通用方案，您可以手动切换")
            showTipBriefly()
        }
        self.scanTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: task)
    }

    // MARK: - 显示构图提示（2.5 秒后自动消失）
    private func showTipBriefly() {
        compositionTipTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { showCompositionTip = true }
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.3)) { showCompositionTip = false }
        }
        compositionTipTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: task)
    }

    // MARK: - 拍照
    private func triggerAutoPhoto() {
        speak("拍好了！")
        manager.takePhoto()
        triggerFlash()
        score = 0
        stableStartTime = nil
    }

    private func triggerManualPhoto() {
        manager.takePhoto()
        triggerFlash()
    }

    private func triggerFlash() {
        withAnimation(.easeIn(duration: 0.08)) { showShutterFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.22)) { showShutterFlash = false }
        }
    }

    // MARK: - 语音
    private func speak(_ text: String) {
        guard !synthesizer.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }
}

// MARK: - 方案选择器（底部横向卡片）
struct PlanPickerView: View {
    let plans: [ShootingPlan]
    @Binding var selectedIndex: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(plans.enumerated()), id: \.element.id) { idx, plan in
                    PlanCard(plan: plan, isSelected: idx == selectedIndex)
                        .onTapGesture { selectedIndex = idx }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

struct PlanCard: View {
    let plan: ShootingPlan
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 顶行：emoji + 姿势名
            HStack(spacing: 6) {
                Text(plan.poseEmoji)
                    .font(.system(size: 18))
                Text(plan.poseName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }

            // 标签行：构图 + 比例
            HStack(spacing: 6) {
                TagBadge(icon: plan.composition.icon, text: plan.composition.displayName)
                TagBadge(icon: plan.frameRatio.icon, text: plan.frameRatio.displayName)
            }

            // 描述
            Text(plan.poseDescription)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 160)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isSelected ? Color.white.opacity(0.2) : Color.black.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                )
        )
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }
}

struct TagBadge: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.85))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.15))
        .cornerRadius(6)
    }
}

// MARK: - 构图辅助线（三分法，极淡）
struct CompositionGuideLines: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Canvas { ctx, size in
                var path = Path()
                // 垂直三分线
                [w/3, w*2/3].forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                }
                // 水平三分线
                [h/3, h*2/3].forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
                ctx.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 剪影引导叠加层
struct SilhouetteGuideOverlay: View {
    @Binding var isAligned: Bool
    let plan: ShootingPlan

    var body: some View {
        GeometryReader { geo in
            let screenH = geo.size.height
            let targetH = screenH * plan.frameRatio.heightRatio
            let targetW = targetH * 0.52   // 剪影宽高比约 1:1.9
            let hOffset = plan.composition.offset

            ZStack {
                PoseSilhouetteShape()
                    .fill(
                        isAligned ? Color.green.opacity(0.28) : Color.white.opacity(0.18),
                        style: FillStyle(eoFill: true)
                    )
                PoseSilhouetteShape()
                    .stroke(
                        isAligned ? Color.green : Color.white,
                        style: StrokeStyle(
                            lineWidth: isAligned ? 3.5 : 2.0,
                            lineCap: .round,
                            dash: isAligned ? [] : [10, 6]
                        )
                    )
            }
            .frame(width: targetW, height: targetH)
            .shadow(color: isAligned ? .green.opacity(0.7) : .black.opacity(0.35), radius: 8)
            .animation(.easeInOut(duration: 0.3), value: isAligned)
            // 居中 + 构图水平偏移
            .position(
                x: geo.size.width / 2 + hOffset,
                // 全身贴底部：垂直居中偏下；半身/特写在上方 2/5 处
                y: plan.frameRatio == .fullBody
                    ? screenH - targetH / 2 - 140
                    : screenH * 0.42
            )
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: plan.composition.offset)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: plan.frameRatio.heightRatio)

            // 距离提示文字（剪影下方）
            if !isAligned {
                Text(plan.frameRatio.distanceHint)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.65))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.black.opacity(0.4))
                    .cornerRadius(10)
                    .position(
                        x: geo.size.width / 2 + hOffset,
                        y: plan.frameRatio == .fullBody
                            ? screenH - 100
                            : screenH * 0.42 + targetH / 2 + 24
                    )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 剪影 Shape（通用人体轮廓）
struct PoseSilhouetteShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height

        let headSize = w * 0.24
        path.addEllipse(in: CGRect(x: w * 0.38, y: h * 0.02, width: headSize, height: headSize * 1.15))

        path.move(to: CGPoint(x: w * 0.45, y: h * 0.14 + headSize * 1.15))
        path.addQuadCurve(to: CGPoint(x: w * 0.18, y: h * 0.28), control: CGPoint(x: w * 0.28, y: h * 0.22))
        path.addQuadCurve(to: CGPoint(x: w * 0.12, y: h * 0.52), control: CGPoint(x: w * 0.08, y: h * 0.38))
        path.addCurve(to: CGPoint(x: w * 0.28, y: h * 0.43), control1: CGPoint(x: w * 0.18, y: h * 0.56), control2: CGPoint(x: w * 0.22, y: h * 0.48))
        path.addLine(to: CGPoint(x: w * 0.33, y: h * 0.50))
        path.addQuadCurve(to: CGPoint(x: w * 0.24, y: h * 0.93), control: CGPoint(x: w * 0.27, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.40, y: h * 0.93))
        path.addQuadCurve(to: CGPoint(x: w * 0.48, y: h * 0.58), control: CGPoint(x: w * 0.44, y: h * 0.74))
        path.addQuadCurve(to: CGPoint(x: w * 0.63, y: h * 0.93), control: CGPoint(x: w * 0.54, y: h * 0.74))
        path.addLine(to: CGPoint(x: w * 0.79, y: h * 0.93))
        path.addQuadCurve(to: CGPoint(x: w * 0.70, y: h * 0.52), control: CGPoint(x: w * 0.79, y: h * 0.73))
        path.addLine(to: CGPoint(x: w * 0.64, y: h * 0.48))
        path.addQuadCurve(to: CGPoint(x: w * 0.83, y: h * 0.43), control: CGPoint(x: w * 0.74, y: h * 0.52))
        path.addQuadCurve(to: CGPoint(x: w * 0.78, y: h * 0.24), control: CGPoint(x: w * 0.94, y: h * 0.33))
        path.addQuadCurve(to: CGPoint(x: w * 0.55, y: h * 0.14 + headSize * 1.15), control: CGPoint(x: w * 0.67, y: h * 0.23))
        path.closeSubpath()

        return path
    }
}

// MARK: - 方案引导面板
struct PoseGuideSheet: View {
    let plan: ShootingPlan?
    let scene: SceneType
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // 场景标识
                    HStack(spacing: 8) {
                        Image(systemName: scene.icon)
                        Text(scene.displayName)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)

                    if let plan = plan {
                        // 当前选中方案
                        VStack(spacing: 16) {
                            Text("\(plan.poseEmoji) \(plan.poseName)")
                                .font(.title2.bold())
                            Text(plan.poseDescription)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 8)
                        }

                        Divider()

                        // 构图说明
                        GuideInfoRow(
                            icon: plan.composition.icon,
                            title: "\(plan.composition.displayName)构图",
                            detail: plan.composition.reason
                        )

                        // 比例说明
                        GuideInfoRow(
                            icon: plan.frameRatio.icon,
                            title: "\(plan.frameRatio.displayName)拍摄",
                            detail: plan.frameRatio.distanceHint
                        )

                        Divider()
                    }

                    // 使用说明
                    VStack(alignment: .leading, spacing: 12) {
                        GuideRow(icon: "checkmark.circle.fill", color: .green,
                                 text: "绿色边框 + 分数变绿：姿势对齐！保持不动即可自动拍照")
                        GuideRow(icon: "figure.stand", color: .white.opacity(0.6),
                                 text: "白色虚线：还未对齐，请移动身体贴合剪影")
                        GuideRow(icon: "hand.tap", color: .blue,
                                 text: "点击底部卡片可切换推荐方案")
                        GuideRow(icon: "camera.rotate.fill", color: .orange,
                                 text: "左下角按钮可切换前后置摄像头")
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(14)
                    .padding(.horizontal, 16)

                    Spacer(minLength: 20)
                }
                .padding(.top, 32)
                .padding(.horizontal, 16)
            }
            .navigationTitle("拍摄指引")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct GuideInfoRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct GuideRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(.subheadline)
        }
    }
}

#Preview { ContentView() }
