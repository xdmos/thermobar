import AppKit
import SwiftUI

struct PanelWindowBridge: NSViewRepresentable {
    let store: PanelFrameStore
    let panelOpacity: Double

    init(store: PanelFrameStore, panelOpacity: Double = 1.00) {
        self.store = store
        self.panelOpacity = panelOpacity
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store, panelOpacity: panelOpacity)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.scheduleInstall(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.setPanelOpacity(panelOpacity)
        context.coordinator.scheduleInstall(for: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.dismantle(view: nsView)
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private let store: PanelFrameStore
        private var panelOpacity: Double
        private weak var window: NSWindow?
        private var originalVisualState: WindowVisualState?
        // AppKit asks NSObject forwarding hooks from Objective-C, outside Swift's
        // actor annotations; AppKit delivers these delegate callbacks on main.
        nonisolated(unsafe) private weak var forwardedDelegate: NSWindowDelegate?
        private var hasRestoredFrame = false
        private var isApplyingProgrammaticFrame = false
        private var isUserMoveActive = false
        private var isObservingScreenParameters = false
        private weak var activeView: NSView?
        private var installationGeneration: UInt64 = 0

        init(store: PanelFrameStore, panelOpacity: Double = 1.00) {
            self.store = store
            self.panelOpacity = panelOpacity
            super.init()
        }

        func setPanelOpacity(_ panelOpacity: Double) {
            self.panelOpacity = panelOpacity
            guard let window else { return }
            configureHostSurface(window)
        }

        func scheduleInstall(for view: NSView) {
            let generation = activate(view: view)
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.installIfCurrent(on: view.window, view: view, generation: generation)
            }
        }

        func activate(view: NSView) -> UInt64 {
            installationGeneration &+= 1
            activeView = view
            return installationGeneration
        }

        func installIfCurrent(on window: NSWindow?, view: NSView, generation: UInt64) {
            guard installationGeneration == generation, activeView === view else { return }
            install(on: window)
        }

        func dismantle(view: NSView) {
            guard activeView === view else { return }
            installationGeneration &+= 1
            activeView = nil
            uninstall()
        }

        func install(on window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                uninstall()
                self.window = window
                originalVisualState = WindowVisualState(window: window)
                hasRestoredFrame = false
                isUserMoveActive = false
            }

            configureHostSurface(window)

            // Keep SwiftUI's existing delegate in the chain. The proxy owns only
            // move notifications and forwards every other optional delegate method.
            if window.delegate !== self {
                forwardedDelegate = window.delegate
                window.delegate = self
            }

            window.isMovableByWindowBackground = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            startObservingScreenParameters()

            guard !hasRestoredFrame else { return }
            hasRestoredFrame = true
            applyProgrammaticFrame(store.restoreFrame())
        }

        func uninstall() {
            guard let window else {
                stopObservingScreenParameters()
                forwardedDelegate = nil
                return
            }
            if window.delegate === self {
                window.delegate = forwardedDelegate
            }
            restoreVisualState(of: window)
            self.window = nil
            forwardedDelegate = nil
            hasRestoredFrame = false
            isApplyingProgrammaticFrame = false
            isUserMoveActive = false
            stopObservingScreenParameters()
        }

        func windowWillMove(_ notification: Notification) {
            isUserMoveActive = !isApplyingProgrammaticFrame
            forwardedDelegate?.windowWillMove?(notification)
        }

        func windowDidMove(_ notification: Notification) {
            defer {
                isUserMoveActive = false
                forwardedDelegate?.windowDidMove?(notification)
            }
            guard isUserMoveActive, !isApplyingProgrammaticFrame, let window else { return }
            store.save(frame: window.frame, on: window.screen)
        }

        @objc private func screenParametersChanged(_ notification: Notification) {
            guard let window else { return }
            let frame = PanelFrameStore.clamp(window.frame, screens: NSScreen.screens.compactMap { screen in
                guard let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
                    return nil
                }
                return .init(displayIdentifier: identifier, visibleFrame: screen.visibleFrame)
            })
            applyProgrammaticFrame(frame)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            guard selector != #selector(windowWillMove(_:)), selector != #selector(windowDidMove(_:)),
                  forwardedDelegate?.responds(to: selector) == true
            else {
                return super.forwardingTarget(for: selector)
            }
            return forwardedDelegate
        }

        private func applyProgrammaticFrame(_ frame: CGRect?) {
            guard let frame, let window, window.frame != frame else { return }
            isApplyingProgrammaticFrame = true
            window.setFrame(frame, display: true)
            isApplyingProgrammaticFrame = false
        }

        private func configureHostSurface(_ window: NSWindow) {
            if panelOpacity == 1.00 {
                applyOriginalVisualState(to: window)
            } else {
                // Keep the original native surface participating in hit-testing
                // and let AppKit compose the whole panel at the selected opacity.
                window.alphaValue = CGFloat(panelOpacity)
            }
        }

        private func applyOriginalVisualState(to window: NSWindow) {
            guard let originalVisualState else { return }
            window.isOpaque = originalVisualState.isOpaque
            window.backgroundColor = originalVisualState.backgroundColor
            window.alphaValue = originalVisualState.alphaValue
        }

        private func restoreVisualState(of window: NSWindow) {
            applyOriginalVisualState(to: window)
            self.originalVisualState = nil
        }

        private func startObservingScreenParameters() {
            guard !isObservingScreenParameters else { return }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(screenParametersChanged(_:)),
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            isObservingScreenParameters = true
        }

        private func stopObservingScreenParameters() {
            guard isObservingScreenParameters else { return }
            NotificationCenter.default.removeObserver(
                self,
                name: NSApplication.didChangeScreenParametersNotification,
                object: nil
            )
            isObservingScreenParameters = false
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        private struct WindowVisualState {
            let isOpaque: Bool
            let backgroundColor: NSColor
            let alphaValue: CGFloat

            @MainActor init(window: NSWindow) {
                isOpaque = window.isOpaque
                backgroundColor = window.backgroundColor
                alphaValue = window.alphaValue
            }
        }
    }
}
