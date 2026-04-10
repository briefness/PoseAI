import SwiftUI

// MARK: - 首次启动引导（Onboarding）
// 只在第一次安装后展示，用 AppStorage 持久化标记
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentPage: Int = 0
    @State private var hasAgreedToPrivacy: Bool = false

    private let steps: [OnboardingStep] = [
        OnboardingStep(
            icon: "viewfinder",
            iconColor: Color(red: 1.0, green: 0.82, blue: 0.45),  // Design.accent
            title: "先对准背景",
            subtitle: "打开 App 后，把手机镜头\n对准你想拍照的场景",
            detail: "咖啡馆、海边、森林……\nAI 会自动识别并推荐最佳方案"
        ),
        OnboardingStep(
            icon: "figure.stand",
            iconColor: Color(red: 1.0, green: 0.82, blue: 0.45),
            title: "站进人形剪影",
            subtitle: "画面中会出现一个人形轮廓\n调整位置让自己和剪影重合",
            detail: "剪影会根据你的实际身高自动缩放\n右上角分数环越高说明姿势越接近"
        ),
        OnboardingStep(
            icon: "camera.circle.fill",
            iconColor: Color(red: 0.35, green: 0.95, blue: 0.60),  // Design.success
            title: "保持不动，自动拍照",
            subtitle: "匹配度超过 85% 并保持 0.8 秒\nApp 会自动按下快门",
            detail: "也可以点击底部圆形按钮手动拍照\n照片自动保存到你的相册"
        )
    ]

    var body: some View {
        ZStack {
            // 背景
            Color.black.ignoresSafeArea()
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.12), .black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 跳过按钮
                HStack {
                    Spacer()
                    Button("跳过") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isPresented = false
                        }
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    // 使用透明度控制可见性，天然保持布局高度稳定
                    .opacity(currentPage < steps.count - 1 ? 1 : 0)
                }

                Spacer()

                // 步骤内容（TabView 横滑）
                TabView(selection: $currentPage) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { idx, step in
                        StepCard(step: step)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.5, dampingFraction: 0.82), value: currentPage)
                .frame(maxHeight: 380)

                Spacer()

                // 底部：页码指示器 + 按钮
                VStack(spacing: 24) {
                    // 页码点
                    HStack(spacing: 8) {
                        ForEach(0..<steps.count, id: \.self) { idx in
                            Capsule()
                                .fill(idx == currentPage
                                    ? Color(red: 1.0, green: 0.82, blue: 0.45)
                                    : Color.white.opacity(0.2))
                                .frame(width: idx == currentPage ? 24 : 8, height: 8)
                                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: currentPage)
                        }
                    }

                    // 隐私协议 (P3-1)
                    if currentPage == steps.count - 1 {
                        HStack(spacing: 8) {
                            Button {
                                withAnimation { hasAgreedToPrivacy.toggle() }
                            } label: {
                                Image(systemName: hasAgreedToPrivacy ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 16))
                                    .foregroundColor(hasAgreedToPrivacy ? Color(red: 0.35, green: 0.95, blue: 0.60) : .white.opacity(0.5))
                            }
                            Text("我已阅读并同意")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                            Link("《隐私政策》", destination: URL(string: "https://poseai.app/privacy")!)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                        }
                        .padding(.bottom, -8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // 下一步 / 开始按钮
                    Button {
                        if currentPage < steps.count - 1 {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                currentPage += 1
                            }
                        } else {
                            if hasAgreedToPrivacy {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    isPresented = false
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(currentPage < steps.count - 1 ? "下一步" : "开始拍照")
                                .font(.system(size: 17, weight: .bold))
                            Image(systemName: currentPage < steps.count - 1 ? "arrow.right" : "camera.fill")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor((currentPage == steps.count - 1 && !hasAgreedToPrivacy) ? .white.opacity(0.5) : .black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(
                            backgroundColor(for: currentPage, agreed: hasAgreedToPrivacy),
                            in: Capsule()
                        )
                        .shadow(
                            color: shadowColor(for: currentPage, agreed: hasAgreedToPrivacy),
                            radius: 16, y: 6
                        )
                    }
                    .disabled(currentPage == steps.count - 1 && !hasAgreedToPrivacy)
                    .padding(.horizontal, 32)
                    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: currentPage)
                }
                .padding(.bottom, 24)
            }
        }
    }

    private func backgroundColor(for page: Int, agreed: Bool) -> Color {
        if page < steps.count - 1 {
            return Color(red: 1.0, green: 0.82, blue: 0.45)
        } else {
            return agreed ? Color(red: 0.35, green: 0.95, blue: 0.60) : Color.white.opacity(0.15)
        }
    }

    private func shadowColor(for page: Int, agreed: Bool) -> Color {
        if page < steps.count - 1 {
            return Color(red: 1.0, green: 0.82, blue: 0.45).opacity(0.4)
        } else {
            return agreed ? Color(red: 0.35, green: 0.95, blue: 0.60).opacity(0.4) : Color.clear
        }
    }
}

// MARK: - 单步内容卡片
private struct StepCard: View {
    let step: OnboardingStep
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 36) {
            // 图标光晕
            ZStack {
                Circle()
                    .fill(step.iconColor.opacity(0.12))
                    .frame(width: 130, height: 130)
                Circle()
                    .fill(step.iconColor.opacity(0.07))
                    .frame(width: 100, height: 100)
                Image(systemName: step.icon)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [step.iconColor, step.iconColor.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            .scaleEffect(appeared ? 1.0 : 0.75)
            .opacity(appeared ? 1.0 : 0)

            // 文字
            VStack(spacing: 14) {
                Text(step.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                Text(step.subtitle)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                Text(step.detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .offset(y: appeared ? 0 : 20)
            .opacity(appeared ? 1.0 : 0)
        }
        .padding(.horizontal, 36)
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.78).delay(0.05)) {
                appeared = true
            }
        }
        .onDisappear { appeared = false }
    }
}

// MARK: - 步骤数据模型
private struct OnboardingStep {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let detail: String
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
