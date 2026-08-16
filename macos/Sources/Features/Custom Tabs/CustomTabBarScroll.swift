import AppKit
import OSLog
import SwiftUI

/// Keeping the bar's selection in sight.
///
/// The bar is one row that scrolls, and enough tabs or groups put the selected one past
/// the end of it. What the row should do about that is narrow: move the least it takes to
/// bring the selection into sight, and not move at all when it is already there.
///
/// That rule is arithmetic on two rectangles, so it is done in the open rather than asked
/// of `ScrollViewProxy`. `scrollTo(_:anchor:)` decides for itself whether a view was
/// already visible, where it comes to rest, and what an identity it doesn't recognise
/// means — and each of those answers is something other than what a tab bar wants.
///
/// The bar aims by the frames it already collects for dragging — `TabFramePreference` and
/// `SectionFramePreference` — which are measured in the bar's own coordinate space. That
/// space is the row's contents, which is what `NSScrollView` calls document coordinates,
/// so a tab's frame and `documentVisibleRect` are directly comparable.
///
/// Screen coordinates would seem the neutral choice between SwiftUI and AppKit and are
/// not: a `GeometryReader` recomputes on layout, and a global frame read before the view
/// has a window is zero and stays zero, because nothing about the layout changed when the
/// window arrived.

// MARK: - Target

/// The one thing the bar should be showing.
///
/// A tab most of the time. A group held open with nothing in it has no tab to select, so
/// its header stands in — the group is somewhere the user has gone, and the header is all
/// there is of it to bring into sight.
enum TabBarScrollTarget: Equatable {
    case tab(ObjectIdentifier)
    case section(UUID)
}

/// Why the row is being asked to move. A closed set — there are three things that ask.
enum AlignReason: String {
    /// The selection landed somewhere new.
    case selection
    /// This bar came forward and hasn't been checked against the selection since.
    case key
    /// The second look, once the row's layout has stopped rearranging itself.
    case settle
}

// MARK: - Scroller

/// Moves the row by a measured amount.
///
/// Held by the bar and handed the scroll view once there is one. A class because the
/// scroll view arrives after the view that wants it, and because moving the row is
/// something done to AppKit rather than a value SwiftUI redraws from.
final class TabBarScroller {
    weak var scrollView: NSScrollView? {
        didSet {
            watchScrolls()

            // The scroll view and the window taking focus arrive from different
            // subsystems — this one from SwiftUI's next layout pass, the other from
            // AppKit — so neither can be assumed to come first. Both entry points do the
            // same thing, and whichever is last is the one that finds both halves in
            // hand. Without this, a bar whose scroll view landed after its window became
            // key would sit out the `guard window === scrollView?.window` in the observer
            // below and never take the scope's offset.
            guard scrollView?.window?.isKeyWindow == true else { return }
            adoptSharedOffset()
            wantsAlign = true
        }
    }

    /// The scope whose row offset this one shares. See `CustomTabBarModel.rowOffset`.
    weak var model: CustomTabBarModel?

    /// Which row this is, so a log covering every window's bar can be read apart.
    let id = String(UUID().uuidString.prefix(4))

    /// Tab frames in bar coordinates, as the strips last published them.
    ///
    /// Held here rather than in the bar's `@State` on purpose. The scroll needs to be able
    /// to look up *any* tab at any time — a preference only arrives when its value changes,
    /// so a bar that kept only the selected tab's frame would have nothing to aim by when
    /// the selection moved to a tab whose frame hadn't — but nothing about the row's
    /// appearance depends on these, and putting them in view state would redraw every bar
    /// on every pixel the tabs move.
    var tabFrames: [ObjectIdentifier: CGRect] = [:]

    private var boundsObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var liveScrollObservers: [NSObjectProtocol] = []

    /// Where the scroll in flight is headed, and which flight that is.
    ///
    /// A completion runs at the time it was booked for, not when its animation is still
    /// the current one — so a second scroll started before the first has landed would
    /// otherwise be declared finished by its predecessor's completion. What follows from
    /// that is not cosmetic: `yieldToUser` checks `isAnimating` before taking the row
    /// back, so a row still being driven by Core Animation would go on fighting the
    /// trackpad, which is the one thing that flag exists to prevent.
    private var destination: CGFloat?
    private var flight = 0

    /// Whether the user has their hand on the row right now.
    private(set) var isUserScrolling = false

