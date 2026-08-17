import SwiftUI

/// The custom tab bar, drawn as a titlebar accessory below the titlebar.
///
/// This replaces only the *presentation* of the native tab bar. Every interaction
/// forwards through `CustomTabBarModel` to the native tab group.
struct CustomTabBarView: View {
    @ObservedObject var model: CustomTabBarModel

    /// Live reorder state for a group drag.
    @State private var groupDrag: GroupDragState?

    /// Live reorder state for a tab drag.
    @State private var tabDrag: TabDragState?

    /// Where each section sits, in bar coordinates.
    @State private var sectionFrames: [UUID: CGRect] = [:]

    /// Whether this bar has completed its first layout pass.
    @State private var hasDrawn = false

    /// The tabs this bar last drew, so a snapshot that adds or removes one can be told
    /// apart from one that merely rearranges or resizes what's already there.
    @State private var drawnTabIDs: Set<ObjectIdentifier> = []

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.sectionSpacing) {
                ForEach(displaySections) { section in
                    CustomTabSectionView(
                        section: section,
                        model: model,
                        groupDrag: $groupDrag,
                        tabDrag: $tabDrag,
                        sectionFrames: $sectionFrames)
                }

                NewGroupButton { model.createEmptyGroup() }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(SectionFramePreference.self) { sectionFrames = $0 }
            // Not animated until this bar has drawn once.
            //
            // Every tab is a window and every window builds its own bar, so the bar you
            // see after opening or switching tabs is a brand-new view. To it, *all* the
            // tabs are appearing for the first time — so without this the whole row
            // animates in on every tab switch, including tabs and groups that had
            // nothing to do with it.
            // Animates on the whole snapshot, titles included: a tab's width follows its
            // title, and the title arrives a moment after the tab does, so this is what
            // makes that widening a movement instead of a snap.
            .animation(animation, value: model.sections)
            .onAppear {
                drawnTabIDs = currentTabIDs
                DispatchQueue.main.async { hasDrawn = true }
            }
            .onChange(of: currentTabIDs) { drawnTabIDs = $0 }
        }
        .frame(height: Self.height)
    }

    private var currentTabIDs: Set<ObjectIdentifier> {
        Set(model.sections.lazy.flatMap(\.tabs).map(\.id))
    }

    /// How to get from the drawn snapshot to this one.
    ///
    /// Adding or removing a tab settles without overshoot. A tab arrives over several
    /// snapshots — it joins the window list, takes focus, lands in its group, then gets
    /// its title — and opening tabs faster than a spring settles restarts the animation
    /// from wherever the row happens to be. A spring that overshoots is somewhere past
    /// its target when that happens, so the restart reads as the bar jumping; a
    /// critically damped one is always between where it was and where it's going.
    ///
    /// Everything else — reordering, switching groups, a title arriving and widening its
    /// tab — moves the same tabs around at a pace the user controls, so it keeps the
    /// livelier spring.
    private var animation: Animation? {
        guard hasDrawn else { return nil }
        guard currentTabIDs == drawnTabIDs else {
            return .spring(response: 0.18, dampingFraction: 1)
        }
        return .spring(response: 0.25, dampingFraction: 0.85)
    }

    /// Sections in the order to draw them, which during a group drag is the dragged
    /// arrangement rather than the model's.
    private var displaySections: [CustomTabSection] {
        guard let order = groupDrag?.order else { return model.sections }
        return order.compactMap { id in model.sections.first { $0.id == id } }
    }

    /// Tall enough for the content it holds: a 24pt row, 3pt of section padding either
    /// side, 3pt of bar padding either side. Too short and the row is clipped, which
    /// looks like tabs going missing rather than like a sizing mistake.
    static let height: CGFloat = 36
    static let sectionSpacing: CGFloat = 3
    static let coordinateSpace = "CustomTabBar"
}

// MARK: - Drag State

/// The geometry of a row of draggable items, captured once when a drag begins.
///
/// Everything positional during a drag is answered from this snapshot, never from live
/// frames: live frames are mid-animation, and using them to decide a position that then
/// moves the frames is a feedback loop.
///
/// Items are *not* assumed to be the same width. Widths are recorded per item and slot
/// positions are a running sum over the current order, so two items of different widths
/// trading places gives the right answer — a slot's position depends on what's in front
/// of it, not on its index.
struct DragSlots<ID: Hashable> {
    let origin: CGFloat
    let spacing: CGFloat
    let widths: [ID: CGFloat]

