import MinutesCore
import SwiftUI

@main
struct MinutesApp: App {
    @StateObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundKeeper.shared.register()
        _model = StateObject(wrappedValue: AppModel(demo: DemoScenario.fromLaunchArguments()))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.becameActive() }
                }
        }
    }
}

enum Route: Hashable {
    case meeting(String)
    case settings
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .meeting(let id): MeetingDetailView(id: id)
                    case .settings: SettingsView()
                    }
                }
        }
        .tint(Theme.ink)
        .fullScreenCover(isPresented: Binding(get: { model.recording != nil }, set: { _ in })) {
            RecordingView()
                .environmentObject(model)
        }
        .onChange(of: model.openMeetingID) { _, id in
            guard let id else { return }
            path = model.demoRoute ?? [.meeting(id)]
            model.openMeetingID = nil
        }
        .onAppear {
            if let route = model.demoRoute { path = route }
        }
        #if DEBUG
        .task { await EndToEnd.run(model) }
        #endif
    }
}
