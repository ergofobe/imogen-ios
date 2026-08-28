import SwiftUI

@main
struct ImogenApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Registered in `init`, because the system requires every background task
        // identifier to be claimed before the app finishes launching.
        PhotoBackup.shared.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.imogenSafelight)
                .task {
                    AppModelHolder.current = model
                    pairFromEnvironmentIfAsked()
                }
                // Pairing links and the OAuth redirect both arrive this way, and can
                // arrive at any moment — including while somebody is looking at a
                // photograph. Handled at the top so they work from wherever they were.
                .onOpenURL { model.open($0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Coming to the front is the signal that matters. Somebody who has just
                // taken a photograph is usually holding the phone, and waiting for the
                // system to grant background time would let them put it down again.
                PhotoBackup.shared.runSoon(model)
            case .background:
                PhotoBackup.shared.scheduleBackgroundTask(model)
            default:
                break
            }
        }
    }
}

/// Pairing from the launch environment, for a simulator.
///
/// A simulator has no camera, and `simctl openurl` puts a system prompt in front of the
/// app that nothing on the command line can dismiss — so without this there is no way to
/// get a development build past its first screen without a real phone and a real QR code.
///
/// Debug only, and compiled out of anything shipped:
///
/// ```
/// xcrun simctl launch --console \
///   --env IMOGEN_PAIR_URI="imogen://pair?server=…&code=…" booted com.imogen.ios
/// ```
@MainActor
private func pairFromEnvironmentIfAsked() {
    #if DEBUG
        guard let uri = ProcessInfo.processInfo.environment["IMOGEN_PAIR_URI"],
            let url = URL(string: uri),
            let model = AppModelHolder.current
        else { return }
        model.open(url)
    #endif
}

extension Color {
    /// The safelight orange from a darkroom, which is imogen's one colour.
    ///
    /// Backed by the AccentColor asset, so light and dark mode get the same value
    /// system controls do, and there's a single source of truth for the color.
    static let imogenSafelight = Color("AccentColor")
}
