import SwiftUI

@main
struct CloudAndxClientApp: App {
    @StateObject private var model = RuntimeViewModel()

    var body: some Scene {
        WindowGroup("CloudAndx Android") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 980, height: 700)
    }
}