    /// Bumped whenever the user takes the row over.
    ///
    /// Work scheduled for later — the second look at where the selection came to rest —
    /// carries the value it was booked under, so a hand that arrives in between can be
    /// told from one that never came. Without it the correction lands half a second after
    /// the user has scrolled somewhere and drags the row back off it.
    private(set) var generation = 0

    /// Give the row up. The scroll in flight stops where it has got to, and nothing
    /// booked under the old generation will run.
    ///
    /// A moving row that ignores the trackpad is worse than one that never moved: the
    /// bar's own idea of where to be is a guess about what the user wants, and the user
    /// reaching for it is not a guess.
    func yieldToUser() {
        generation += 1
        isUserScrolling = true
        destination = nil
        // Ends the flight as well as the animation, so the completion still due for it
        // can't come back and declare the row idle after the user has taken it.
        flight += 1

        TabBarScrollLog.log("[\(id)] user took the row (was\(isAnimating ? "" : " not") moving)")
        guard isAnimating, let clip = scrollView?.contentView else { return }
        isAnimating = false

        // Replacing the animation with an instant one to where the row has actually got
        // to. Simply clearing the flag would leave Core Animation still driving the
        // bounds, which is the very thing that was overriding the user.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            clip.animator().setBoundsOrigin(clip.bounds.origin)
        }
    }

    /// Set when this row came forward and hasn't been checked against the selection since.
    ///
    /// Read by the bar rather than pushed to it. A tab that isn't selected is a window
    /// that is ordered out, and SwiftUI stops updating the views inside one — so the bar
    /// of the tab being switched *to* is not running at the moment its window takes focus,
    /// and anything delivered to it then is delivered to nobody. What can be done in that
    /// moment is done here, in AppKit, which is always running; the rest waits in this
    /// flag for the bar to wake up and ask.
    private(set) var wantsAlign = false

    func alignHandled() { wantsAlign = false }

    init() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            guard window === self.scrollView?.window else { return }

            // The row arrives where the user left it before anything is drawn on top of
            // that — this is the whole of the jump they were seeing, and it is fixed
            // here rather than by any later correction.
            self.adoptSharedOffset()
            self.wantsAlign = true
        }
    }

    deinit {
        for observer in [keyObserver, boundsObserver].compactMap({ $0 }) + liveScrollObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Put this row where the scope left it.
    ///
    /// Never animated. This isn't the row moving — it is a copy of the row arriving, and
    /// it has to arrive already where the one it replaces was standing.
    func adoptSharedOffset() {
        guard let model, let scrollView else { return }
        let clip = scrollView.contentView
        let content = scrollView.documentView?.frame.width ?? 0
        let furthest = max(0, content - clip.bounds.width)
        let x = min(max(model.rowOffset, 0), furthest)
        guard abs(x - clip.bounds.origin.x) > 0.5 else { return }

        TabBarScrollLog.log(String(
            format: "[%@] adopt %.1f → %.1f", id, clip.bounds.origin.x, x))
        clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The part of the row on screen right now, in the row's own coordinates.
    ///
    /// Taken from the scroll view rather than measured in SwiftUI. It is the same fact
    /// either way, and this is the copy that is true at the moment it is asked — a
    /// measured one is only as fresh as the layout that produced it.
    var visibleRect: CGRect? {
        guard let scrollView else { return nil }
        let rect = scrollView.documentVisibleRect
        return rect.width > 0 ? rect : nil
    }

    /// Whether a scroll of this row is still in flight.
    ///
    /// While it is, the row is between where it was and where it is going, and every
    /// measurement of it says the selection isn't visible yet. Aiming again at that
    /// answer restarts the animation from wherever it had got to, over and over, which is
    /// the row juddering rather than moving.
    private(set) var isAnimating = false

    /// Shift the row, held to what there is to scroll.
    ///
    /// The clamp is why this is arithmetic and not a request: at the ends of the row a
    /// scroll view decides for itself what "into view" means, and the difference shows up
    /// as the row coming to rest somewhere unrelated.
    ///
    /// Returns what it actually did, for the log to report.
    @discardableResult
    func scroll(by delta: CGFloat) -> (from: CGFloat, to: CGFloat)? {
        guard let scrollView else { return nil }

        let clip = scrollView.contentView
        let content = scrollView.documentView?.frame.width ?? 0
        let furthest = max(0, content - clip.bounds.width)
        let from = clip.bounds.origin.x
        let to = min(max(from + delta, 0), furthest)

        // Already on its way there. One thing happening — a tab coming forward — reaches
        // the bar as both a window taking focus and a selection changing, and each asks
        // for the move. Restarting the animation on the second would make the row set off
        // twice for one journey.
        if isAnimating, let destination, abs(destination - to) < 0.5 { return nil }
        guard abs(to - from) > 0.5 else { return nil }
        destination = to

        let origin = NSPoint(x: to, y: clip.bounds.origin.y)
        isAnimating = true
        flight += 1
        let token = flight
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(origin)
        } completionHandler: { [weak self, weak scrollView] in
            // Only the flight this call started. By now the row may be on a later one, or
            // in the user's hands, and either way this completion has nothing to say
            // about it.
            if let self, token == self.flight {
                self.isAnimating = false
                self.destination = nil
            }
            guard let scrollView else { return }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        return (from, to)
    }

    /// Keep the scope's idea of where the row is up to date with this one.
    ///
    /// Every way the row can move reports here — ours, the user's trackpad, AppKit
    /// revealing the first responder — which is what makes this the whole answer rather
    /// than a list of the movements we happened to think of.
    ///
    /// Only the bar in front writes. The others are copies being kept in step, and a copy
    /// that reported its own position would overwrite the scope's with one nobody asked
    /// for.
    private func watchScrolls() {
        for observer in liveScrollObservers { NotificationCenter.default.removeObserver(observer) }
        liveScrollObservers = []
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        guard let scrollView else { return }
        let clip = scrollView.contentView

        // The user's hand on the row. `willStart` is the earliest AppKit says so, which
        // matters: by `didLiveScroll` a frame of ours has already fought a frame of theirs.
        liveScrollObservers = [
            NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in self?.yieldToUser() },
            NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in self?.isUserScrolling = false },
        ]
        clip.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            guard let self, let scrollView = self.scrollView else { return }
            guard scrollView.window?.isKeyWindow == true else { return }
            self.model?.rowOffset = scrollView.contentView.bounds.origin.x
        }
    }

    /// Where the row currently sits and how far it can go, for the log.
    var state: String {
        guard let scrollView else { return "scrollView=nil" }
        let clip = scrollView.contentView
        let content = scrollView.documentView?.frame.width ?? 0
        return String(
            format: "clipX=%.1f clipW=%.1f contentW=%.1f max=%.1f",
            clip.bounds.origin.x, clip.bounds.width, content, max(0, content - clip.bounds.width))
    }

    static let duration: TimeInterval = 0.18
}

