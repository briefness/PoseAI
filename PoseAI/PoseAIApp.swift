import SwiftUI

@main
struct PoseAIApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark) // 强制深色模式，摄像头场景下更美观
        }
    }
}
