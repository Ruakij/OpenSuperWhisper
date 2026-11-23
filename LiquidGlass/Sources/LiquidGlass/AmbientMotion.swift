import AppKit
import QuartzCore
import SwiftUI

/// Frame rates for motion, by size. The window server re-renders for every frame that is drawn, so
/// each animation gets the lowest rate that shows no steps:
/// - small (`smallFrameRate`): slow fades and the breathing dot, data-driven bars;
/// - normal (`normalFrameRate`): spinners and a growing ring, where 15 fps visibly steps;
/// - large (`largeFrameRate`): a highlight sliding across a surface, where 30 fps still steps;
/// - uncapped: motion that follows the pointer or fills the window runs at the display rate. It needs
///   no cap here: SwiftUI transitions and `CAAnimation`s without a `preferredFrameRateRange` already do.
///
/// Looping motion runs on Core Animation rather than as a SwiftUI animation: a SwiftUI animation is
/// evaluated in the app process every frame, at the display rate (120 Hz on ProMotion), and
/// SwiftUI has no frame-rate cap for it.
public enum AmbientMotion {
    public static let smallFrameRate: Float = 15
    public static let normalFrameRate: Float = 30
    public static let largeFrameRate: Float = 60

    /// `animation` limited to `rate` (or the display rate, when that is lower).
    public static func capped<A: CAAnimation>(_ animation: A, rate: Float = smallFrameRate) -> A {
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
        return animation
    }
}

// MARK: - Bar levels

/// Meter bars at the resolution the screen can show.
public enum BarLevel {
    /// `level` (0...1) moved to the nearest whole device pixel of a bar that is `rest` tall at
    /// rest and `height` at full level. A change smaller than a pixel is not visible, and it would
    /// still make the meter render again when the level is used as it is; snapped, an unchanged
    /// bar produces the same view and SwiftUI commits nothing.
    public static func snapped(_ level: Double, rest: CGFloat, height: CGFloat, displayScale: CGFloat) -> Double {
        let span = height - rest
        guard span > 0, displayScale > 0 else { return level }
        let pixels = ((rest + span * CGFloat(level)) * displayScale).rounded()
        return Double(min(max((pixels / displayScale - rest) / span, 0), 1))
    }
}

/// The levels of a `BandsFeed` snapped to whole device pixels. The view, and the meter in
/// `content`, are invalidated only when a bar moves a whole pixel: the feed is not observed, so a
/// frame whose bars all stay put costs no view evaluation and no commit.
public struct SnappedBands<Content: View>: View {
    var feed: BandsFeed
    var rest: CGFloat
    var height: CGFloat
    var content: ([Float]) -> Content
    @Environment(\.displayScale) private var displayScale
    @State private var snapped: [Float] = []

    public init(feed: BandsFeed, rest: CGFloat, height: CGFloat,
                @ViewBuilder content: @escaping ([Float]) -> Content) {
        self.feed = feed
        self.rest = rest
        self.height = height
        self.content = content
        // All bars at rest from the first frame, before the feed delivers a value.
        _snapped = State(initialValue: Array(repeating: 0, count: feed.levels.count))
    }

    public var body: some View {
        content(snapped)
            .onReceive(feed.$levels) { update($0) }
            .onChange(of: displayScale) { update(feed.levels) }
    }

    private func update(_ levels: [Float]) {
        let next = levels.map {
            Float(BarLevel.snapped(Double($0), rest: rest, height: height, displayScale: displayScale))
        }
        if next != snapped { snapped = next }
    }
}

// MARK: - Spinner

/// An indeterminate spinner like the system's: eight spokes that fade toward the tail, turning
/// one step at a time. Drawn once; each step only rotates the layer.
public struct AmbientSpinner: NSViewRepresentable {
    var diameter: CGFloat

    public init(diameter: CGFloat = 16) {
        self.diameter = diameter
    }

    public func makeNSView(context: Context) -> AmbientSpinnerView { AmbientSpinnerView() }

