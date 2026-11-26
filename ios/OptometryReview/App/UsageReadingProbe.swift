import SwiftUI

/// Samples the explanation's position in its nearest scroll viewport without changing scrolling.
struct UsageReadingProbe: UIViewRepresentable {
    var onSample: (Double, Bool) -> Void

    func makeUIView(context: Context) -> Probe { Probe(onSample: onSample) }
    func updateUIView(_ view: Probe, context: Context) { view.onSample = onSample }

    final class Probe: UIView {
        var onSample: (Double, Bool) -> Void
        private var ticker: CADisplayLink?
        private let target = Target()

        init(onSample: @escaping (Double, Bool) -> Void) {
            self.onSample = onSample
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            target.view = self
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { ticker?.invalidate() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            ticker?.invalidate()
            ticker = nil
            if window != nil {
                let ticker = CADisplayLink(target: target, selector: #selector(Target.tick))
                ticker.preferredFramesPerSecond = 5
                ticker.add(to: .main, forMode: .common)
                self.ticker = ticker
            }
        }

        func sample() {
            guard let window, bounds.height > 0 else { return }
            var parent = superview
            while parent != nil && !(parent is UIScrollView) { parent = parent?.superview }
            let viewport: CGRect
            if let scroll = parent as? UIScrollView {
                viewport = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: window)
                    .intersection(window.bounds)
            } else { viewport = window.bounds }
            let rect = convert(bounds, to: window)
            let visible = !rect.intersection(viewport).isEmpty
            let depth = min(1, max(0, (viewport.maxY - rect.minY) / rect.height))
            onSample(depth, visible)
        }

        private final class Target: NSObject {
            weak var view: Probe?
            @objc func tick() { view?.sample() }
        }
    }
}
