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

    /// Whether a tab or group is being dragged. The drag positions the row itself, and
    /// scrolling under it would take what's being dragged out from under the pointer.
    var isDragging = false

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

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clip.animator().setBoundsOrigin(NSPoint(x: to, y: clip.bounds.origin.y))
        } completionHandler: { [weak self, weak scrollView] in
            // Only the flight this call started. By now the row may be on a later one, or
            // in the user's hands, and either way this completion has nothing to say.
            if let self, case .flying(let inFlight, _) = self.owner, inFlight == token {
                self.owner = .idle
            }
            guard let scrollView else { return }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Give the row up.
    ///
    /// A moving row that ignores the trackpad is worse than one that never moved: where the
    /// bar thinks the row should be is a guess about what the user wants, and the user
    /// reaching for it is not a guess. So the scroll in flight stops where it has got to,
    /// the second look is called off, and anything owed is written off.
    ///
    /// Stopping means replacing the animation with an instant one to where the row has
    /// actually reached. Just marking it over would leave Core Animation still driving the
    /// bounds, which is the very thing that was overriding the user.
    private func yieldToUser() {

        settleWork?.cancel()
        settleWork = nil
        pending = nil

        if isFlying, let clip = scrollView?.contentView {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clip.animator().setBoundsOrigin(clip.bounds.origin)
            }
        }
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

    private var isFlying: Bool {
        if case .flying = owner { return true }
        return false
    }


    static let duration: TimeInterval = 0.18

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
