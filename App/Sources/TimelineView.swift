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
    var onAddToAlbum: (([String]) -> Void)?

    @State private var selection: Set<String> = []
    @State private var opened: Asset?
    @State private var details: Asset?
    /// The day at the top of the viewport, which is what the thumb draws itself against.
    @State private var topDay = 0

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
                    "Your library is empty",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(
                        "Turn on backup, or add photographs from another device — they "
                            + "will appear here, newest first."
                    )
                )
            } else {
                grid
            }
        }
        .fullScreenCover(item: $opened) { asset in
            ViewerView(
                session: session,
                assets: store.days[String(asset.capturedAt.prefix(10))] ?? [asset],
                initial: asset,
                mode: .library,
                onFavorite: store.setFavorite,
                onArchive: { store.archive($0) },
                onTrash: { store.trash([$0]) },
                onRestore: { _ in },
                onDetails: { details = $0 }
            )
        }
        .sheet(item: $details) { asset in
            DetailsView(asset: asset) { store.setDescription(asset, $0) }
        }
    }

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
                    index: store.index,
                    day: topDay,
                    isScrubbing: $store.isScrubbing
                ) { day in
                    topDay = day
                    scroller.scrollTo(day, anchor: .top)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selection.isEmpty {
                    SelectionBar(
                        count: selection.count,
                        showsRestore: false,
                        onClear: { selection = [] },
                        onFavourite: {
                            for asset in selected() { store.setFavorite(asset, true) }
                            selection = []
                        },
                        onAddToAlbum: onAddToAlbum.map { add in
                            {
                                add(Array(selection))
                                selection = []
                            }
                        },
                        onTrash: {
                            store.trash(selected())
                            selection = []
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
            if let asset = loaded?[safe: offset] {
                PhotoCell(
                    session: session,
                    asset: asset,
                    selected: selection.contains(asset.id),
                    selecting: !selection.isEmpty
                ) {
                    if selection.isEmpty { opened = asset } else { toggle(asset.id) }
                } onLongPress: {
                    toggle(asset.id)
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

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func selected() -> [Asset] {
        store.days.values.flatMap { $0 }.filter { selection.contains($0.id) }
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

struct PhotoCell: View {
    let session: Session
    let asset: Asset
    let selected: Bool
    let selecting: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        AssetImage(session: session, asset: asset)
            .aspectRatio(1, contentMode: .fill)
            .clipped()
            .overlay(alignment: .center) {
                if asset.type == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if asset.favorite, !selecting {
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
            .accessibilityLabel(asset.description ?? asset.originalFilename)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
