import AppKit
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
///
/// The division of labour: the bar says *what* should be visible and hands over the
/// numbers it measures; everything about *when and how* the row moves is here. That
/// matters more than it sounds, because a tab that isn't selected is a window that is
/// ordered out and SwiftUI stops updating the views inside one — so the bar of the tab
/// being switched *to* is not running at the moment its window takes focus. Anything that
/// had to be decided by the view at that moment would be decided by nobody.

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

/// Moves the row, and decides when to.
///
/// One of these per bar, which is one per window: a tab *is* a window in AppKit's tab
/// group, so a scope with fourteen tabs has fourteen rows to keep in step. Where they are
/// is shared (`CustomTabBarModel.rowOffset`); which one is on screen is whichever window
/// is key.
///
/// A class because the scroll view arrives after the view that wants it, because moving
/// the row is something done to AppKit rather than a value SwiftUI redraws from, and
/// because it has to keep working while the view that made it is not.
final class TabBarScroller {
    weak var scrollView: NSScrollView? {
        didSet {
            watchScrolls()

            // The scroll view and the window taking focus arrive from different
            // subsystems — this one from SwiftUI's next layout pass, the other from
            // AppKit — so neither can be assumed to come first. Both entry points do the
            // same thing, and whichever is last is the one that finds both halves in hand.
            guard scrollView?.window?.isKeyWindow == true else { return }
            cameForward()
        }
    }

    /// The scope this row belongs to: where it should stand (`rowOffset`) and what it
    /// should be showing (`scrollTarget`).
    weak var model: CustomTabBarModel?

    // MARK: What the bar measures

    /// Frames in bar coordinates, as the bar last published them.
    ///
    /// Held here rather than in the bar's `@State` for two reasons. The scroll needs to be
    /// able to look up *any* tab at any time — a preference only arrives when its value
    /// changes, so keeping just the selected tab's frame would leave nothing to aim by
    /// when the selection moved to a tab whose frame hadn't — and nothing about the row's
    /// appearance depends on these, so putting them in view state would redraw every bar
    /// on every pixel the tabs move.
    ///
    /// Assigning either is also how a pending move learns its number has arrived.
    var tabFrames: [ObjectIdentifier: CGRect] = [:] { didSet { fulfill() } }
    var sectionFrames: [UUID: CGRect] = [:] { didSet { fulfill() } }

    /// Whether a tab or group is being dragged.
    ///
    /// A drag positions the row itself, so nothing that aims at the selection may move it.
    /// The one thing that may is the drag reaching an edge — see `watchEdges`.
    var isDragging = false {
        didSet {
            guard isDragging != oldValue else { return }
            if isDragging {
                // The drag has the row now. Anything already moving it was aiming at the
                // selection, which is not what the user is doing.
                driver?.invalidate()
                driver = nil
                settleWork?.cancel()
                settleWork = nil
                pending = nil
                owner = .idle
            }
            watchEdges()
        }
    }

    /// How far the row moved itself under a drag, as it happens.
    ///
    /// A drag holds an item at a translation, and a translation is only recomputed when
    /// the pointer moves. Scrolling the row under a pointer that is holding still would
    /// leave the item pinned to the row and sliding away with it, so the row says how far
    /// it went and the drag adds that to what it is holding.
    var onDragScroll: ((CGFloat) -> Void)?

    // MARK: State

    /// Who the row belongs to right now.
    ///
    /// One value rather than a flag apiece for "animating", "where it's headed" and "the
    /// user has it". Those three are answers to the same question, and kept separately
    /// they drift: a completion runs at the time it was booked for, so a second scroll
    /// started before the first had landed used to be declared finished by its
    /// predecessor — leaving the row still driven by Core Animation while the code that
    /// hands it back to the trackpad believed there was nothing to hand back.
    private enum Owner {
        case idle
        case flying(token: Int, destination: CGFloat)
        case user
    }

    private var owner: Owner = .idle
    private var flights = 0

    /// The move the row owes, until it makes it. Nil means it owes none.
    ///
    /// One value, on the scroller. Split between the view and here — as "a reason" in
    /// `@State` and "came forward" in a flag — it was consumed only when SwiftUI happened
    /// to deliver a preference, so a request raised with the layout already settled waited
    /// for a republish that never came.
    private var pending: AlignReason?

    /// The second look, until it happens.
    private var settleWork: DispatchWorkItem?

    /// What is stepping the row, while it is moving.
    private var driver: Timer?