    /// Where an item sits, given an order.
    func x(of id: ID, in order: [ID]) -> CGFloat {
        var x = origin
        for other in order {
            if other == id { return x }
            x += (widths[other] ?? 0) + spacing
        }
        return x
    }

    /// How wide the whole row is, for an order.
    func width(of order: [ID]) -> CGFloat {
        guard !order.isEmpty else { return 0 }
        return order.reduce(0) { $0 + (widths[$1] ?? 0) } + spacing * CGFloat(order.count - 1)
    }

    /// A translation held to what the row can actually contain.
    ///
    /// Without this the dragged item follows the pointer past either end and floats over
    /// the bar's padding — or off it entirely — while its slot stays put, which reads as
    /// the drag having come loose from the row.
    ///
    /// Only groups use this. A tab has to be able to leave its strip — that's how it
    /// gets dropped into another group — so holding it inside one would take the feature
    /// away rather than tidy it up.
    func clamp(_ translation: CGFloat, of id: ID, in order: [ID]) -> CGFloat {
        let start = x(of: id, in: order) - origin
        let lower = -start
        let upper = max(width(of: order) - (widths[id] ?? 0) - start, lower)
        return min(max(translation, lower), upper)
    }

    /// The slot a dragged item has moved into.
    ///
    /// Judged on the dragged item, not the pointer. The pointer is wherever the item was
    /// grabbed — for a group that's its header, near the left edge of something as wide
    /// as all its tabs — so asking where the *pointer* is means the item has to travel
    /// its own width past a neighbour before the swap registers.
    ///
    /// The edge that does the testing depends on which way the item is going: its
    /// leading edge when moving left, its trailing edge when moving right. Testing the
    /// item's *center* instead only works while everything is about the same width. The
    /// a group holding many tabs is far wider than one holding a single tab, and its
    /// center can't reach the other's without the item leaving the row entirely — so
    /// with the row clamped, a wide group simply could never be moved in front of a
    /// narrow one.
    ///
    /// Counting how many other items the edge has passed is monotonic in the item's
    /// position, so the target can't flip back and forth while it holds still.
    func insertionIndex(
        of id: ID,
        in order: [ID],
        startOrder: [ID],
        translation: CGFloat
    ) -> Int {
        let width = widths[id] ?? 0
        let current = x(of: id, in: startOrder) + translation
        let edge = current < x(of: id, in: order) ? current : current + width

        var x = origin
        var passed = 0
        for other in order {
            let otherWidth = widths[other] ?? 0
            if other != id, x + otherWidth / 2 < edge { passed += 1 }
            x += otherWidth + spacing
        }

        return min(max(passed, 0), max(order.count - 1, 0))
    }
}

/// An in-progress group drag.
///
/// The reorder happens here and reaches AppKit only on release: reordering windows on
/// every mouse move round-trips through the tab group and comes back as a fresh
/// snapshot, which is both expensive and visually unstable.
struct GroupDragState {
    let id: UUID
    let slots: DragSlots<UUID>
    let startOrder: [UUID]

    var translation: CGFloat = 0
    var order: [UUID]

    /// `translation`, held inside the row. See `DragSlots.clamp`.
    var clampedTranslation: CGFloat {
        slots.clamp(translation, of: id, in: startOrder)
    }

    /// How far to shift the dragged item so it stays under the pointer once the items
    /// around it have moved.
    var correction: CGFloat {
        slots.x(of: id, in: startOrder) - slots.x(of: id, in: order)
    }
}

/// An in-progress tab drag.
struct TabDragState {
    /// Which drag this is, as opposed to which tab it is dragging.
    ///
    /// Letting go starts an animation that owns the state until it lands, so cleanup is
    /// scheduled for later. By then the same tab may have been grabbed again, and a
    /// cleanup that recognizes its drag by the tab would end that one instead. The token
    /// says "the drag I started", which is the thing it actually has the right to end.
    let token = UUID()

    let id: ObjectIdentifier
    let sectionID: UUID
    let slots: DragSlots<ObjectIdentifier>
    let startOrder: [ObjectIdentifier]

    var translation: CGFloat = 0
    var order: [ObjectIdentifier]