    public func updateNSView(_ view: AmbientSpinnerView, context: Context) {
        view.configure(diameter: diameter, color: Color.primary.resolve(in: context.environment).cgColor)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: AmbientSpinnerView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

public final class AmbientSpinnerView: NSView {
    private static let spokes = 8
    private let turning = CALayer()
    private var spokeLayers: [CAShapeLayer] = []
    private var diameter: CGFloat = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(turning)
        for index in 0..<Self.spokes {
            let spoke = CAShapeLayer()
            // The newest spoke is the most opaque, the one behind it dimmer, and so on around.
            spoke.opacity = Float(0.75 - 0.6 * Double(index) / Double(Self.spokes - 1))
            turning.addSublayer(spoke)
            spokeLayers.append(spoke)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(diameter: CGFloat, color: CGColor) {
        if diameter != self.diameter {
            self.diameter = diameter
            draw()
            needsLayout = true
        }
        spokeLayers.forEach { $0.fillColor = color }
    }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        turning.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        turning.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        turning.removeAnimation(forKey: "turn")
        guard window != nil else { return }
        // One step per spoke, clockwise.
        let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        turn.values = (0..<Self.spokes).map { -Double($0) * 2 * .pi / Double(Self.spokes) }
        turn.calculationMode = .discrete
        turn.duration = 1
        turn.repeatCount = .infinity
        turning.add(AmbientMotion.capped(turn, rate: AmbientMotion.normalFrameRate), forKey: "turn")
    }

    private func draw() {
        let radius = diameter / 2
        let inner = radius * 0.42
        let width = radius * 0.24
        let spoke = CGPath(roundedRect: CGRect(x: -width / 2, y: inner, width: width, height: radius - inner),
                           cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, layer) in spokeLayers.enumerated() {
            layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            layer.position = CGPoint(x: radius, y: radius)
            // Spoke 0 at 12 o'clock, the rest counter-clockwise behind it.
            var turn = CGAffineTransform(translationX: radius, y: radius)
                .rotated(by: Double(index) * 2 * .pi / Double(Self.spokes))
            layer.path = spoke.copy(using: &turn)
        }
        CATransaction.commit()
    }
}

// MARK: - Fading content

/// SwiftUI content whose opacity changes on Core Animation at the capped rate. The content is
/// drawn once and the layer fades, so a fade does not re-render the SwiftUI tree per frame.
public struct FadingContent<Content: View>: View {
    var opacity: Double
    var duration: TimeInterval
    /// Room around the content for what it draws outside its frame (a shadow); the layout is the
    /// content's own.
    var bleed: CGFloat
    var content: Content

    public init(opacity: Double, duration: TimeInterval, bleed: CGFloat = 0,
                @ViewBuilder content: () -> Content) {
        self.opacity = opacity
        self.duration = duration
        self.bleed = bleed
        self.content = content()
    }

    public var body: some View {
        Host(opacity: opacity, duration: duration, content: content.padding(bleed))
            .padding(-bleed)
    }

    private struct Host<Inner: View>: NSViewRepresentable {
        var opacity: Double
        var duration: TimeInterval
        var content: Inner

        func makeNSView(context: Context) -> NSHostingView<Inner> {
            let view = NSHostingView(rootView: content)
            view.wantsLayer = true
            view.alphaValue = opacity
            return view
        }

        func updateNSView(_ view: NSHostingView<Inner>, context: Context) {
            view.rootView = content
            guard Float(view.alphaValue) != Float(opacity), let layer = view.layer else { return }
            let from = layer.presentation()?.opacity ?? layer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.alphaValue = opacity
            CATransaction.commit()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = Float(opacity)
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(AmbientMotion.capped(fade), forKey: "fade")
        }
    }
}

// MARK: - Ring

/// A ring that grows out of the view's frame and fades, once per `period`, forever.
public struct AmbientRing: NSViewRepresentable {
    var color: Color
    var lineWidth: CGFloat
    var growth: CGFloat
    var period: TimeInterval

    public init(color: Color, lineWidth: CGFloat = 1.5, growth: CGFloat = 2.1, period: TimeInterval = 1.4) {
        self.color = color
        self.lineWidth = lineWidth
        self.growth = growth
        self.period = period
    }

    public func makeNSView(context: Context) -> AmbientRingView { AmbientRingView(growth: growth, period: period) }

    public func updateNSView(_ view: AmbientRingView, context: Context) {
        view.set(color: color.resolve(in: context.environment).cgColor, lineWidth: lineWidth)
    }
}

public final class AmbientRingView: NSView {
    private let ring = CAShapeLayer()
    private let growth: CGFloat
    private let period: TimeInterval

    init(growth: CGFloat, period: TimeInterval) {
        self.growth = growth
        self.period = period
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        ring.fillColor = nil
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(color: CGColor, lineWidth: CGFloat) {
        ring.strokeColor = color
        ring.lineWidth = lineWidth
    }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.bounds = bounds
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: ring.lineWidth / 2, dy: ring.lineWidth / 2), transform: nil)
        CATransaction.commit()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ring.removeAllAnimations()
        guard window != nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = growth
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7
        fade.toValue = 0
        let beat = CAAnimationGroup()
        beat.animations = [grow, fade]
        beat.duration = period
        beat.repeatCount = .infinity
        beat.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(AmbientMotion.capped(beat, rate: AmbientMotion.normalFrameRate), forKey: "beat")
    }
}

// MARK: - Arc spinner