    /// What is watching the edges, while something is being dragged.
    private var edgeWatch: Timer?

    private var boundsObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var liveScrollObservers: [NSObjectProtocol] = []

    init() {
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let window = note.object as? NSWindow else { return }
            guard window === self.scrollView?.window else { return }
            self.cameForward()
        }
    }

    deinit {
        settleWork?.cancel()
        driver?.invalidate()
        edgeWatch?.invalidate()
        for observer in [keyObserver, boundsObserver].compactMap({ $0 }) + liveScrollObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: Asking

    /// This row is about to stand in for the one the user was looking at.
    ///
    /// It takes on where that row was left first — including wherever the user had dragged
    /// it to — and only then asks whether the selection needs bringing into sight. The
    /// other order measures against a row the user never saw.
    private func cameForward() {
        adoptSharedOffset()

        // Asking is held over to the next turn, because right now the model still
        // describes the tab being left: it rebuilds from the same notification this came
        // from, and coalesces that to the end of the runloop turn. Aiming immediately
        // would aim at the outgoing selection — usually harmless, since the row has just
        // arrived where that selection was visible, but not if the user had scrolled it
        // out of sight, and then the row would visit the old tab on its way to the new
        // one. The adopt above is the part that has to be immediate, and it is.
        DispatchQueue.main.async { [weak self] in self?.requestAlign(.key) }
    }

    /// Ask the row to move, and move it if everything it needs is in hand.
    ///
    /// If something is missing — no frame for the target yet, no scroll view — the request
    /// stays owed and the next thing to arrive settles it.
    func requestAlign(_ reason: AlignReason) {
        pending = reason
        fulfill()
    }

    private func fulfill() {
        guard let reason = pending else { return }
        guard !isDragging else { return }

        // Not while the user is holding the row. Their scroll is an instruction; ours is a
        // guess about what they'd want.
        if case .user = owner {
            pending = nil
            return
        }

        // Only the row in front. The others are copies that will take the scope's offset
        // when their turn comes, and positioning them now is both invisible and a lie — by
        // then the user may have dragged the row somewhere else entirely.
        guard scrollView?.window?.isKeyWindow == true else {
            pending = nil
            return
        }

        guard let target = model?.scrollTarget else { return }
        guard let frame = rect(of: target), let viewport = visibleRect else { return }

        pending = nil

        let delta: CGFloat
        if frame.maxX > viewport.maxX - Self.margin {
            delta = frame.maxX - viewport.maxX + Self.margin
        } else if frame.minX < viewport.minX + Self.margin {
            delta = frame.minX - viewport.minX - Self.margin
        } else {
            delta = 0
        }

        if delta != 0 { scroll(by: delta) }

        // Look again once the row has stopped rearranging itself. The row's layout settles
        // over several passes — a tab joins, the ones around it make room, its title
        // arrives and widens it — and the earliest pass, which is the one that gets the
        // row moving promptly, is also the least accurate. Answering a reason twice keeps
        // both: one selection's first move landed 160pt short of where the tab ended up.
        //
        // Only for a reason that was given, and only one at a time. Opening a tab is two
        // reasons at once — a new selection, and its window taking focus.
        if reason != .settle { scheduleSettle() }
    }

    private func scheduleSettle() {
        guard settleWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWork = nil
            self.requestAlign(.settle)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func rect(of target: TabBarScrollTarget) -> CGRect? {
        switch target {
        case .tab(let id): return tabFrames[id]
        case .section(let id): return sectionFrames[id]
        }
    }

    // MARK: Moving

    /// Put this row where the scope left it.
    ///
    /// Never animated. This isn't the row moving — it is a copy of the row arriving, and it
    /// has to arrive already where the one it replaces was standing.
    private func adoptSharedOffset() {
        guard let model, let scrollView else { return }
        let clip = scrollView.contentView
        let x = min(max(model.rowOffset, 0), furthest)
        guard abs(x - clip.bounds.origin.x) > 0.5 else { return }

        clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Shift the row, held to what there is to scroll.
    ///
    /// The clamp is why this is arithmetic and not a request: at the ends of the row a
    /// scroll view decides for itself what "into view" means, and the difference shows up
    /// as the row coming to rest somewhere unrelated.
    ///
    /// The movement is stepped here rather than handed to `animator()`. That proxy is the
    /// documented way to animate a clip view and it does nothing in this bar: SwiftUI's
    /// scroll view keeps its clip view non-layer-backed, so no animation is ever attached
    /// — the row arrives at the far end in one frame. Measured: `animationKeys()` empty,
    /// and the clip's bounds still at the old value after the animation group returns.
    private func scroll(by delta: CGFloat) {
        guard let scrollView else { return }

        let clip = scrollView.contentView
        let from = clip.bounds.origin.x
        let to = min(max(from + delta, 0), furthest)

        // Already on its way there. One thing happening — a tab coming forward — reaches
        // the row as both a window taking focus and a selection changing, and each asks for
        // the move. Restarting the animation on the second would make the row set off twice
        // for one journey.
        if case .flying(_, let destination) = owner, abs(destination - to) < 0.5 { return }
        guard abs(to - from) > 0.5 else { return }

        flights += 1
        let token = flights
        owner = .flying(token: token, destination: to)

        let span = Self.duration(forDistance: abs(to - from))
        let startedAt = CFAbsoluteTimeGetCurrent()
        driver?.invalidate()
        let driver = Timer(timeInterval: Self.frame, repeats: true) { [weak self] timer in
            guard let self, let scrollView = self.scrollView else { timer.invalidate(); return }

            // Someone else has the row now — a later flight, or the user. Whoever it is is
            // driving it, and two hands on the same row is the jitter this token exists to
            // prevent.
            guard case .flying(let inFlight, _) = self.owner, inFlight == token else {
                timer.invalidate()
                return
            }

            let progress = min(1, (CFAbsoluteTimeGetCurrent() - startedAt) / span)
            let clip = scrollView.contentView
            let x = from + (to - from) * CGFloat(Self.eased(progress))
            clip.setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)

            if progress >= 1 {
                timer.invalidate()
                self.driver = nil
                self.owner = .idle
            }
        }
        self.driver = driver
        // Common modes, so the row keeps moving through a menu tracking or a live resize
        // rather than freezing halfway.
        RunLoop.main.add(driver, forMode: .common)
    }

    /// How long a move of this length should take.
    ///
    /// Not one number for every distance. A row crossing its whole length in the time a
    /// neighbouring tab takes is not fast, it is a cut — there is nothing on screen long
    /// enough to follow, and the end of the journey is the first thing you see. Growing
    /// the time with the distance keeps the *speed* of the row roughly recognisable, and
    /// the cap keeps a long move from turning into something to wait for.
    private static func duration(forDistance distance: CGFloat) -> TimeInterval {
        let reach = min(1, Double(distance) / 800)
        return 0.14 + (0.32 - 0.14) * reach
    }

    /// Fast off the mark and easing into place — the row is answering something the user
    /// just did, so the response wants to be immediate and the arrival calm.
    private static func eased(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    // MARK: Dragging to the edge

    /// Carry the row while a drag is held against either end of it.
    ///
    /// A drag can only drop something where it can see, and the row is a window onto more
    /// than it shows — so without this, moving a tab to a group that is off the end is not
    /// something the user can do at all. Holding the pointer at the edge is the way that
    /// has always been asked for.
    ///
    /// Watched on a clock rather than driven by the drag's own updates. The gesture speaks
    /// only when the pointer moves, and a pointer held at the edge is exactly a pointer
    /// that has stopped moving — the moment this is most needed is the moment nothing
    /// would arrive.
    private func watchEdges() {
        edgeWatch?.invalidate()
        edgeWatch = nil
        guard isDragging else { return }

        let watch = Timer(timeInterval: Self.frame, repeats: true) { [weak self] timer in
            guard let self, self.isDragging else {
                timer.invalidate()
                return
            }
            self.carryEdge()
        }
        edgeWatch = watch
        RunLoop.main.add(watch, forMode: .common)
    }

    /// One tick of that carry: how far into an edge the pointer is, turned into a shift.
    private func carryEdge() {
        guard let scrollView, let window = scrollView.window, window.isKeyWindow else { return }

        let pointer = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let bounds = scrollView.bounds

        // A pointer that has left the bar is doing something else. Without this the row
        // keeps travelling under a drag the user has taken somewhere entirely else, and
        // comes back to a place they never chose.
        guard pointer.y > bounds.minY - Self.reach, pointer.y < bounds.maxY + Self.reach else {
            return
        }

        let depth: CGFloat
        let direction: CGFloat
        if pointer.x < bounds.minX + Self.edge {
            depth = (bounds.minX + Self.edge - max(pointer.x, bounds.minX)) / Self.edge
            direction = -1
        } else if pointer.x > bounds.maxX - Self.edge {
            depth = (min(pointer.x, bounds.maxX) - (bounds.maxX - Self.edge)) / Self.edge
            direction = 1
        } else {
            return
        }

        // Squared, so the edge has a slow lip rather than a step: the last part of the row
        // is somewhere the pointer passes through on its way to the end, and a drag that
        // breaks into a run the moment it gets there is one you cannot aim.
        let speed = Self.carrySpeed * depth * depth
        shift(by: direction * speed * Self.frame)
    }

    /// Move the row now, by hand, and say how far it actually went.
    private func shift(by delta: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        let from = clip.bounds.origin.x
        let to = min(max(from + delta, 0), furthest)
        guard abs(to - from) > 0.01 else { return }

        clip.setBoundsOrigin(NSPoint(x: to, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        onDragScroll?(to - from)
    }

    /// Give the row up.
    ///
    /// A moving row that ignores the trackpad is worse than one that never moved: where the
    /// bar thinks the row should be is a guess about what the user wants, and the user
    /// reaching for it is not a guess. So the scroll in flight stops where it has got to,
    /// the second look is called off, and anything owed is written off.
    ///
    /// Stopping is the whole of it now that the row is stepped here: drop the driver and
    /// the row is already where it last put it. Nothing else is holding the bounds.
    private func yieldToUser() {
        settleWork?.cancel()
        settleWork = nil
        pending = nil

        driver?.invalidate()
        driver = nil
        owner = .user
    }

    // MARK: Observing

    /// Keep the scope's idea of where the row is up to date with this one, and notice when
    /// the user takes it.
    ///
    /// Every way the row can move reports to the bounds observer — ours, the user's
    /// trackpad, AppKit revealing the first responder — which is what makes it the whole
    /// answer rather than a list of the movements we happened to think of. Only the bar in
    /// front writes: the others are copies being kept in step, and a copy reporting its own
    /// position would overwrite the scope's with one nobody asked for.
    private func watchScrolls() {
        for observer in liveScrollObservers { NotificationCenter.default.removeObserver(observer) }
        liveScrollObservers = []
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
            self.boundsObserver = nil
        }
        guard let scrollView else { return }
        let clip = scrollView.contentView

        // `willStart` is the earliest AppKit says the user has the row, which matters: by
        // `didLiveScroll` a frame of ours has already fought a frame of theirs.
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
            ) { [weak self] _ in
                guard let self, case .user = self.owner else { return }
                self.owner = .idle
            },
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

    // MARK: Geometry

    /// The part of the row on screen right now, in the row's own coordinates.
    ///
    /// Taken from the scroll view rather than measured in SwiftUI. It is the same fact
    /// either way, and this is the copy that is true at the moment it is asked — a measured
    /// one is only as fresh as the layout that produced it.
    private var visibleRect: CGRect? {
        guard let scrollView else { return nil }
        let rect = scrollView.documentVisibleRect
        return rect.width > 0 ? rect : nil
    }

    /// How far the row can be scrolled.
    private var furthest: CGFloat {
        guard let scrollView else { return 0 }
        let content = scrollView.documentView?.frame.width ?? 0
        return max(0, content - scrollView.contentView.bounds.width)
    }

    /// How often to step a moving row. A display's worth — anything finer is thrown away
    /// by the compositor, and anything coarser is visible as stepping.
    static let frame: TimeInterval = 1.0 / 60

    /// How near an end the pointer has to be for the row to start carrying a drag along.
    static let edge: CGFloat = 44

    /// How far outside the bar the pointer may stray and still be counted as dragging
    /// along it. Some slack, because a drag is held by hand and hands wander.
    static let reach: CGFloat = 40

    /// The fastest the row carries a drag, in points per second — reached only with the
    /// pointer pressed right up against the end.
    static let carrySpeed: CGFloat = 900

    /// How much of the row to leave beside a tab brought into sight, so it lands next to
    /// the edge rather than flush against it — which reads as clipped rather than as the
    /// end of the row.
    static let margin: CGFloat = 8

    /// How long to let the row rearrange itself before checking where the selection
    /// actually came to rest. Longer than the bar's own spring, which is what is still
    /// moving the tabs around while the first scroll is already under way.
    static let settleDelay: TimeInterval = 0.35
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
        }
    }
}
