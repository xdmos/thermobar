import Darwin
import SwiftUI
import ThermoBarCore

@main
struct ThermoBarApp: App {
    @State private var model: AppModel
    private let workspaceLifecycle: WorkspaceLifecycle
    private let frameStore: PanelFrameStore

    init() {
        let systemIdentity = SystemIdentity.current()
        let appModel = AppModel(model: systemIdentity.model, build: systemIdentity.build)
        _model = State(initialValue: appModel)
        frameStore = PanelFrameStore()
        workspaceLifecycle = WorkspaceLifecycle { [weak appModel] event in
            Task { @MainActor [weak appModel] in
                await appModel?.handleLifecycleEvent(event)
            }
        }
        appModel.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPopoverView(model: model)
        } label: {
            MenuBarLabel(
                snapshot: model.snapshot,
                mode: model.panelVisible ? .visible : .menuBarOnly
            )
        }
        .menuBarExtraStyle(.window)

        Window("ThermoBar", id: "floating-panel") {
            FloatingPanelSceneContent(model: model, frameStore: frameStore)
        }
        .windowLevel(.floating)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: FloatingPanelLayout.width, height: 330)
        .defaultLaunchBehavior(model.panelVisible ? .presented : .suppressed)

        Settings {
            SettingsView(model: model)
        }
    }
}

private struct FloatingPanelSceneContent: View {
    let model: AppModel
    let frameStore: PanelFrameStore

    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        FloatingPanelView(
            snapshot: model.snapshot,
            mode: model.panelVisible ? .visible : .menuBarOnly,
            diagnostics: model.diagnostics,
            onClose: {
                dismissWindow(id: "floating-panel")
                model.setPanelVisibilityIntent(false)
            }
        )
        .background(PanelWindowBridge(store: frameStore, panelOpacity: model.panelOpacity))
        .onDisappear {
            model.setPanelVisibilityIntent(false)
        }
    }
}

private struct SystemIdentity {
    let model: String
    let build: String

    static func current() -> Self {
        Self(model: value(for: "hw.model"), build: value(for: "kern.osversion"))
    }

    private static func value(for name: String) -> String {
        var byteCount = 0
        guard sysctlbyname(name, nil, &byteCount, nil, 0) == 0, byteCount > 1 else {
            return ""
        }

        var buffer = [CChar](repeating: 0, count: byteCount)
        guard sysctlbyname(name, &buffer, &byteCount, nil, 0) == 0 else {
            return ""
        }
        return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}
