import SwiftUI
import AVFoundation
import AVFAudio

// MARK: - 品牌设计常量
private enum Design {
    // 主题色（暖金 + 深黑）
    static let accent = Color(red: 1.0, green: 0.82, blue: 0.45)         // #FFD073 暖金
    static let accentGlow = Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.35)
    static let success = Color(red: 0.35, green: 0.95, blue: 0.60)       // #59F299 亮绿
    static let successGlow = Color(red: 0.35, green: 0.95, blue: 0.60).opacity(0.35)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.38)         // #FF6161 火红
    static let surface = Color.white.opacity(0.08)
    static let surfaceStrong = Color.white.opacity(0.15)
    static let border = Color.white.opacity(0.18)
    static let borderActive = Color.white.opacity(0.75)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let overlayBg = Color.black.opacity(0.55)
    static let blur: Material = .ultraThinMaterial
    static let cornerCard: CGFloat = 18
    static let cornerBadge: CGFloat = 8
}

struct ContentView: View {

    // MARK: - 摄像头 & 视觉
    @StateObject private var manager = CameraManager()

    // MARK: - 场景与方案状态
    @State private var scene: SceneType = .unknown
    @State private var currentPlanIndex: Int = 0
    @State private var isSceneReady: Bool = false
    @State private var scanPulse: Bool = false
    @State private var scanRotation: Double = 0

    // MARK: - 姿势匹配状态
    @State private var points: [String: CGPoint] = [:]
    @State private var isHalfBody: Bool = false
    @State private var score: Double = 0
    @State private var bodyBoundingBox: CGRect? = nil  // 归一化包围盒，nil = 未检测到人

    // MARK: - 拍摄状态
    @State private var stableStartTime: Date? = nil
    @State private var showShutterFlash: Bool = false
    @State private var hapticCooldown: Bool = false
    @State private var breathingScale: CGFloat = 1.0
    @State private var isCapturing: Bool = false

    // MARK: - UI 状态
    @State private var showGuide: Bool = false
    @State private var showCompositionTip: Bool = false
    @State private var compositionTipTask: DispatchWorkItem? = nil
    @State private var scanTimeoutTask: DispatchWorkItem? = nil
    @State private var planChangeAnimate: Bool = false

    // MARK: - 连拍与历史状态 (P2-1, P2-2)
    @State private var burstImages: [UIImage] = []
    @State private var expectedBurstCount: Int = 1
    @State private var isReviewingPhotos: Bool = false
    @State private var sessionSavedImages: [UIImage] = []
    @State private var showSessionGallery: Bool = false

    // MARK: - 内购状态 (P3-3)
    @AppStorage("isPro") var isPro = false
    @State private var showPaywall = false

    // MARK: - 倒计时自拍
    @State private var timerSeconds: Int = 0           // 0=关闭, 3/5/10
    @State private var countdown: Int = 0              // 当前倒计时数字
    @State private var timerTask: DispatchWorkItem? = nil
    @State private var isLowLight: Bool = false        // 暗光警告

    // MARK: - 姿势亲近度自动推荐
    @State private var autoRecommendLastCheck: Date = .distantPast   // 节流：0.5s 计算一次
    @State private var userOverrideUntil: Date = .distantPast        // 用户手动选择后 8s 内不自动切换


    // MARK: - 语音
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - 常量
    private let successThreshold: Double = 85

    // MARK: - 计算属性
    private var isPremiumScene: Bool {
        [.city_street, .park, .indoor_home, .neon_night].contains(scene)
    }
    
    private var requiresProUnlock: Bool {
        isPremiumScene && !isPro
    }

    private var currentPlan: ShootingPlan? {
        let plans = scene.plans
        guard !plans.isEmpty, currentPlanIndex < plans.count else { return nil }
        return plans[currentPlanIndex]
    }

    private var isReady: Bool { score > successThreshold }

