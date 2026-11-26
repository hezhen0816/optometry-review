import SwiftUI
import GameController

struct UsageEnvironmentSnapshot: Equatable {
    let orientation: String
    let width: CGFloat
    let height: CGFloat
    let splitView: Bool
    let hardwareKeyboard: Bool
    let dynamicType: String
    let darkMode: Bool
    let iCloudSync: Bool

    @MainActor
    init(window: UIWindow) {
        switch window.windowScene?.interfaceOrientation {
        case .portrait: orientation = "portrait"
        case .portraitUpsideDown: orientation = "portraitUpsideDown"
        case .landscapeLeft: orientation = "landscapeLeft"
        case .landscapeRight: orientation = "landscapeRight"
        default: orientation = "unknown"
        }
        width = window.bounds.width.rounded()
        height = window.bounds.height.rounded()
        splitView = window.bounds.width + 1 < (window.windowScene?.screen.bounds.width ?? window.bounds.width)
        hardwareKeyboard = GCKeyboard.coalesced != nil
        dynamicType = window.traitCollection.preferredContentSizeCategory.rawValue
        darkMode = window.traitCollection.userInterfaceStyle == .dark
        iCloudSync = CloudSync.shared.enabled
    }

    var fields: [String: Any] {
        ["orientation": orientation, "windowWidth": width, "windowHeight": height, "splitView": splitView,
         "hardwareKeyboard": hardwareKeyboard, "dynamicType": dynamicType, "darkMode": darkMode, "iCloudSync": iCloudSync]
    }
}

/// Uses the hosting window rather than the screen, including in Split View and Slide Over.
struct UsageEnvironmentProbe: UIViewRepresentable {
    var onReady: () -> Void = {}
    func makeUIView(context: Context) -> Probe { Probe(onReady: onReady) }
    func updateUIView(_ view: Probe, context: Context) { view.sample() }

    final class Probe: UIView {
        private let onReady: () -> Void
        private var last: UsageEnvironmentSnapshot?
        private var observers: [NSObjectProtocol] = []

        init(onReady: @escaping () -> Void) {
            self.onReady = onReady
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) {
                (view: Probe, _: UITraitCollection) in view.sample()
            }
            for name in [.GCKeyboardDidConnect, .GCKeyboardDidDisconnect,
                         UIContentSizeCategory.didChangeNotification, UIApplication.didBecomeActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sample() }
                })
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

        override func didMoveToWindow() { super.didMoveToWindow(); sample() }
        override func layoutSubviews() { super.layoutSubviews(); sample() }

        func sample() {
            guard let window else { return }
            let value = UsageEnvironmentSnapshot(window: window)
            guard value != last else { return }
            last = value
            UsageLog.shared.updateEnvironment(value.fields)
            DispatchQueue.main.async { self.onReady() }
        }
    }
}