/// Reaches the AppKit scroll view the bar is drawn in.
///
/// A view of its own placed in the row: `enclosingScrollView` is exactly the scroll view
/// that holds it, so nothing has to go looking through the window for one.
struct TabBarScrollViewBridge: NSViewRepresentable {
    let scroller: TabBarScroller
    let model: CustomTabBarModel

    func makeNSView(context: Context) -> NSView {
        BridgeView(scroller: scroller)
    }

    // The one place the scope is wired in. SwiftUI runs this immediately after
    // `makeNSView` and on every update after that, so a second copy in the initializer
    // bought nothing and left two places to keep in step.
    func updateNSView(_ nsView: NSView, context: Context) {
        scroller.model = model
    }

    private class BridgeView: NSView {
        private let scroller: TabBarScroller

        init(scroller: TabBarScroller) {
            self.scroller = scroller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scroller.scrollView = enclosingScrollView
            TabBarScrollLog.log("bridge: enclosingScrollView=\(enclosingScrollView.map { "\(type(of: $0))" } ?? "nil")")
        }
    }
}

// MARK: - Instrumentation

/// The running commentary of the scroll, off unless asked for.
///
/// The four attempts at this that came before were reasoned out of the source and never
/// run, and each was wrong in a way no further reading would have shown: which of the two
/// rectangles was off, whether the scroll view being driven was the row's, whether a frame
/// read during a layout is the one that settles. Those are numbers, and numbers have to be
/// watched.
///
/// Enabled with `GHOSTTY_TAB_BAR_SCROLL_DEBUG=1` in the environment.
enum TabBarScrollLog {
    static let isEnabled = ProcessInfo.processInfo.environment["GHOSTTY_TAB_BAR_SCROLL_DEBUG"] == "1"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "TabBarScroll"
    )

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = message()
        logger.debug("\(line, privacy: .public)")
        print("[tabbar-scroll] \(line)")
        fflush(stdout)
    }
}
