import SwiftUI

@main
struct zzzlyApp: App {
    @State private var monitor = SnoreMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(monitor)
        }
    }
}