    /// Another section the pointer has been dragged onto.
    var crossingTo: UUID?

    /// Let go of, and now gliding into its slot. Still drawn, but no longer the
    /// gesture's — a new grab on the same tab starts a fresh drag rather than
    /// continuing this one.
    var isSettling = false

    /// Where the tab sat when the drag began, relative to the strip. A constant — the
    /// dragged tab is drawn outside the flow, so its position never has to account for
    /// the items it has passed.
    var startX: CGFloat {
        slots.x(of: id, in: startOrder) - slots.origin
    }
}

/// Collects section frames so group drags and cross-group drops can tell what they're
/// over.
private struct SectionFramePreference: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Collects tab frames, read once at the start of a tab drag to learn each tab's width.
private struct TabFramePreference: PreferenceKey {
    static var defaultValue: [ObjectIdentifier: CGRect] = [:]

    static func reduce(
        value: inout [ObjectIdentifier: CGRect],
        nextValue: () -> [ObjectIdentifier: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Section

/// One group's tabs, with its header. The default section renders the same way.
private struct CustomTabSectionView: View {
    let section: CustomTabSection
    let model: CustomTabBarModel
    @Binding var groupDrag: GroupDragState?
    @Binding var tabDrag: TabDragState?
    @Binding var sectionFrames: [UUID: CGRect]

    var body: some View {
        HStack(spacing: 4) {
            CustomTabGroupHeaderView(
                section: section,
                model: model,
                groupDrag: $groupDrag,
                sectionFrames: $sectionFrames)

            // Every group shows its tabs. The active one is lit and is what tab actions
            // apply to; the rest are there to be seen and clicked into.
            if !section.tabs.isEmpty {
                CustomTabStripView(
                    section: section,
                    model: model,
                    tabDrag: $tabDrag,
                    sectionFrames: $sectionFrames)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(groupBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(dropHighlight, lineWidth: 2)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SectionFramePreference.self,
                    value: [section.id: proxy.frame(in: .named(CustomTabBarView.coordinateSpace))])
            }
        )
        // The drag moves the whole cluster, not just the label the pointer is on. A
        // group is its header *and* its tabs — dragging the header alone slid it out
        // from over its own tabs and left them behind in the old position.
        .offset(x: dragOffset)
        .transaction { transaction in
            if isDragging { transaction.animation = nil }
        }
        .zIndex(isDragging ? 1 : 0)
        .opacity(isDragging ? 0.9 : 1)
    }

    private var isDragging: Bool { groupDrag?.id == section.id }

    private var dragOffset: CGFloat {
        guard let groupDrag, isDragging else { return 0 }
        return groupDrag.clampedTranslation + groupDrag.correction
    }

    /// A wash behind the whole cluster, so a group reads as one thing even when its
    /// tabs are individually colored. Inactive groups sit back.
    private var groupBackground: Color {
        guard let color = section.color.displayColor else {
            return Color.primary.opacity(section.isActive ? 0.06 : 0.02)
        }
        return Color(nsColor: color).opacity(section.isActive ? 0.14 : 0.06)
    }

    /// Lights up when a tab from another group is hovering here.
    private var dropHighlight: Color {
        tabDrag?.crossingTo == section.id ? Color.accentColor : .clear
    }
}

// MARK: - Group Header

/// The group's label, which doubles as the switcher: clicking it returns to the tab
/// last used in that group.
private struct CustomTabGroupHeaderView: View {
    let section: CustomTabSection
    let model: CustomTabBarModel
    @Binding var groupDrag: GroupDragState?
    @Binding var sectionFrames: [UUID: CGRect]

    /// Whether this header is the one under the pointer for the gesture in flight.
    ///
    /// A gesture that is cancelled rather than completed — which is what opening a
    /// context menu does to every other one — still delivers `onEnded`, and with no
    /// movement to show for it. Without knowing the press landed here, that arrives
    /// looking exactly like a click and selects a group the user never touched.
    @State private var pressing = false

    var body: some View {
        HStack(spacing: 5) {
            Text(section.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)

            // How many tabs the section holds, drawn whether or not it is the active one.
            //
            // Showing it only on the inactive ones meant adding and removing it in the
            // same frame as the section resized around it, and the two animate on their
            // own terms: the count landed at its final position immediately while the
            // header was still growing, so it came away from the name it belongs to.
            if !section.tabs.isEmpty {
                Text("\(section.tabs.count)")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.6)
            }
        }
        .padding(.horizontal, 8)
        // Same height as a tab. A shorter header makes the section — and so the whole
        // bar — change height when a group expands, which shows up as a twitch on every
        // group switch.
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(labelBackground)
        )
        .foregroundStyle(section.isActive ? .primary : .secondary)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .overlay(CustomTabContextMenuHost(subject: .group(section), model: model))
    }

    // MARK: Dragging

    private var isDragging: Bool { groupDrag?.id == section.id }

    /// One gesture handles both click and drag.
    ///
    /// A separate `onTapGesture` alongside a `DragGesture` makes SwiftUI arbitrate
    /// between them and clicks get eaten. Recognizing from zero distance and deciding at
    /// the end on how far the pointer actually moved removes the ambiguity.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CustomTabBarView.coordinateSpace))
            .onChanged { value in
                pressing = true

                // The default section is a fixed anchor: it has no id to reorder by.
                guard section.group != nil else { return }
                guard abs(value.translation.width) > Self.threshold || isDragging else { return }

                // A gesture that was interrupted rather than ended leaves its state
                // behind, and a new drag would then be ignored as someone else's.
                if !isDragging, groupDrag != nil, value.translation == .zero { groupDrag = nil }

                if groupDrag == nil {
                    let order = model.sections.map(\.id)
                    groupDrag = GroupDragState(
                        id: section.id,
                        slots: DragSlots(
                            origin: order.first.flatMap { sectionFrames[$0]?.minX } ?? 0,
                            spacing: CustomTabBarView.sectionSpacing,
                            widths: sectionFrames.mapValues(\.width)),
                        startOrder: order,
                        order: order)
                }
                guard isDragging else { return }

                groupDrag?.translation = value.translation.width
                reorderIfNeeded()
            }
            .onEnded { value in
                let wasPressed = pressing
                pressing = false

                guard isDragging, let group = section.group else {
                    // Never became a drag, so it was a click — if the press was ours.
                    if wasPressed, abs(value.translation.width) <= Self.threshold {
                        model.selectGroup(section.group?.id)
                    }
                    return
                }
                commit(group: group.id)
            }
    }

