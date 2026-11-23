import AppKit
import SwiftUI

/// The recording dot and its glow, breathing on Core Animation.
///
/// The breath runs in the render server, so the app does no work per frame, and its frame rate is
/// capped: WindowServer re-renders the window for every frame it draws, and a breath of 1.6s reads
/// as smooth at 15 fps. A SwiftUI animation or timeline would draw at the display rate.
struct PulsingDot: NSViewRepresentable {
    var dotSize: CGFloat
    /// Breathing; otherwise a steady, dimmer dot with no glow.
    var live: Bool
    /// A steady dot at mid-breath instead of the motion.
    var reduceMotion: Bool

    func makeNSView(context: Context) -> PulsingDotView { PulsingDotView(dotSize: dotSize) }

    func updateNSView(_ view: PulsingDotView, context: Context) {
        view.set(dotSize: dotSize, live: live, reduceMotion: reduceMotion)
    }
}

final class PulsingDotView: NSView {
    private static let halfPeriod: CFTimeInterval = 0.8
    /// A layer is composited as is, so this colour shows as written. It is lighter than system
    /// red because a plain red is hard to see on a dark backdrop.
    private static let coreColor = NSColor(srgbRed: 1, green: 0.48, blue: 0.56, alpha: 1)

    private var dotSize: CGFloat
    private let glow = CALayer()
    private let core = CALayer()
    /// What `apply()` last used, so an update with the same values leaves the running breath
    /// alone. Nil until the first `set`, which draws the steady dot.
    private var state: (live: Bool, reduceMotion: Bool)?

    init(dotSize: CGFloat) {
        self.dotSize = dotSize
        super.init(frame: .zero)
        wantsLayer = true
        glow.compositingFilter = "plusLighter"
        core.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        core.cornerRadius = dotSize / 2
        core.backgroundColor = Self.coreColor.cgColor
        layer?.addSublayer(glow)
        layer?.addSublayer(core)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(dotSize newSize: CGFloat, live: Bool, reduceMotion: Bool) {
        if newSize != dotSize {
            dotSize = newSize
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            core.bounds = CGRect(x: 0, y: 0, width: newSize, height: newSize)
            core.cornerRadius = newSize / 2
            CATransaction.commit()
            renderGlow()
            needsLayout = true
        }
        // Restarting the breath on every SwiftUI update would reset its phase.
        guard state.map({ $0 != (live, reduceMotion) }) ?? true else { return }
        state = (live, reduceMotion)
        apply()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.position = CGPoint(x: bounds.midX, y: bounds.midY)
        core.position = glow.position
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderGlow()
        apply()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderGlow()
    }

    private func renderGlow() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Rendered once; breathing only moves the layer's opacity and scale. The padding leaves
        // room for the blur to spread past the disc.
        let side = dotSize * 2.2 + 6 * dotSize * 0.9
        let renderer = ImageRenderer(content: Circle().fill(Color.red)
            .frame(width: dotSize * 2.2, height: dotSize * 2.2)
            .blur(radius: dotSize * 0.9)
            .frame(width: side, height: side))
        renderer.scale = scale
        glow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        glow.contentsScale = scale
        glow.contents = renderer.cgImage
    }

    private func apply() {
        glow.removeAllAnimations()
        core.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Same ranges as a breath of 0...1: the glow 0.035...0.12, the dot 0.75...1.
        guard let state, state.live else { return set(glow: 0, core: 0.55) }
        guard !state.reduceMotion else { return set(glow: 0.035 + 0.085 * 0.6, core: 0.75 + 0.25 * 0.6) }
        glow.add(breath("opacity", 0.035, 0.12), forKey: "breath")
        glow.add(breath("transform.scale", 0.85, 1.15), forKey: "scale")
        core.add(breath("opacity", 0.75, 1), forKey: "breath")
    }

    private func set(glow glowOpacity: Float, core coreOpacity: Float) {
        glow.opacity = glowOpacity
        core.opacity = coreOpacity
    }

    private func breath(_ keyPath: String, _ from: Double, _ to: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = Self.halfPeriod
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return AmbientMotion.capped(a)
    }
}