    // MARK: - Body
    var body: some View {
        ZStack {
            cameraLayer

            if isSceneReady {
                CompositionGuideLines()
            }

            if !isSceneReady {
                sceneScanningOverlay
            } else if let plan = currentPlan {
                if requiresProUnlock {
                    paywallTeaser
                } else {
                    SilhouetteGuideOverlay(
                        isAligned: Binding(get: { isReady }, set: { _ in }),
                        plan: plan,
                        bodyBoundingBox: bodyBoundingBox
                    )
                    .transition(.opacity.animation(.easeInOut(duration: 0.5)))
                    .animation(.easeInOut(duration: 0.4), value: currentPlanIndex)
                }
            }

            if !requiresProUnlock {
                if isSceneReady, currentPlan?.frameRatio == .fullBody {
                    arFootprintsOverlay
                }
            }

            // 顶部信息栏
            VStack(spacing: 0) {
                topBar
                    .padding(.top, 58)
                    .padding(.horizontal, 18)
                Spacer()
            }

            // 构图提示浮层
            if !requiresProUnlock, showCompositionTip, let plan = currentPlan {
                compositionTipOverlay(plan: plan)
            }

            // 暗光提示 Banner（有人但光线不足时显示）
            if isLowLight && isSceneReady {
                lowLightBanner
            }

            // 底部控制区
            VStack(spacing: 0) {
                Spacer()
                bottomPanel
            }

            // 俯拍警告
            if manager.devicePitch < -0.35 {
                pitchWarningOverlay
            }

            // 快门闪光
            if showShutterFlash {
                Color.white
                    .ignoresSafeArea()
                    .opacity(0.9)
                    .transition(.opacity)
            }

            // 倒计时大数字
            if countdown > 0 {
                Text("\(countdown)")
                    .font(.system(size: 130, weight: .ultraLight, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.35), radius: 24)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
                    .id(countdown)
                    .animation(.spring(response: 0.35, dampingFraction: 0.6), value: countdown)
                    .allowsHitTesting(false)
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
        .fullScreenCover(isPresented: $isReviewingPhotos) {
            PhotoPreviewView(images: burstImages) { selectedImage in
                // 用户点「保存」
                UIImageWriteToSavedPhotosAlbum(selectedImage, nil, nil, nil)
                sessionSavedImages.append(selectedImage)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                isReviewingPhotos = false
            } onRetake: {
                // 用户点「重拍」
                isReviewingPhotos = false
            }
        }
        .sheet(isPresented: $showSessionGallery) {
            SessionGallerySheet(images: sessionSavedImages)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
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
        VStack(spacing: 28) {
            // 图标
            ZStack {
                Circle()
                    .fill(Design.danger.opacity(0.15))
                    .frame(width: 90, height: 90)
                Image(systemName: "camera.slash.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(Design.danger)
            }

            // 说明文字
            VStack(spacing: 8) {
                Text("需要摄像头权限")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                Text("PoseAI 需要访问摄像头\n才能实时检测姿势和场景")
                    .font(.system(size: 14))
                    .foregroundColor(Design.textSecondary)
                    .multilineTextAlignment(.center)
            }

            // 去设置按钮
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                        .font(.system(size: 15, weight: .medium))
                    Text("去设置中开启")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Design.accent, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }


    // MARK: - 顶部信息栏
    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            // 左侧：场景 + 方案信息
            if isSceneReady, let plan = currentPlan {
                HStack(spacing: 10) {
                    // 场景图标
                    ZStack {
                        Circle()
                            .fill(Design.surface)
                            .frame(width: 36, height: 36)
                        Image(systemName: scene.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Design.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(scene.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Design.textSecondary)
                        Text("\(plan.poseEmoji) \(plan.poseName)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Design.textPrimary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Design.cornerCard))
                .overlay(
                    RoundedRectangle(cornerRadius: Design.cornerCard)
                        .stroke(Design.border, lineWidth: 1)
                )
                .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            Spacer()

            // 右侧：分数环 + 帮助按钮
            HStack(spacing: 10) {
                if isSceneReady {
                    scoreRing
                }
                Button { showGuide = true } label: {
                    ZStack {
                        Circle()
                            .fill(Design.surface)
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle().stroke(Design.border, lineWidth: 1)
                            )
                        Image(systemName: "questionmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: isSceneReady)
    }

    // MARK: - 分数环
    private var scoreRing: some View {
        ZStack {
            // 外发光（对齐时）
            if isReady {
                Circle()
                    .stroke(Design.successGlow, lineWidth: 10)
                    .frame(width: 54, height: 54)
                    .blur(radius: 6)
            }

            // 底层轨道
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 3.5)
                .frame(width: 46, height: 46)

            // 进度弧
            Circle()
                .trim(from: 0, to: score / 100)
                .stroke(
                    AngularGradient(
                        colors: isReady ? [Design.success, Design.success.opacity(0.6)] : scoreArcColors,
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
                .frame(width: 46, height: 46)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.12), value: score)

            // 分数文字
            Text("\(Int(score))")
                .font(.system(size: 12, weight: .black, design: .rounded))
                .foregroundColor(.white)
        }
        .frame(width: 54, height: 54)
        .scaleEffect(isReady ? 1.08 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isReady)
    }

    private var scoreArcColors: [Color] {
        if score > 60 { return [Design.accent, Design.accent.opacity(0.5)] }
        return [Color.white.opacity(0.8), Color.white.opacity(0.3)]
    }

    // MARK: - 场景扫描引导
    private var sceneScanningOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 28) {
                ZStack {
                    // 最外圈脉冲
                    Circle()
                        .stroke(Design.accent.opacity(scanPulse ? 0.0 : 0.35), lineWidth: 1.5)
                        .frame(width: scanPulse ? 220 : 160)
                        .animation(
                            .easeOut(duration: 1.8).repeatForever(autoreverses: false),
                            value: scanPulse
                        )

                    // 第二圈
                    Circle()
                        .stroke(Design.accent.opacity(scanPulse ? 0.0 : 0.2), lineWidth: 1)
                        .frame(width: scanPulse ? 190 : 140)
                        .animation(
                            .easeOut(duration: 1.8).delay(0.3).repeatForever(autoreverses: false),
                            value: scanPulse
                        )

                    // 主框
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Design.accent.opacity(0.8), lineWidth: 2)
                        .frame(width: 140, height: 190)

                    // 四角修饰线
                    ScanCornerLines()
                        .frame(width: 140, height: 190)

                    // 内容
                    VStack(spacing: 10) {
                        ZStack {
                            // 旋转扫描弧
                            Circle()
                                .trim(from: 0, to: 0.25)
                                .stroke(
                                    AngularGradient(colors: [Design.accent, .clear], center: .center),
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                                )
                                .frame(width: 44, height: 44)
                                .rotationEffect(.degrees(scanRotation))
                                .onAppear {
                                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                                        scanRotation = 360
                                    }
                                }

                            Image(systemName: "viewfinder")
                                .font(.system(size: 22, weight: .ultraLight))
                                .foregroundColor(Design.accent.opacity(0.7))
                        }

                        Text("识别场景中…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }

                // 提示文字
                VStack(spacing: 6) {
                    Text("将镜头对准拍摄背景")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                    Text("咖啡馆 · 海边 · 森林")
                        .font(.system(size: 12))
                        .foregroundColor(Design.accent.opacity(0.7))
                        .tracking(2)
                }
            }
            .padding(.bottom, 200)
        }
        .onAppear { scanPulse = true }
    }

    // MARK: - AR 地面脚印
    private var arFootprintsOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 36) {
                Image(systemName: "shoe.fill")
                    .resizable().scaledToFit().frame(width: 24)
                    .rotationEffect(.degrees(-12))
                    .foregroundColor(Design.accent.opacity(0.25))
                Image(systemName: "shoe.fill")
                    .resizable().scaledToFit().frame(width: 24)
                    .rotationEffect(.degrees(12))
                    .foregroundColor(Design.accent.opacity(0.25))
            }
            .padding(.bottom, 220)
        }
    }

    // MARK: - 底部整体面板（磨砂玻璃）
    private var bottomPanel: some View {
        VStack(spacing: 0) {
            // 方案选择器
            if isSceneReady {
                planPickerSection
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 主控制行
            controlRow
                .padding(.top, 14)
                .padding(.bottom, 44)
                .padding(.horizontal, 28)
        }
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [Color.black.opacity(0.0), Color.black.opacity(0.55)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(Color.white.opacity(0.12)),
                    alignment: .top
                )
        )
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isSceneReady)
    }

    // MARK: - 方案选择器
    private var planPickerSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(scene.plans.enumerated()), id: \.element.id) { idx, plan in
                    PlanCard(plan: plan, isSelected: idx == currentPlanIndex)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                                currentPlanIndex = idx
                            }
                            // 用户主动选择 → 8s 内屏蔽自动推荐
                            userOverrideUntil = Date().addingTimeInterval(8)
                            score = 0
                            stableStartTime = nil
                        }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - 主控制行
    private var controlRow: some View {
        HStack(spacing: 0) {
            // 左：历史缩略图 (P2-2)
            Button { 
                if !sessionSavedImages.isEmpty { showSessionGallery = true }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Design.surface)
                        .frame(width: 50, height: 50)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Design.border, lineWidth: 1))
                    
                    if let lastImg = sessionSavedImages.last {
                        Image(uiImage: lastImg)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 50, height: 50)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            // 中：快门（倒计时/直接拍）
            shutterButton
                .onTapGesture { handleShutterTap() }

            // 右：翻转摄像头与倒计时
            HStack(spacing: 12) {
                // 切换摄像头
                Button { manager.isFront.toggle() } label: {
                    ZStack {
                        Circle()
                            .fill(Design.surface)
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Design.border, lineWidth: 1))
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white)
                    }
                }
                
                // 倒计时
                Button { cycleTimer() } label: {
                    ZStack {
                        Circle()
                            .fill(timerSeconds > 0 ? Design.accent.opacity(0.18) : Design.surface)
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(timerSeconds > 0 ? Design.accent.opacity(0.6) : Design.border, lineWidth: 1))
                        if timerSeconds == 0 {
                            Image(systemName: "timer")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(Design.textSecondary)
                        } else {
                            Text("\(timerSeconds)s")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Design.accent)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 内购拦截浮层
    private var paywallTeaser: some View {
        VStack(spacing: 16) {
            Image(systemName: "crown.fill")
                .font(.system(size: 44))
                .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.45))
            Text("「\(scene.displayName)」是高级场景")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text("升级 Pro 即可使用专属姿势与满级体验")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.8))
            Button {
                showPaywall = true
            } label: {
                Text("了解 Pro 特权")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Color(red: 1.0, green: 0.82, blue: 0.45), in: Capsule())
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .background(Color.black.opacity(0.65).blur(radius: 20))
        .background(Color.black.opacity(0.3))
        .cornerRadius(24)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    // MARK: - 快门按钮（精致版）
    private var shutterButton: some View {
        ZStack {
            // 最外圈呼吸动效（对齐时）
            if isReady {
                Circle()
                    .stroke(Design.successGlow, lineWidth: 22)
                    .frame(width: 82, height: 82)
                    .scaleEffect(breathingScale)
                    .opacity(2.0 - breathingScale)
                    .onAppear {
                        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                            breathingScale = 1.5
                        }
                    }
            }

            // 外圈轨道
            Circle()
                .stroke(
                    isReady ? Design.success.opacity(0.9) : Color.white.opacity(0.55),
                    lineWidth: 2.5
                )
                .frame(width: 82, height: 82)

            // 内圆主体
            Circle()
                .fill(
                    isReady
                        ? LinearGradient(colors: [Design.success, Color(red: 0.2, green: 0.85, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.white.opacity(0.92), Color.white.opacity(0.78)], startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 68, height: 68)
                .shadow(color: isReady ? Design.successGlow : Color.black.opacity(0.3), radius: isReady ? 12 : 5)

            // 图标
            if isReady {
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            } else {
                Circle()
                    .fill(Color.black.opacity(0.08))
                    .frame(width: 26, height: 26)
            }
        }
        .frame(width: 92, height: 92)
        .scaleEffect(isCapturing ? 0.92 : (isReady ? 1.05 : 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isReady)
    }

    // MARK: - 构图提示浮层
    private func compositionTipOverlay(plan: ShootingPlan) -> some View {
        VStack {
            Spacer().frame(height: 130)

            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Design.accent.opacity(0.2))
                        .frame(width: 34, height: 34)
                    Image(systemName: plan.composition.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Design.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(plan.composition.displayName) 构图")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    Text(plan.composition.reason)
                        .font(.system(size: 11))
                        .foregroundColor(Design.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Design.cornerCard))
            .overlay(
                RoundedRectangle(cornerRadius: Design.cornerCard)
                    .stroke(Design.accent.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .transition(.move(edge: .top).combined(with: .opacity))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)

            Spacer()
        }
    }

    // MARK: - 俯拍警告
    private var pitchWarningOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Design.danger)
                Text("请平行或低角度拍摄，显腿更长")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Design.danger.opacity(0.5), lineWidth: 1))
            .padding(.bottom, 170)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: manager.devicePitch < -0.35)
    }

    // 暗光提示 Banner
    private var lowLightBanner: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.slash.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.yellow)
                Text("光线不足，移到明亮处效果更好")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.yellow.opacity(0.4), lineWidth: 1))
            .padding(.top, 110)
            .transition(.move(edge: .top).combined(with: .opacity))
            Spacer()
        }
    }

    // MARK: - 绑定回调
    private func bind() {
        manager.visionService.onUpdate = { pts, half, bbox in
            self.points = pts
            self.isHalfBody = half
            // 平滑更新包围盒（只在检测到时更新，避免人走出画面后剪影乱跳）
            if let bbox = bbox { self.bodyBoundingBox = bbox }

            guard let plan = self.currentPlan else { return }
            let newRaw = PoseMatcher.calculateSimilarity(
                current: pts,
                preset: plan.posePoints,
                isHalfBody: half
            )
            let smoothed = (self.score * 0.7) + (newRaw * 0.3)
            withAnimation(.linear(duration: 0.1)) { self.score = smoothed }

            if smoothed > self.successThreshold {
                if self.stableStartTime == nil {
                    self.stableStartTime = Date()
                    if !self.hapticCooldown {
                        self.hapticCooldown = true
                        self.speak("对齐啦，保持不动！")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            self.hapticCooldown = false
                        }
                    }
                } else if let start = self.stableStartTime,
                          Date().timeIntervalSince(start) > 0.8 {
                    self.stableStartTime = nil
                    self.triggerAutoPhoto()
                }
            } else {
                self.stableStartTime = nil
            }

            // MARK: P1-4 姿势亲近度自动推荐
            // 节流：每 0.5s 房计算一次（避免 30fps 过度 CPU 占用）
            let now = Date()
            guard now.timeIntervalSince(self.autoRecommendLastCheck) > 0.5 else { return }
            self.autoRecommendLastCheck = now

            // 用户手动选择后 8s 内不自动切换
            guard now > self.userOverrideUntil else { return }

            // 对当前场景的所有方案打分
            let plans = self.scene.plans
            guard plans.count > 1, pts.count >= 4 else { return }  // 点太少时不推荐

            let scores = plans.enumerated().map { idx, p in
                (idx, PoseMatcher.calculateSimilarity(current: pts, preset: p.posePoints, isHalfBody: half))
            }
            guard let best = scores.max(by: { $0.1 < $1.1 }) else { return }

            // 最高分必须比当前方案高 8 分，且最高分 > 15，才切换（防止无意义抄动）
            let currentScore = scores[self.currentPlanIndex].1
            if best.0 != self.currentPlanIndex, best.1 > 15, best.1 - currentScore > 8 {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    self.currentPlanIndex = best.0
                }
                self.score = 0
                self.stableStartTime = nil
            }
        }

        manager.visionService.onSceneChange = { newScene in
            guard newScene != .unknown else { return }
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
                    self.speak("识别到\(newScene.displayName)，推荐\(plan.poseName)，\(plan.composition.voiceHint)")
                    self.showTipBriefly()
                }
            }
        }

        manager.onPhotoCapture = { [self] image in
            self.burstImages.append(image)
            if self.burstImages.count >= self.expectedBurstCount {
                self.isReviewingPhotos = true
            }
        }

        manager.visionService.onLowLight = { [self] isLow in
            withAnimation(.easeInOut(duration: 0.4)) { self.isLowLight = isLow }
        }

        manager.start()
    }

    private func startScanTimeout() {
        let task = DispatchWorkItem {
            guard !self.isSceneReady else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                self.scene = .coffee_shop
                self.isSceneReady = true
                self.currentPlanIndex = 0
            }
            self.speak("未能识别背景，展示通用方案，您可以手动切换")
            self.showTipBriefly()
        }
        self.scanTimeoutTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0, execute: task)
    }

    private func showTipBriefly() {
        compositionTipTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showCompositionTip = true }
        let task = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.4)) { self.showCompositionTip = false }
        }
        compositionTipTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: task)
    }

    private func triggerAutoPhoto() {
        let finalCount = isPro ? 3 : 1
        speak(isPro ? "拍好了！连拍三张" : "拍好了")
        takeBurst(count: finalCount)
        score = 0
        stableStartTime = nil
    }

    private func triggerManualPhoto() {
        takeBurst(count: 1)
    }

    private func takeBurst(count: Int) {
        guard !isCapturing else { return }
        isCapturing = true
        expectedBurstCount = count
        burstImages.removeAll()
        var taken = 0
        
        func snap() {
            guard taken < count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.isCapturing = false }
                return
            }
            manager.takePhoto()
            triggerFlash()
            taken += 1
            if taken < count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    snap()
                }
            }
        }
        snap()
    }

    // MARK: - 倒计时循环切换
    private func cycleTimer() {
        let options = [0, 3, 5, 10]
        let cur = options.firstIndex(of: timerSeconds) ?? 0
        timerSeconds = options[(cur + 1) % options.count]
        cancelTimer()
    }

    // MARK: - 快门点击：有倒计时则启动倒计时，否则直接拍
    private func handleShutterTap() {
        if timerSeconds == 0 {
            triggerManualPhoto()
        } else {
            if countdown > 0 {
                cancelTimer() // 再次点击取消倒计时
            } else {
                startCountdown()
            }
        }
    }

    private func startCountdown() {
        countdown = timerSeconds
        let task = DispatchWorkItem {}
        timerTask = task
        func tick() {
            guard countdown > 0 else {
                triggerManualPhoto()
                return
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard self.countdown > 0 else { return }
                withAnimation { self.countdown -= 1 }
                tick()
            }
        }
        tick()
    }

    private func cancelTimer() {
        countdown = 0
        timerTask?.cancel()
        timerTask = nil
    }

    private func triggerFlash() {
        withAnimation(.easeIn(duration: 0.07)) { showShutterFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
            withAnimation(.easeOut(duration: 0.2)) { self.showShutterFlash = false }
        }
    }

    private func speak(_ text: String) {
        guard !synthesizer.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.52
        synthesizer.speak(utterance)
    }
}