    private func reorderIfNeeded() {
        guard let drag = groupDrag else { return }
        var order = drag.order
        guard let from = order.firstIndex(of: section.id) else { return }

        // The default section stays put at the head, so slot 0 isn't a target.
        let to = max(drag.slots.insertionIndex(
            of: section.id,
            in: order,
            startOrder: drag.startOrder,
            translation: drag.clampedTranslation), 1)
        guard to != from, order.indices.contains(to) else { return }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            order.remove(at: from)
            order.insert(section.id, at: to)
            groupDrag?.order = order
        }
    }

    private func commit(group: UUID) {
        guard let order = groupDrag?.order else { return }

        // Commit before clearing, for the same reason as tabs: clearing first hands the
        // bar back to the model's old order for a frame.
        if let index = order.firstIndex(of: section.id) {
            // Express the new position as "before the section that follows it", which
            // is what the registry's move takes. Landing last means before nothing.
            let next = order.indices.contains(index + 1) ? order[index + 1] : nil
            model.moveGroup(group, before: next == CustomTabSection.defaultID ? nil : next)
        }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            groupDrag = nil
        }
    }

    private static let threshold: CGFloat = 4

    private var labelBackground: Color {
        guard let color = section.color.displayColor else {
            return Color.primary.opacity(section.isActive ? 0.14 : 0.06)
        }
        return Color(nsColor: color).opacity(section.isActive ? 0.55 : 0.25)
    }
}

// MARK: - Tab Strip

/// The active group's tabs.
///
/// Tabs keep their natural widths. The drag copes with that by snapshotting each tab's
/// width when the drag starts and summing them for slot positions, rather than assuming
/// every slot is the same size — which is what made dragging a wide tab past a narrow
/// one drift.
struct CustomTabStripView: View {
    let section: CustomTabSection
    let model: CustomTabBarModel
    @Binding var tabDrag: TabDragState?
    @Binding var sectionFrames: [UUID: CGRect]

    /// Tab frames, in bar coordinates. Read only when a drag begins.
    @State private var tabFrames: [ObjectIdentifier: CGRect] = [:]

