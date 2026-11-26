import SwiftUI
import UIKit

/// Screens hide the navigation bar for their own top bars, which also switches off UIKit's edge-swipe back.
/// `.interactivePopEnabled()` on a NavigationStack's root turns the swipe back on for that stack only, and
/// `.blocksInteractivePop()` turns it off for that stack while a screen that must not be left by a stray swipe
/// (a session in progress) is on screen. Other navigation controllers (sheets, system UI) are never touched.
@MainActor
final class InteractivePopController: NSObject, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    /// Probes of on-screen blocking views in this stack.
    private var blockers: Set<ObjectIdentifier> = []

    private static var installed: [ObjectIdentifier: InteractivePopController] = [:]

    private init(navigation: UINavigationController) {
        self.navigation = navigation
    }

    /// The controller of one navigation controller, installed as its edge-swipe delegate on first use.
    static func controller(for navigation: UINavigationController) -> InteractivePopController {
        installed = installed.filter { $0.value.navigation != nil }
        let key = ObjectIdentifier(navigation)
        if let c = installed[key] { return c }
        let c = InteractivePopController(navigation: navigation)
        navigation.interactivePopGestureRecognizer?.delegate = c
        installed[key] = c
        return c
    }

    var isBlocked: Bool { !blockers.isEmpty }

    func block(_ probe: ObjectIdentifier) { blockers.insert(probe) }
    func unblock(_ probe: ObjectIdentifier) { blockers.remove(probe) }

    nonisolated func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        MainActor.assumeIsolated {
            guard let navigation, gestureRecognizer === navigation.interactivePopGestureRecognizer else { return true }
            return navigation.viewControllers.count > 1 && blockers.isEmpty
        }
    }
}

/// Zero-size view that finds its navigation controller through the responder chain.
private final class InteractivePopProbeView: UIView {
    var blocks = false { didSet { if blocks != oldValue { update() } } }
    private weak var registered: InteractivePopController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        update()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The hosting controller may join its navigation controller after the first window move.
        if registered == nil { update() }
    }

    private var navigation: UINavigationController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController {
                return vc as? UINavigationController ?? vc.navigationController
            }
            responder = r.next
        }
        return nil
    }

    private func update() {
        let target = window == nil ? nil : navigation.map(InteractivePopController.controller(for:))
        let id = ObjectIdentifier(self)
        if let registered, registered !== target || !blocks {
            registered.unblock(id)
            self.registered = nil
        }
        guard let target else { return }
        if blocks {
            target.block(id)
            registered = target
        } else {
            registered = target
        }
    }

    deinit {
        let id = ObjectIdentifier(self)
        let controller = registered
        MainActor.assumeIsolated { controller?.unblock(id) }
    }
}

private struct InteractivePopProbe: UIViewRepresentable {
    let blocks: Bool

    func makeUIView(context: Context) -> InteractivePopProbeView {
        let view = InteractivePopProbeView(frame: .zero)
        view.blocks = blocks
        return view
    }

    func updateUIView(_ view: InteractivePopProbeView, context: Context) {
        view.blocks = blocks
    }
}

extension View {
    /// Enables the edge-swipe back in the NavigationStack containing this view (put it on the stack's root).
    func interactivePopEnabled() -> some View {
        background(InteractivePopProbe(blocks: false).frame(width: 0, height: 0).accessibilityHidden(true))
    }

    /// Disables the edge-swipe back of this view's own NavigationStack while it is on screen (when `active`).
    func blocksInteractivePop(_ active: Bool = true) -> some View {
        background(InteractivePopProbe(blocks: active).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}