// MARK: - 工具扩展
private extension CGFloat {
    /// 将值限制在闭合区间内
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - 扫描框四角修饰线
struct ScanCornerLines: View {

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let len: CGFloat = 18
            let thick: CGFloat = 2.5
            let color = Design.accent

            Canvas { ctx, _ in
                let corners: [(CGPoint, CGPoint, CGPoint)] = [
                    (CGPoint(x: 0, y: len), CGPoint(x: 0, y: 0), CGPoint(x: len, y: 0)),
                    (CGPoint(x: w - len, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: len)),
                    (CGPoint(x: 0, y: h - len), CGPoint(x: 0, y: h), CGPoint(x: len, y: h)),
                    (CGPoint(x: w - len, y: h), CGPoint(x: w, y: h), CGPoint(x: w, y: h - len))
                ]
                for (a, b, c) in corners {
                    var p = Path()
                    p.move(to: a); p.addLine(to: b); p.addLine(to: c)
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: thick, lineCap: .round))
                }
            }
        }
    }
}

// MARK: - 方案选择卡片（紧凑 pill 样式）
// 设计原则：相机主界面，背景才是主角，UI 是配角
// 未选中 → 只显示 emoji + 姿势名（约 42pt 高）
// 选中   → 展开一行构图+比例标签（约 60pt 高）
// 不显示描述文字（在帮助面板 PoseGuideSheet 中可查看完整信息）
struct PlanCard: View {
    let plan: ShootingPlan
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 主行：emoji + 姿势名（始终显示）
            HStack(spacing: 7) {
                Text(plan.poseEmoji)
                    .font(.system(size: 17))
                Text(plan.poseName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            // 标签行：仅选中时显示
            if isSelected {
                HStack(spacing: 5) {
                    TagBadge(icon: plan.composition.icon, text: plan.composition.displayName, active: true)
                    TagBadge(icon: plan.frameRatio.icon, text: plan.frameRatio.displayName, active: true)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    isSelected
                        ? LinearGradient(colors: [Design.accent.opacity(0.22), Design.accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.black.opacity(0.45), Color.black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isSelected ? Design.accent.opacity(0.75) : Design.border,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .shadow(color: isSelected ? Design.accentGlow : .clear, radius: 8)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isSelected)
    }
}


struct TagBadge: View {
    let icon: String
    let text: String
    var active: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(active ? Design.accent : .white.opacity(0.7))
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(
            Capsule()
                .fill(active ? Design.accent.opacity(0.18) : Color.white.opacity(0.1))
        )
        .overlay(
            Capsule()
                .stroke(active ? Design.accent.opacity(0.4) : Color.clear, lineWidth: 1)
        )
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
                [w/3, w*2/3].forEach { x in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                }
                [h/3, h*2/3].forEach { y in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
                ctx.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 1)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 剪影引导叠加层
// 设计思路：
// 1. 评分引擎（PoseMatcher）使用关节夹角，与体型无关，天然免疫高矮胖瘦
// 2. 剪影作为「视觉引导」，通过 bodyBoundingBox 跟随用户实际身体大小动态缩放
//    - 有检测到人体 → 剪影高度 ≈ 人体在画面中的实际高度（归一化），水平跟随中心
//    - 无检测 / 初始化 → 退回到方案设定的默认尺寸（frameRatio.heightRatio）
// 3. 宽高比固定 0.52（人体自然比例），保持剪影不变形
// 4. 使用 withAnimation(.spring) 平滑过渡，防止抖动
struct SilhouetteGuideOverlay: View {
    @Binding var isAligned: Bool
    let plan: ShootingPlan
    var bodyBoundingBox: CGRect?   // Vision 检测到的归一化人体包围盒 (x,y,w,h)

    var body: some View {
        GeometryReader { geo in
            let screenW = geo.size.width
            let screenH = geo.size.height

            // MARK: 计算剪影的目标尺寸和位置
            // 优先使用实时检测到的包围盒，否则用方案默认比例
            let (silW, silH, centerX, centerY) = resolveLayout(
                screenW: screenW, screenH: screenH, bbox: bodyBoundingBox, plan: plan
            )
            let hOffset = plan.composition.offset

            ZStack {
                PoseSilhouetteShape()
                    .fill(
                        isAligned ? Design.success.opacity(0.22) : Color.white.opacity(0.12),
                        style: FillStyle(eoFill: true)
                    )

                PoseSilhouetteShape()
                    .stroke(
                        isAligned
                            ? LinearGradient(
                                colors: [Design.success, Design.success.opacity(0.6)],
                                startPoint: .top, endPoint: .bottom)
                            : LinearGradient(
                                colors: [.white.opacity(0.7), .white.opacity(0.3)],
                                startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(
                            lineWidth: isAligned ? 3.0 : 1.8,
                            lineCap: .round,
                            dash: isAligned ? [] : [10, 7]
                        )
                    )
            }
            .frame(width: silW, height: silH)
            .shadow(color: isAligned ? Design.successGlow : .clear, radius: 14)
            .animation(.easeInOut(duration: 0.3), value: isAligned)
            // 位置：X 跟随构图规则偏移；Y 跟随实际人体中心（或默认）
            .position(x: centerX + hOffset, y: centerY)
            .animation(.spring(response: 0.6, dampingFraction: 0.82), value: silH)
            .animation(.spring(response: 0.6, dampingFraction: 0.82), value: centerY)
            .animation(.spring(response: 0.55, dampingFraction: 0.8), value: hOffset)

            // 距离提示（未对齐、无人体检测时显示）
            if !isAligned {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 10))
                        .foregroundColor(Design.accent)
                    Text(plan.frameRatio.distanceHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Design.accent.opacity(0.3), lineWidth: 1))
                .position(
                    x: centerX + hOffset,
                    y: centerY + silH / 2 + 28
                )
                .animation(.spring(response: 0.6, dampingFraction: 0.82), value: centerY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - 布局计算
    // 返回 (剪影宽, 剪影高, 中心X, 中心Y)，全部单位 pt
    private func resolveLayout(
        screenW: CGFloat, screenH: CGFloat,
        bbox: CGRect?, plan: ShootingPlan
    ) -> (CGFloat, CGFloat, CGFloat, CGFloat) {

        // 剪影宽高比固定：人体自然比例约 0.52:1
        let aspectRatio: CGFloat = 0.52

        if let bbox = bbox, bbox.height > 0.05 {
            // ── 有实时人体检测 ──────────────────────────────────────────
            // Vision 的包围盒来自关节点（不含头部上方留白）
            // 向上补偿 15% 使剪影头部不被截断
            let paddingTop: CGFloat = 0.10
            let paddingH: CGFloat  = 0.05   // 底部少量留白
            let paddingSide: CGFloat = 0.08  // 左右各留白

            let bboxH = min(bbox.height + paddingTop + paddingH, 0.95)
            // 检测高度映射到屏幕像素
            var rawH = bboxH * screenH
            // 将剪影高度限制在「方案允许的范围」内，避免离太远/太近时剪影失控
            let minH = screenH * plan.frameRatio.heightRatio * 0.5
            let maxH = screenH * plan.frameRatio.heightRatio * 1.3
            rawH = max(minH, min(maxH, rawH))

            let silH = rawH
            let silW = silH * aspectRatio

            // 水平中心跟随人体（bbox.midX 是归一化坐标）
            // 但若偏差过大（构图规则要求站偏）则混合
            let detectedCenterX = (bbox.midX + paddingSide / 2) * screenW
            // 简单取检测中心（构图偏移由 hOffset 分开控制）
            let centerX = detectedCenterX.clamped(to: silW/2...(screenW - silW/2))

            // 垂直中心：人体检测到的 Y 中心，向上补偿头部空间
            let detectedMidY = (bbox.minY - paddingTop / 2 + bboxH / 2) * screenH
            let centerY = detectedMidY.clamped(to: silH/2...(screenH - silH/2 - 40))

            return (silW, silH, centerX, centerY)

        } else {
            // ── 无检测/初始化：使用方案默认布局 ────────────────────────
            let defaultH = screenH * plan.frameRatio.heightRatio
            let defaultW = defaultH * aspectRatio
            let defaultX = screenW / 2
            let defaultY: CGFloat = plan.frameRatio == .fullBody
                ? screenH - defaultH / 2 - 140
                : screenH * 0.42
            return (defaultW, defaultH, defaultX, defaultY)
        }
    }
}

// MARK: - 剪影 Shape
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
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {

                        // 场景标识卡
                        HStack(spacing: 10) {
                            Image(systemName: scene.icon)
                                .font(.system(size: 16))
                                .foregroundColor(Design.accent)
                            Text(scene.displayName)
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(14)

                        if let plan = plan {
                            // 当前方案卡
                            VStack(spacing: 12) {
                                Text("\(plan.poseEmoji) \(plan.poseName)")
                                    .font(.system(size: 22, weight: .bold))
                                Text(plan.poseDescription)
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(14)

                            // 构图 + 比例说明
                            VStack(spacing: 0) {
                                GuideInfoRow(
                                    icon: plan.composition.icon,
                                    title: "\(plan.composition.displayName)构图",
                                    detail: plan.composition.reason
                                )
                                Divider().padding(.horizontal, 16)
                                GuideInfoRow(
                                    icon: plan.frameRatio.icon,
                                    title: "\(plan.frameRatio.displayName)拍摄",
                                    detail: plan.frameRatio.distanceHint
                                )
                            }
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(14)
                        }

                        // 使用说明卡
                        VStack(alignment: .leading, spacing: 14) {
                            Text("使用说明")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.bottom, 2)
                            GuideRow(icon: "checkmark.circle.fill", color: .green,
                                     text: "绿色边框 + 分数变绿：姿势对齐！保持不动即自动拍照")
                            GuideRow(icon: "figure.stand", color: .secondary,
                                     text: "白色虚线：未对齐，请移动身体贴合剪影")
                            GuideRow(icon: "hand.tap", color: .blue,
                                     text: "点击底部卡片可切换推荐拍摄方案")
                            GuideRow(icon: "arrow.triangle.2.circlepath.camera", color: .orange,
                                     text: "左下角图标可切换前后置摄像头")
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(14)

                        Spacer(minLength: 20)
                    }
                    .padding(16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("拍摄指引")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
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
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

struct GuideRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 16))
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - 可识别图片包装（用于 fullScreenCover item binding）
struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

// MARK: - 照片预览页（拍照后展示，用户确认保存）
struct PhotoPreviewView: View {
    let images: [UIImage]
    let onSave: (UIImage) -> Void
    let onRetake: () -> Void

    @AppStorage("isPro") var isPro = false
    @State private var appeared = false
    @State private var selectedIndex = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 全屏照片
            if !images.isEmpty {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
                .scaleEffect(appeared ? 1.0 : 1.05)
                .opacity(appeared ? 1.0 : 0)
                .animation(.easeOut(duration: 0.3), value: appeared)
            }

            // 顶部渐变遮罩
            VStack {
                LinearGradient(
                    colors: [.black.opacity(0.6), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 120)
                .ignoresSafeArea()
                Spacer()
            }

            // 底部渐变遮罩 + 按钮
            VStack(spacing: 0) {
                Spacer()

                // 图片选择器 (仅当有连拍时显示)
                if images.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedIndex == idx ? Design.accent : Color.clear, lineWidth: 2)
                                    )
                                    .onTapGesture {
                                        withAnimation { selectedIndex = idx }
                                    }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 20)
                }

                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 120)
                .overlay(
                    HStack(spacing: 16) {
                        // 重拍
                        Button(action: onRetake) {
                            VStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 22, weight: .medium))
                                Text("重拍")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                        }

                        // 保存
                        Button {
                            if selectedIndex < images.count {
                                onSave(images[selectedIndex])
                            }
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(Design.success)
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "arrow.down.to.line")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.black)
                                }
                                Text("保存")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Design.success)
                            }
                        }