    /// The tab the gesture in flight actually pressed. See the group header's copy.
    @State private var pressing: ObjectIdentifier?

    static let spacing: CGFloat = 4

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(displayTabs) { tab in
                CustomTabView(tab: tab, model: model)
                    // The dragged tab is drawn in the overlay below. It stays here,
                    // invisible, to hold its slot — swapping it for a different view
                    // would change the view's identity and cancel the very gesture
                    // that's driving the drag.
                    .opacity(isDragging(tab.id) ? 0 : 1)
                    .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: TabFramePreference.self,
                            value: [tab.id: proxy.frame(
                                in: .named(CustomTabBarView.coordinateSpace))])
                    }
                )
                .gesture(gesture(for: tab))
                // A new tab grows into its place instead of appearing at full size and
                // shoving its neighbours sideways.
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.8, anchor: .leading).combined(with: .opacity),
                    removal: .opacity))
            }
        }
        .onPreferenceChange(TabFramePreference.self) { tabFrames = $0 }
        .overlay(alignment: .leading) { draggedTab }
    }

    /// The tab being dragged, drawn outside the flow at a position that follows the
    /// pointer directly.
    ///
    /// Keeping it *in* the flow means correcting its offset by the width of every tab it
    /// passes, and any difference between the recorded width and the real one is added
    /// again at each crossing. The error is invisible for one step and accumulates over
    /// several — which is exactly when the drift showed. Out of the flow there is no
    /// correction to accumulate: its position is its starting point plus how far the
    /// pointer has moved, and nothing else.
    @ViewBuilder
    private var draggedTab: some View {
        if let tabDrag, tabDrag.sectionID == section.id,
           let tab = section.tabs.first(where: { $0.id == tabDrag.id }) {
            CustomTabView(tab: tab, model: model)
                .frame(width: draggedWidth)
                .offset(x: tabDrag.startX + tabDrag.translation)
                .shadow(radius: 6)
                .allowsHitTesting(false)
        }
    }

    private func isDragging(_ id: ObjectIdentifier) -> Bool {
        tabDrag?.id == id && tabDrag?.sectionID == section.id
    }

    private var draggedWidth: CGFloat {
        guard let tabDrag else { return 0 }
        return tabDrag.slots.widths[tabDrag.id] ?? 0
    }

    private var displayTabs: [CustomTabItem] {
        guard let order = tabDrag?.order, tabDrag?.sectionID == section.id else {
            return section.tabs
        }
        return order.compactMap { id in section.tabs.first { $0.id == id } }
    }

    // MARK: Dragging

    private func gesture(for tab: CustomTabItem) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(CustomTabBarView.coordinateSpace))
            .onChanged { value in
                pressing = tab.id

                // A drag that has been let go is still on screen until it lands, but it
                // is over: treating it as this gesture's would reuse slot geometry
                // measured before the last move was committed.
                if let settling = tabDrag, settling.isSettling, settling.id == tab.id {
                    tabDrag = nil
                }

                let isDragging = tabDrag?.id == tab.id
                guard abs(value.translation.width) > Self.threshold || isDragging else { return }

                if !isDragging, tabDrag != nil, value.translation == .zero { tabDrag = nil }

                if tabDrag == nil {
                    let order = section.tabs.map(\.id)
                    tabDrag = TabDragState(
                        id: tab.id,
                        sectionID: section.id,
                        slots: DragSlots(
                            origin: order.first.flatMap { tabFrames[$0]?.minX } ?? 0,
                            spacing: Self.spacing,
                            widths: tabFrames.mapValues(\.width)),
                        startOrder: order,
                        order: order)
                }
                guard tabDrag?.id == tab.id else { return }

                tabDrag?.translation = value.translation.width
                tabDrag?.crossingTo = crossedSection()
                reorderIfNeeded(tab)
            }
            .onEnded { value in
                let wasPressed = pressing == tab.id
                pressing = nil

                guard tabDrag?.id == tab.id else {
                    if wasPressed, abs(value.translation.width) <= Self.threshold {
                        model.select(tab.id)
                    }
                    return
                }
                commit(tab)
            }
    }

    /// Another section the dragged tab has moved onto.
    ///
    /// Read off the tab, not the pointer, for the same reason the reorder is: the
    /// pointer is wherever the tab was grabbed. Grab one near its left edge and the
    /// pointer leaves the section while most of the tab is still inside it — which a
    /// quick drag then commits as a group change the user never asked for.
    ///
    /// Reordering inside a group must never be read as leaving it, so this only answers
    /// once the tab's center is outside this section entirely.
    private func crossedSection() -> UUID? {
        guard let drag = tabDrag else { return nil }

        let center = drag.slots.x(of: drag.id, in: drag.startOrder)
            + drag.translation
            + (drag.slots.widths[drag.id] ?? 0) / 2

        // Horizontal only. The bar is a single row, so a vertical test says nothing
        // except that the pointer wandered off the titlebar.
        if let own = sectionFrames[section.id], (own.minX...own.maxX).contains(center) {
            return nil
        }

        return sectionFrames.first { id, frame in
            id != section.id && (frame.minX...frame.maxX).contains(center)
        }?.key
    }

    private func reorderIfNeeded(_ tab: CustomTabItem) {
        guard let drag = tabDrag else { return }
        var order = drag.order
        guard let from = order.firstIndex(of: tab.id) else { return }

        let to = drag.slots.insertionIndex(
            of: tab.id,
            in: order,
            startOrder: drag.startOrder,
            translation: drag.translation)
        guard to != from, order.indices.contains(to) else { return }

        // Critically damped so the tabs being pushed aside don't overshoot. If they do,
        // letting go mid-flight drops the dragged tab into a slot that is momentarily
        // past where it will end up, and it has to come back — the small jolt on release.
        withAnimation(Self.settle) {
            order.remove(at: from)
            order.insert(tab.id, at: to)
            tabDrag?.order = order
        }
    }

    private func commit(_ tab: CustomTabItem) {
        guard let drag = tabDrag else { return }

        // Tell the model *before* dropping the drag state, not after. Clearing first
        // leaves a frame where the bar has gone back to reading the model's old order
        // while the model hasn't been told yet, so the tab flicks back to where it
        // started and then forward again.
        if let crossing = drag.crossingTo {
            // Dropped on another group: joining it is the whole intent, and assignment
            // already places the tab beside its new siblings.
            //
            // No glide here — the destination is a different strip whose geometry this
            // one never measured, so there's no slot to aim at. The tab arriving in
            // another group is the change worth seeing anyway.
            let group = model.sections.first { $0.id == crossing }?.group
            model.assign(tab.id, to: group?.id)
            withAnimation(Self.settle) { tabDrag = nil }
            return
        }

        if let index = drag.order.firstIndex(of: tab.id) {
            if drag.order.indices.contains(index + 1) {
                model.moveTab(tab.id, before: drag.order[index + 1])
            } else if index > 0 {
                model.moveTab(tab.id, after: drag.order[index - 1])
            }
        }

        // Glide into the slot rather than vanishing from wherever the pointer left it.
        //
        // Dropping the drag state is what puts the tab back in the flow, and doing it
        // straight away teleports the tab from under the pointer to its slot. So the
        // floating copy is animated to exactly where the in-flow one is waiting, and
        // only then handed over — at which point the swap has nothing to show.
        let resting = drag.slots.x(of: tab.id, in: drag.order) - drag.slots.origin - drag.startX
        withAnimation(Self.settle) {
            tabDrag?.translation = resting
            tabDrag?.isSettling = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) {
            // Only the drag this call let go of. Grabbing the same tab again before the
            // glide finishes starts a new one, and ending that by tab identity would
            // clear a drag still under the pointer.
            guard tabDrag?.token == drag.token else { return }
            tabDrag = nil
        }
    }

    private static let threshold: CGFloat = 4

    /// Movement the user isn't driving directly: settling into a slot, and the tabs
    /// making room. Critically damped — anything that overshoots has to come back, and
    /// coming back is what reads as a jolt.
    private static let settleDuration: TimeInterval = 0.22
    private static let settle: Animation = .spring(response: settleDuration, dampingFraction: 1)
}