/// A partial ring turning at a steady rate, like a determinate-less progress arc. Drawn once; the
/// layer rotates.
public struct AmbientArcSpinner: NSViewRepresentable {
    var color: Color
    var diameter: CGFloat
    var lineWidth: CGFloat
    /// The visible share of the ring, 0...1.
    var arc: CGFloat
    var period: TimeInterval

    public init(color: Color, diameter: CGFloat = 24, lineWidth: CGFloat = 2.5, arc: CGFloat = 0.7,
                period: TimeInterval = 0.9) {
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth
        self.arc = arc
        self.period = period
    }

    public func makeNSView(context: Context) -> AmbientArcSpinnerView {
        AmbientArcSpinnerView(diameter: diameter, arc: arc, period: period)
    }

    public func updateNSView(_ view: AmbientArcSpinnerView, context: Context) {
        view.set(color: color.resolve(in: context.environment).cgColor, lineWidth: lineWidth)
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: AmbientArcSpinnerView,
                             context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}

public final class AmbientArcSpinnerView: NSView {
    private let turning = CALayer()
    private let arcLayer = CAShapeLayer()
    private let diameter: CGFloat
    private let period: TimeInterval

    init(diameter: CGFloat, arc: CGFloat, period: TimeInterval) {
        self.diameter = diameter
        self.period = period
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(turning)
        turning.addSublayer(arcLayer)
        arcLayer.fillColor = nil
        arcLayer.lineCap = .round
        arcLayer.strokeEnd = arc
        let box = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        turning.bounds = box
        arcLayer.bounds = box
        arcLayer.position = CGPoint(x: diameter / 2, y: diameter / 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(color: CGColor, lineWidth: CGFloat) {
        arcLayer.strokeColor = color
        arcLayer.lineWidth = lineWidth
        // The stroke is centred on the path; inset so it stays inside the diameter. Flipped so
        // the arc starts at 3 o'clock and runs clockwise.
        var flip = CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -diameter)
        arcLayer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: diameter, height: diameter)
            .insetBy(dx: lineWidth / 2, dy: lineWidth / 2), transform: &flip)
    }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        turning.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        turning.removeAnimation(forKey: "turn")
        guard window != nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = period
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .linear)
        turning.add(AmbientMotion.capped(turn, rate: AmbientMotion.normalFrameRate), forKey: "turn")
    }
}

// MARK: - Shimmer

/// A placeholder tint with a soft highlight sweeping across it, left to right. The highlight is a
/// gradient layer whose position animates; nothing is evaluated per frame.
public struct AmbientShimmer: NSViewRepresentable {
    var base: Color
    var highlight: Color
    var cornerRadius: CGFloat
    var period: TimeInterval

    public init(base: Color, highlight: Color, cornerRadius: CGFloat = 6, period: TimeInterval = 1.2) {
        self.base = base
        self.highlight = highlight
        self.cornerRadius = cornerRadius
        self.period = period
    }

    public func makeNSView(context: Context) -> AmbientShimmerView {
        AmbientShimmerView(cornerRadius: cornerRadius, period: period)
    }

    public func updateNSView(_ view: AmbientShimmerView, context: Context) {
        view.set(base: base.resolve(in: context.environment).cgColor,
                 highlight: highlight.resolve(in: context.environment).cgColor)
    }
}

public final class AmbientShimmerView: NSView {
    private let baseLayer = CALayer()
    private let sweep = CAGradientLayer()
    private let period: TimeInterval
    /// The width the running sweep was built for; a layout at the same width keeps it going.
    private var sweptWidth: CGFloat = -1

    init(cornerRadius: CGFloat, period: TimeInterval) {
        self.period = period
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(baseLayer)
        baseLayer.addSublayer(sweep)
        baseLayer.cornerRadius = cornerRadius
        baseLayer.masksToBounds = true
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func set(base: CGColor, highlight: CGColor) {
        baseLayer.backgroundColor = base
        let clear = highlight.copy(alpha: 0) ?? highlight
        sweep.colors = [clear, highlight, clear]
    }

    override public func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.frame = bounds
        sweep.bounds = CGRect(origin: .zero, size: bounds.size)
        sweep.position = CGPoint(x: -bounds.width / 2, y: bounds.midY)
        CATransaction.commit()
        if bounds.width != sweptWidth { restart() }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    private func restart() {
        sweptWidth = bounds.width
        sweep.removeAnimation(forKey: "sweep")
        guard window != nil, bounds.width > 0 else { return }
        let slide = CABasicAnimation(keyPath: "position.x")
        slide.fromValue = -bounds.width / 2
        slide.toValue = bounds.width * 1.5
        slide.duration = period
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .linear)
        sweep.add(AmbientMotion.capped(slide, rate: AmbientMotion.largeFrameRate), forKey: "sweep")
    }
}
