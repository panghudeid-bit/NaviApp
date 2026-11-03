import SwiftUI

@main
struct NaviApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark) // 统一采用更具科技感与防眩光的车规级深色模式
        }
    }
}