                        // 分享（P2-4 加入水印）
                        Button {
                            guard selectedIndex < images.count else { return }
                            let watermarkedImg = isPro ? images[selectedIndex] : images[selectedIndex].withPoseAIWatermark()
                            let av = UIActivityViewController(activityItems: [watermarkedImg], applicationActivities: nil)
                            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let root = scene.windows.first?.rootViewController {
                                root.present(av, animated: true)
                            }
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 22, weight: .medium))
                                Text("分享")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 44),
                    alignment: .bottom
                )
            }
            .ignoresSafeArea()
        }
        .onAppear {
            withAnimation { appeared = true }
        }
    }
}

// MARK: - 水印扩展 (P2-4)
extension UIImage {
    func withPoseAIWatermark() -> UIImage {
        let size = self.size
        UIGraphicsBeginImageContextWithOptions(size, false, self.scale)
        self.draw(in: CGRect(origin: .zero, size: size))
        
        let text = " 📸 Shot on PoseAI " as NSString
        // 字体大小自适应图片
        let fontSize = max(size.width, size.height) * 0.015
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: fontSize),
            .foregroundColor: UIColor.white.withAlphaComponent(0.9),
            .backgroundColor: UIColor.black.withAlphaComponent(0.3)
        ]
        
        let textSize = text.size(withAttributes: attributes)
        // 右下角 2% padding
        let padding = size.width * 0.02
        let rect = CGRect(
            x: size.width - textSize.width - padding,
            y: size.height - textSize.height - padding,
            width: textSize.width,
            height: textSize.height
        )
        // 绘制带圆角的背景（如果想追求更好效果可用 UIBezierPath 画带圆角的背景）
        let bgPath = UIBezierPath(roundedRect: rect.insetBy(dx: -8, dy: -4), cornerRadius: 8)
        UIColor.black.withAlphaComponent(0.4).setFill()
        bgPath.fill()
        
        text.draw(in: rect, withAttributes: attributes)
        
        let watermarkedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return watermarkedImage ?? self
    }
}