// MARK: - Tab

/// A single tab.
private struct CustomTabView: View {
    let tab: CustomTabItem
    let model: CustomTabBarModel

    @State private var isHovering: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(.system(size: 12))

            // One slot for two things that are never wanted at once: the close button
            // while the pointer is here, and otherwise a pulse while the shell is
            // working. The slot always holds its place, so neither hovering a tab nor a
            // command starting in it resizes the tab and shoves its neighbours around.
            Button {
                model.close(tab.id)
            } label: {
                ZStack {
                    if tab.isBusy {
                        BusyIndicator()
                            .opacity(isHovering ? 0 : 1)
                    }

                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(isHovering ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 12)
            .allowsHitTesting(isHovering)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 24)
        // Sized by its title, like a group header, and capped so one long title can't
        // push the rest of the bar out of view.
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(border, lineWidth: 1)
        )
        .foregroundStyle(tab.isSelected ? .primary : .secondary)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .overlay(CustomTabContextMenuHost(subject: .tab(tab), model: model))
    }

    /// The assigned tab color, if any. Uncolored tabs fall back to a neutral gray so
    /// the two cases share one set of opacities.
    private var tint: Color {
        guard let displayColor = tab.color.displayColor else { return .primary }
        return Color(nsColor: displayColor)
    }

    /// Fill the whole tab rather than marking it with a dot. Opacity carries the
    /// selection state, so a colored tab still reads as selected or not.
    private var background: Color {
        if tab.isSelected {
            return tint.opacity(tab.color == .none ? 0.16 : 0.45)
        } else if isHovering {
            return tint.opacity(tab.color == .none ? 0.08 : 0.30)
        } else {
            return tint.opacity(tab.color == .none ? 0.0 : 0.18)
        }
    }

    /// Selected colored tabs get an outline too. Fill opacity alone doesn't separate
    /// them well enough from a hovered neighbor of the same color.
    private var border: Color {
        guard tab.isSelected, tab.color != .none else { return .clear }
        return tint.opacity(0.9)
    }
}

