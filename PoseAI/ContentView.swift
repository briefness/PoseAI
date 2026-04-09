import SwiftUI
import AVFoundation
import AVFAudio

struct ContentView: View {

    // MARK: - State
    @StateObject private var manager = CameraManager()
    @State private var scene: SceneType = .unknown
    @State private var points: [String: CGPoint] = [:]
    @State private var isHalfBody: Bool = false
    @State private var score: Double = 0       // 低通滤波后的平滑分数
    @State private var rawScore: Double = 0    // 原始分数（用于内部计算）
    @State private var showGuide: Bool = false // 姿势引导面板
    @State private var hapticCooldown: Bool = false // 防高频震动
    @State private var breathingPulse: Bool = false // 呼吸灯动效控制

    // MARK: - 语音库
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - 惊喜阈值
    private let successThreshold: Double = 85

    var body: some View {
        ZStack {
            // ── 层 1：摄像头预览 ──────────────────────────
            cameraLayer

            // ── 层 2：骨骼 Canvas ────────────────────────
            skeletonCanvas

            // ── 层 3：AR 地面导引 ─────────────────────────
            arFootprintsOverlay

            // ── 层 4：HUD UI ─────────────────────────────
            hudOverlay
            
            // ── 直男拍照纠偏警告 ────────────────────────────
            if manager.devicePitch < -0.35 {
                pitchWarningOverlay
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: bind)
        .onDisappear { manager.stop() }
        .sheet(isPresented: $showGuide) {
            PoseGuideSheet(scene: scene)
        }
    }

    // MARK: - 摄像头层
    private var cameraLayer: some View {
        Group {
            if manager.authorizationStatus == .authorized {
                CameraPreview(manager: manager)
                    .ignoresSafeArea()
            } else if manager.authorizationStatus == .denied {
                permissionDeniedView
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }

    // 未授权提示视图
    private var permissionDeniedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("需要摄像头权限")
                .font(.headline)
                .foregroundColor(.white)
            Text("请在「设置 > 隐私 > 摄像头」中开启权限。")
                .font(.caption)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - 骨骼绘制（Canvas）
    private var skeletonCanvas: some View {
        Canvas { ctx, size in
            let preset = scene.recommendedPose.points
            let jointColor = scoreColor

            // ── 绘制骨骼连线 ──────────────────────────
            drawBones(ctx: ctx, size: size, points: points, color: jointColor)
            drawBones(ctx: ctx, size: size, points: preset, color: .white, alpha: 0.2, radius: 5)

            // ── 绘制预设姿势虚影 ─────────────────────
            for (id, p) in preset {
                if isHalfBody && PoseMatcher.lowerBodyJoints.contains(id) { continue }
                var ghostCtx = ctx
                ghostCtx.opacity = 0.25
                ghostCtx.fill(
                    Circle().path(in: rect(p, size, 14)),
                    with: .color(.white)
                )
            }

            // ── 绘制实时关节点 ─────────────────────
            for (id, p) in points {
                if isHalfBody && PoseMatcher.lowerBodyJoints.contains(id) { continue }
                var dotCtx = ctx
                dotCtx.opacity = 0.9
                dotCtx.fill(
                    Circle().path(in: rect(p, size, 9)),
                    with: .color(jointColor)
                )
                // 高亮外圈
                dotCtx.stroke(
                    Circle().path(in: rect(p, size, 13)),
                    with: .color(.white.opacity(0.5)),
                    lineWidth: 1.5
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - HUD 叠加层
    private var hudOverlay: some View {
        VStack(spacing: 0) {
            // ── 顶部状态栏 ──────────────────────────
            topBar
                .padding(.top, 60)
                .padding(.horizontal, 20)

            Spacer()

            // ── 评分指示器 ──────────────────────────
            scoreIndicator
                .padding(.bottom, 20)

            // ── 底部控制栏 ──────────────────────────
            bottomBar
                .padding(.bottom, 50)
                .padding(.horizontal, 40)
        }
    }

    // 顶部状态栏
    private var topBar: some View {
        HStack {
            // 场景标签
            Label(
                isHalfBody ? "半身模式" : scene.displayName,
                systemImage: isHalfBody ? "person.crop.rectangle" : "photo.on.rectangle"
            )
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .foregroundColor(.white)

            Spacer()

            // 匹配度标签
            Text("\(Int(score))%")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(scoreColor.opacity(0.85))
                .clipShape(Capsule())
                .foregroundColor(.white)

            // 引导按钮
            Button {
                showGuide = true
            } label: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.leading, 8)
        }
    }

    // 评分指示器（圆形进度环）
    private var scoreIndicator: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 6)

            Circle()
                .trim(from: 0, to: score / 100)
                .stroke(scoreColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: score)

            VStack(spacing: 2) {
                Text("\(Int(score))")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("匹配度")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .frame(width: 90, height: 90)
        .scaleEffect(score > successThreshold ? 1.08 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: score > successThreshold)
    }
    
    // 构图纠偏警告（防直男俯拍）
    private var pitchWarningOverlay: some View {
        VStack {
            Spacer()
            Text("⚠️ 警告：请平行拍摄或低角度拍摄（显腿长）")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.85))
                .cornerRadius(8)
                .shadow(radius: 5)
                .padding(.bottom, 160) // 悬浮于快门按钮上方
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut, value: manager.devicePitch < -0.35)
    }
    
    // AR 地面导引 (辅助站位)
    private var arFootprintsOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 40) {
                Image(systemName: "shoe.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30)
                    .rotationEffect(.degrees(-10))
                Image(systemName: "shoe.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30)
                    .rotationEffect(.degrees(10))
            }
            .foregroundColor(.white.opacity(isHalfBody ? 0 : 0.3)) // 半身模式隐藏脚印
            .padding(.bottom, 220)
        }
    }

    // 底部控制栏
    private var bottomBar: some View {
        HStack {
            // 前后置切换按钮
            Button {
                manager.isFront.toggle()
            } label: {
                Image(systemName: "camera.rotate.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            Spacer()

            // 快门按钮（匹配度到达阈值时激活）
            shutterButton

            Spacer()

            // 场景切换按钮（手动覆盖）
            Button {
                cycleScene()
            } label: {
                Image(systemName: "scope")
                    .font(.system(size: 24))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
        }
    }

    // 快门按钮
    private var shutterButton: some View {
        let isReady = score > successThreshold
        return ZStack {
            Circle()
                .fill(Color.white.opacity(isReady ? 0.95 : 0.35))
                .frame(width: 75, height: 75)

            Circle()
                .strokeBorder(Color.white, lineWidth: 4)
                .frame(width: 85, height: 85)
                .scaleEffect(isReady && breathingPulse ? 1.15 : 1.0)
                .opacity(isReady && breathingPulse ? 0.0 : 1.0)
                // 按就绪状态启停呼吸动效
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
                    .font(.system(size: 24))
                    .foregroundColor(.black)
            }
        }
        .scaleEffect(isReady ? 1.12 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: isReady)
    }

    // MARK: - 辅助：分数色
    private var scoreColor: Color {
        if score > 80 { return .green }
        if score > 50 { return .yellow }
        return .red
    }

    // MARK: - 辅助：骨骼连线绘制
    private func drawBones(
        ctx: GraphicsContext,
        size: CGSize,
        points: [String: CGPoint],
        color: Color,
        alpha: Double = 0.7,
        radius: CGFloat = 4
    ) {
        let connections: [(String, String)] = [
            ("leftShoulder", "rightShoulder"),
            ("leftShoulder", "leftElbow"), ("leftElbow", "leftWrist"),
            ("rightShoulder", "rightElbow"), ("rightElbow", "rightWrist"),
            ("leftShoulder", "leftHip"), ("rightShoulder", "rightHip"),
            ("leftHip", "rightHip"),
            ("leftHip", "leftKnee"), ("leftKnee", "leftAnkle"),
            ("rightHip", "rightKnee"), ("rightKnee", "rightAnkle"),
            ("neck", "leftShoulder"), ("neck", "rightShoulder")
        ]

        var lineCtx = ctx
        lineCtx.opacity = alpha

        for (a, b) in connections {
            guard let pa = points[a], let pb = points[b] else { continue }
            if isHalfBody && (PoseMatcher.lowerBodyJoints.contains(a) || PoseMatcher.lowerBodyJoints.contains(b)) { continue }
            var path = Path()
            path.move(to: CGPoint(x: pa.x * size.width, y: pa.y * size.height))
            path.addLine(to: CGPoint(x: pb.x * size.width, y: pb.y * size.height))
            lineCtx.stroke(path, with: .color(color), lineWidth: 2.5)
        }
    }

    // MARK: - 辅助：关节点 CGRect
    private func rect(_ p: CGPoint, _ size: CGSize, _ diameter: CGFloat) -> CGRect {
        CGRect(
            x: p.x * size.width - diameter / 2,
            y: p.y * size.height - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    // MARK: - 手动场景切换
    private func cycleScene() {
        let scenes: [SceneType] = [.coffee_shop, .beach, .forest, .unknown]
        let current = scenes.firstIndex(of: scene) ?? 0
        scene = scenes[(current + 1) % scenes.count]
    }

    // MARK: - 绑定回调
    private func bind() {
        // 姿态更新回调
        manager.visionService.onUpdate = { [self] pts, half in
            self.points = pts
            self.isHalfBody = half

            let newRaw = PoseMatcher.calculateSimilarity(
                current: pts,
                preset: scene.recommendedPose.points,
                isHalfBody: half
            )
            // 低通滤波防抖：旧值权重 70%，新值权重 30%
            let smoothed = (self.score * 0.7) + (newRaw * 0.3)
            withAnimation(.linear(duration: 0.1)) {
                self.score = smoothed
            }

            // 震动与语音反馈：分数达标且冷却完成才触发
            if smoothed > successThreshold && !self.hapticCooldown {
                self.hapticCooldown = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                speak("姿势完美，保持住")
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.hapticCooldown = false
                }
            }
        }

        // 场景变化回调（仅在手动未选择时自动更新）
        manager.visionService.onSceneChange = { scene in
            if self.scene == .unknown {
                self.scene = scene
                self.speak("已切换至" + scene.displayName)
            }
        }

        manager.start()
    }
    
    // MARK: - 语音合成引导
    private func speak(_ text: String) {
        guard !synthesizer.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.5 // 语速适中
        utterance.pitchMultiplier = 1.0
        synthesizer.speak(utterance)
    }
}

// MARK: - 姿势引导面板
struct PoseGuideSheet: View {
    let scene: SceneType
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 80))
                    .foregroundColor(.accentColor)

                Text("当前场景：\(scene.displayName)")
                    .font(.title2.bold())

                Text("请参照屏幕上的半透明白色骨骼轮廓调整你的姿势。\n匹配度达到 85% 以上时，快门按钮将激活。")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 32)

                VStack(alignment: .leading, spacing: 12) {
                    GuideRow(icon: "circle.fill", color: .green,  text: "绿色：匹配度 > 80%，姿势很好！")
                    GuideRow(icon: "circle.fill", color: .yellow, text: "黄色：匹配度 50~80%，继续调整")
                    GuideRow(icon: "circle.fill", color: .red,    text: "红色：匹配度 < 50%，请参考白色轮廓")
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(12)
                .padding(.horizontal, 24)

                Spacer()
            }
            .padding(.top, 40)
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

struct GuideRow: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(.subheadline)
        }
    }
}

#Preview {
    ContentView()
}