#Preview { ContentView() }

// MARK: - 拍摄历史相册
struct SessionGallerySheet: View {
    let images: [UIImage]
    @Environment(\.dismiss) var dismiss
    @State private var selectedImage: UIImage? = nil

    let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(Array(images.enumerated()), id: \.offset) { idx, img in
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .aspectRatio(1, contentMode: .fill)
                            .clipped()
                            .onTapGesture { selectedImage = img }
                    }
                }
            }
            .navigationTitle("本次拍摄 (\(images.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: Binding(
                get: { selectedImage.map { IdentifiableImage(image: $0) } },
                set: { if $0 == nil { selectedImage = nil } }
            )) { wrapper in
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: wrapper.image)
                        .resizable()
                        .scaledToFit()
                        .ignoresSafeArea()
                    VStack {
                        HStack {
                            Button { selectedImage = nil } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding()
                            }
                            Spacer()
                        }
                        Spacer()
                    }
                }
            }
        }
    }
}

// MARK: - Paywall View
struct PaywallView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("isPro") var isPro = false
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // 背景渐变
            LinearGradient(
                colors: [Color(red: 0.1, green: 0.1, blue: 0.15), .black],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 30) {
                // 顶部关闭按钮
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white.opacity(0.3))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                
                // 图标
                ZStack {
                    Circle()
                        .fill(RadialGradient(
                            colors: [Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.3), .clear],
                            center: .center, startRadius: 10, endRadius: 80
                        ))
                        .frame(width: 140, height: 140)
                    
                    Image(systemName: "crown.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.82, blue: 0.45), Color(red: 1.0, green: 0.6, blue: 0.2)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .shadow(color: Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.5), radius: 10, x: 0, y: 5)
                }
                
                // 标题
                VStack(spacing: 8) {
                    Text("解锁 PoseAI Pro")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                    Text("释放完整拍摄潜力，拍出电影级大片")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                // 特权列表
                VStack(alignment: .leading, spacing: 20) {
                    ProFeatureRow(icon: "sparkles", title: "全场景方案库", desc: "解锁街道、公园、家居等专属姿势推荐")
                    ProFeatureRow(icon: "camera.burst.fill", title: "阵发无限连拍", desc: "不再局限于单张，高速抓拍不错过任何瞬间")
                    ProFeatureRow(icon: "photo.badge.plus", title: "无水印纯净保存", desc: "解锁取消专属底标的功能配置")
                }
                .padding(.horizontal, 32)
                .padding(.top, 10)
                
                Spacer()
                
                // 购买按钮区域
                VStack(spacing: 16) {
                    Text("限时优惠：¥98 / 终身买断")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.45))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.15), in: Capsule())
                    
                    Button {
                        // 模拟购买成功
                        withAnimation {
                            isPro = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            dismiss()
                        }
                    } label: {
                        Text("立即升级")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.82, blue: 0.45), Color(red: 1.0, green: 0.7, blue: 0.3)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                in: Capsule()
                            )
                            .shadow(color: Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.4), radius: 12, y: 5)
                    }
                    
                    HStack(spacing: 20) {
                        Button("恢复购买") { }
                        Button("服务条款") { }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
    }
}

private struct ProFeatureRow: View {
    let icon: String
    let title: String
    let desc: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.45))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(desc)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