/// A dot that breathes while a tab's shell is working.
///
/// Its own view so the repeating animation belongs to something that exists only while
/// the shell is busy. Driven from `onAppear` rather than from the busy flag: the flag
/// changes in the same snapshot as everything else the bar redraws, and an animation
/// started from there is swept up by the bar's own — the dot ends up following the
/// spring the tabs move on instead of pulsing.
private struct BusyIndicator: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .frame(width: 5, height: 5)
            .opacity(dim ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}

// MARK: - New Group

private struct NewGroupButton: View {
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(isHovering ? 0.12 : 0.04))
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { isHovering = $0 }
        .help("New Group")
    }
}

// MARK: - Context Menu

/// Puts the AppKit context menu on a tab or group header.
///
/// SwiftUI's `.contextMenu` can't reproduce the native tab menu — it has no way to put
/// the color swatch grid inside a menu item — and it installs a gesture that competes
/// with the drag gesture and eats clicks. So we hand AppKit a real `NSMenu` instead,
/// which needs a real view to hang it on.
///
/// The view is an *overlay* rather than a background: behind the tab it never sees the
/// mouse. Being on top would normally eat the left-clicks that select a tab, so it
/// hit-tests only while a right-mouse event is being dispatched and is transparent to
/// everything else.
private struct CustomTabContextMenuHost: NSViewRepresentable {
    enum Subject {
        case tab(CustomTabItem)
        case group(CustomTabSection)
    }

    let subject: Subject
    let model: CustomTabBarModel

    func makeNSView(context: Context) -> NSView {
        let view = MenuHostView()
        view.configure(subject: subject, model: model)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MenuHostView)?.configure(subject: subject, model: model)
    }

    class MenuHostView: NSView {
        private var subject: Subject?
        private weak var model: CustomTabBarModel?

        func configure(subject: Subject, model: CustomTabBarModel) {
            self.subject = subject
            self.model = model
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                // Invisible to left clicks, hovers and drags — those belong to SwiftUI.
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let menu = buildMenu() else {
                super.rightMouseDown(with: event)
                return
            }

            menu.popUp(positioning: nil, at: convert(event.locationInWindow, from: nil), in: self)
        }

        private func buildMenu() -> NSMenu? {
            guard let subject, let model else { return nil }

            switch subject {
            case .tab(let tab):
                guard let window = model.window(for: tab.id) else { return nil }
                return CustomTabContextMenu.menu(for: window, model: model, tab: tab)
            case .group(let section):
                return CustomTabContextMenu.groupMenu(for: section, model: model)
            }
        }
    }
}
