import ImogenKit
import ImogenSDK
import SwiftUI

/// The library, in one grid, however large it is.
///
/// The grid is built from the day index rather than from the photographs, so it is the
/// right length immediately and every cell has a fixed place from the first frame. Cells
/// whose day has not been fetched draw a plain rectangle; the day arrives and they fill
/// in. Nothing reflows, because nothing changes size.
///
/// That is what makes the scrubber honest. A grid that grows as pages arrive has a
/// scrollbar that means something different every second.
struct TimelineView: View {
    let session: Session
    @Bindable var store: TimelineStore
    let columns: Int
    var onAddToAlbum: ((AssetSelection) -> Void)?
    /// What an empty one says. The library's own emptiness and a filtered timeline's are
    /// different facts, and offering to turn on backup is only an answer to the first.
    var emptyTitle: String = "Your library is empty"
    var emptyBody: String = "Turn on backup, or add photographs from another device — "
        + "they will appear here, newest first."

    /// Photographs ticked one at a time.
    @State private var picked: Set<String> = []
    /// Photographs unticked from "everything", which is a different question: one is a
    /// list to send, the other is the filter minus a handful.
    @State private var unpicked: Set<String> = []
    @State private var selectingAll = false
    @State private var opened: TimelineTile?
    @State private var details: Asset?
    /// The count a by-query trash resolved to, and what puts its confirmation on screen.
    /// Set only once the server has been asked, so the question always names a number.
    @State private var trashCount: Int?
    /// The exclusions the count was resolved against, kept so that the confirmation and
    /// the deletion are the same set. The grid stays live during the round trip and a tap
    /// on a cell would otherwise move the goalposts between the question and the answer.
    @State private var trashExcept: Set<String> = []
    @State private var resolvingTrash = false
    /// Which resolve the screen is waiting on. Bumped when one starts and again whenever
    /// the selection is cleared, so a count that comes back for a selection nobody is
    /// waiting on any more cannot raise a dialog. The flag alone is not enough: clearing
    /// and selecting again turns it back on, and the abandoned round trip would then put
    /// its own exclusions behind a confirmation somebody never asked for.
    @State private var trashRequest = 0
    /// The day at the top of the viewport, which is what the thumb draws itself against.
    @State private var topDay = 0
    /// The height of the grid, so the rail knows how much of the timeline is on screen.
    @State private var viewportHeight: Double = 0
    /// Cancelled and restarted on every seek, so stepping the rail repeatedly — which
    /// VoiceOver does, a year per tap — fetches the day it comes to rest on rather than
    /// every year it passes through.
    @State private var settle: Task<Void, Never>?
    @State private var gridWidth: Double = 0

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("Could not reach the server", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await store.refresh() } }
                }
            } else if store.index.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(emptyBody)
                )
            } else {
                grid
            }
        }
        .fullScreenCover(item: $opened) { tile in
            ViewerView(
                session: session,
                tiles: store.days[dayKey(of: tile)] ?? [tile],
                initial: tile,
                mode: .library,
                onFavorite: { store.setFavorite($0.id, $1) },
                onArchive: { store.archive($0.id) },
                onTrash: { store.trash([$0.id]) },
                onRestore: { _ in },
                onDetails: { details = $0 }
            )
        }
        .sheet(item: $details) { asset in
            DetailsView(asset: asset) { store.setDescription(asset.id, $0) }
        }
        .confirmationDialog(
            trashQuestion,
            isPresented: .init(
                get: { trashCount != nil },
                set: { if !$0 { trashCount = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to trash", role: .destructive) {
                store.trashEverything(except: trashExcept)
                clearSelection()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            store.notice ?? "",
            isPresented: .init(
                get: { store.notice != nil },
                set: { if !$0 { store.notice = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    /// Always a number, never "all photos": a question nobody can answer is not a
    /// confirmation, and a selection by query is precisely the case where the interface
    /// has not counted them itself.
    private var trashQuestion: String {
        guard let trashCount else { return "" }
        let photos = trashCount == 1 ? "photo" : "photos"
        return "Move \(trashCount.formatted()) \(photos) to the trash?"
    }

    private var layout: TimelineLayout {
        TimelineLayout(
            index: store.index,
            metrics: TimelineMetrics(
                // The grid is squares with two points of spacing, plus a heading.
                columns: columns,
                rowHeight: (viewportHeight > 0 ? cellSide : 100) + 2,
                headerHeight: 34,
                viewportHeight: viewportHeight
            )
        )
    }

    /// A cell is the width left over once the gaps are taken out.
    private var cellSide: Double { max((gridWidth - Double(columns - 1) * 2) / Double(columns), 1) }

    private var grid: some View {
        ScrollViewReader { scroller in
            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 2), count: columns
                        ),
                        spacing: 2,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        // A section per day. Sections rather than a flat list because the
                        // headers pin, and a pinned header is how somebody knows where
                        // they are without stopping to read the scrubber.
                        ForEach(0..<store.index.dayCount, id: \.self) { day in
                            Section {
                                cells(forDay: day)
                            } header: {
                                DayHeader(
                                    date: store.index.date(ofDay: day),
                                    count: store.index.count(ofDay: day)
                                )
                                .id(day)
                                .onAppear {
                                    topDay = day
                                    store.load(around: day)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }

                Scrubber(
                    layout: layout,
                    day: topDay,
                    isScrubbing: $store.isScrubbing
                ) { day in
                    topDay = day
                    // Once per drag, on release. `scrollTo` on a `LazyVGrid` has to lay
                    // out every section between here and the target before it knows
                    // where the target is, so this is the expensive line on the screen
                    // and the rail is careful to ask for it exactly once — see
                    // `ScrubDrag`.
                    scroller.scrollTo(day, anchor: .top)
                    // The design's rule: suspend fetching while the rail is moving and
                    // resume shortly after it settles, so a drag across fifteen years
                    // issues a couple of requests rather than forty.
                    settle?.cancel()
                    settle = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        store.load(around: day)
                    }
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            viewportHeight = proxy.size.height
                            gridWidth = proxy.size.width
                        }
                        .onChange(of: proxy.size) { _, size in
                            viewportHeight = size.height
                            gridWidth = size.width
                        }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting {
                    SelectionBar(
                        count: selectedCount,
                        showsRestore: false,
                        // There is no bulk favourite in the API, so an "everything"
                        // selection would mean a request per photograph. Offering the
                        // heart there would be offering ninety thousand round trips.
                        canFavourite: !selectingAll,
                        isBusy: resolvingTrash,
                        onClear: clearSelection,
                        onSelectAll: selectingAll ? nil : { selectingAll = true; picked = [] },
                        onFavourite: {
                            for id in picked { store.setFavorite(id, true) }
                            clearSelection()
                        },
                        onAddToAlbum: onAddToAlbum.map { add in
                            {
                                add(currentSelection)
                                clearSelection()
                            }
                        },
                        onTrash: {
                            guard selectingAll else {
                                store.trash(picked)
                                clearSelection()
                                return
                            }
                            // Asked before it is offered. Nothing is trashed until the
                            // count comes back and somebody agrees to it — against the
                            // exclusions as they were when the button was pressed.
                            let except = unpicked
                            trashRequest += 1
                            let token = trashRequest
                            resolvingTrash = true
                            Task {
                                let count = await store.resolvedCount(except: except)
                                // Clearing the selection while the count was being
                                // resolved is an answer of its own, and so is starting a
                                // second one. Either way this reply is stale: asking
                                // anyway would put a destructive dialog in front of
                                // somebody who had just backed out of it, or state a
                                // count and a set of exclusions from the selection before
                                // the one they are looking at.
                                guard token == trashRequest else { return }
                                resolvingTrash = false
                                guard count > 0 else {
                                    clearSelection()
                                    return
                                }
                                trashExcept = except
                                trashCount = count
                            }
                        },
                        onRestore: {}
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func cells(forDay day: Int) -> some View {
        let date = store.index.date(ofDay: day)
        let loaded = store.days[date]

        ForEach(0..<store.index.count(ofDay: day), id: \.self) { offset in
            if let tile = loaded?[safe: offset] {
                PhotoCell(
                    session: session,
                    tile: tile,
                    selected: isSelected(tile.id),
                    selecting: isSelecting
                ) {
                    if isSelecting { toggle(tile.id) } else { opened = tile }
                } onLongPress: {
                    toggle(tile.id)
                }
            } else {
                // A cell whose day has not arrived. Deliberately flat and unanimated: a
                // shimmer across four hundred cells is a lot of frames spent saying that
                // something already visible is loading.
                Rectangle()
                    .fill(Color.secondary.opacity(0.15))
                    .aspectRatio(1, contentMode: .fill)
            }
        }
    }

    private var isSelecting: Bool { selectingAll || !picked.isEmpty }

    private var selectedCount: Int {
        selectingAll ? max(store.index.photoCount - unpicked.count, 0) : picked.count
    }

    /// What a bulk action would act on. A list while photographs are ticked one at a time,
    /// and the query behind the grid once "select all" is on — which is the whole point:
    /// a hundred thousand ids do not belong in a request body.
    private var currentSelection: AssetSelection {
        selectingAll
            ? store.everything(except: unpicked)
            : AssetSelection(assetIds: Array(picked))
    }

    private func isSelected(_ id: String) -> Bool {
        selectingAll ? !unpicked.contains(id) : picked.contains(id)
    }

    private func toggle(_ id: String) {
        if selectingAll {
            if unpicked.contains(id) { unpicked.remove(id) } else { unpicked.insert(id) }
        } else {
            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
        }
    }

    private func clearSelection() {
        selectingAll = false
        picked = []
        unpicked = []
        trashExcept = []
        trashCount = nil
        resolvingTrash = false
        // Abandons a count still being resolved, so its answer cannot arrive against a
        // selection that no longer exists. See `trashRequest`.
        trashRequest += 1
    }
}

struct DayHeader: View {
    let date: String
    let count: Int

    var body: some View {
        HStack {
            Text(dayHeading(date)).font(.headline)
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }
}

struct PhotoCell<Tile: PhotoTile>: View {
    let session: Session
    let tile: Tile
    let selected: Bool
    let selecting: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        AssetImage(session: session, assetId: tile.id, placeholderColor: tile.placeholderColor)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay(alignment: .center) {
                if tile.type == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if tile.favorite, !selecting {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(4)
                }
            }
            .overlay {
                if selecting {
                    ZStack(alignment: .topTrailing) {
                        // The dimming is the point: it says which photographs are chosen
                        // from across the room, where a small tick says nothing at all.
                        if selected { Color.black.opacity(0.35) }
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .padding(4)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(perform: onLongPress)
            .accessibilityLabel(tile.spokenLabel)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
