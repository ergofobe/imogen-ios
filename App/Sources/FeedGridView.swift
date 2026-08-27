import ImogenKit
import ImogenSDK
import SwiftUI

/// A set of photographs chosen by a query: an album, a search, the favourites, the trash.
///
/// Not the main timeline — that is built from day counts, because cursor paging does not
/// survive fifty thousand photographs. These are bounded by something a person made, and
/// paging from the top is the right shape for a list you read from the top.
struct FeedGridView: View {
    let session: Session
    @Bindable var feed: AssetFeed
    let columns: Int
    var mode: ViewerMode = .library
    var emptyTitle: String = "Nothing here yet"
    var emptyBody: String = "Photographs will appear here once there are some."
    var onAddToAlbum: ((AssetSelection) -> Void)?

    @State private var selection: Set<String> = []
    @State private var opened: Asset?
    @State private var details: Asset?

    var body: some View {
        Group {
            if feed.isLoading && feed.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = feed.error, feed.items.isEmpty {
                ContentUnavailableView {
                    Label("Could not reach the server", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await feed.refresh() } }
                }
            } else if feed.items.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(emptyBody)
                )
            } else {
                grid
            }
        }
        .fullScreenCover(item: $opened) { asset in
            ViewerView(
                session: session,
                tiles: feed.items,
                initial: asset,
                mode: mode,
                onFavorite: feed.setFavorite,
                onArchive: { feed.archive($0, !$0.archived) },
                onTrash: { feed.trash([$0.id]) },
                onRestore: { feed.restore([$0.id]) },
                onDetails: { details = $0 }
            )
        }
        .sheet(item: $details) { asset in
            DetailsView(asset: asset) { feed.setDescription(asset, $0) }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns),
                spacing: 2,
                pinnedViews: [.sectionHeaders]
            ) {
                // Grouped by day here too, because a grid of photographs with no dates is
                // a wall. The grouping is over what is loaded, which for a bounded list is
                // all of it soon enough.
                ForEach(groupedByDay(), id: \.date) { group in
                    Section {
                        ForEach(group.assets) { asset in
                            PhotoCell(
                                session: session,
                                tile: asset,
                                selected: selection.contains(asset.id),
                                selecting: !selection.isEmpty
                            ) {
                                if selection.isEmpty { opened = asset } else { toggle(asset.id) }
                            } onLongPress: {
                                toggle(asset.id)
                            }
                            .onAppear {
                                if let position = feed.items.firstIndex(where: { $0.id == asset.id }),
                                    feed.shouldLoadMore(showing: position) {
                                    Task { await feed.loadMore() }
                                }
                            }
                        }
                    } header: {
                        DayHeader(date: group.date, count: group.assets.count)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                SelectionBar(
                    count: selection.count,
                    showsRestore: mode == .trash,
                    onClear: { selection = [] },
                    onFavourite: {
                        for asset in feed.items where selection.contains(asset.id) {
                            feed.setFavorite(asset, true)
                        }
                        selection = []
                    },
                    onAddToAlbum: onAddToAlbum.map { add in
                        {
                            add(AssetSelection(assetIds: Array(selection)))
                            selection = []
                        }
                    },
                    onTrash: {
                        feed.trash(Array(selection))
                        selection = []
                    },
                    onRestore: {
                        feed.restore(Array(selection))
                        selection = []
                    }
                )
            }
        }
    }

    private struct DayGroup {
        let date: String
        let assets: [Asset]
    }

    /// Grouped in the order the server sent them, which is already the right one.
    /// Re-deriving that order from parsed dates would be slower and would disagree with it
    /// whenever two photographs share a second.
    private func groupedByDay() -> [DayGroup] {
        var groups: [DayGroup] = []
        for asset in feed.items {
            let date = dayKey(of: asset)
            if groups.last?.date == date {
                groups[groups.count - 1] = DayGroup(
                    date: date, assets: groups[groups.count - 1].assets + [asset]
                )
            } else {
                groups.append(DayGroup(date: date, assets: [asset]))
            }
        }
        return groups
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

/// What can be done to a selection.
///
/// The count is stated rather than implied. Selecting across a long scroll is easy to lose
/// track of, and "move 340 photographs to the trash" is a different decision from "move 3".
/// That holds all the way up: a selection of everything states the number too, which is why
/// the count here is the resolved one rather than the length of a list.
struct SelectionBar: View {
    let count: Int
    let showsRestore: Bool
    var canFavourite: Bool = true
    /// True while a count is being resolved. Trashing is the action that has to wait for
    /// one, and a destructive button that stays live through a round trip either looks
    /// broken or gets pressed twice.
    var isBusy: Bool = false
    let onClear: () -> Void
    var onSelectAll: (() -> Void)?
    let onFavourite: () -> Void
    let onAddToAlbum: (() -> Void)?
    let onTrash: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Button(action: onClear) { Image(systemName: "xmark") }
                .accessibilityLabel("Clear selection")
            Text("\(count.formatted()) selected").font(.subheadline.weight(.medium))

            if let onSelectAll {
                Button("Select all", action: onSelectAll).font(.subheadline)
            }
            if isBusy { ProgressView().controlSize(.small) }

            Spacer()

            if showsRestore {
                Button(action: onRestore) { Image(systemName: "arrow.uturn.backward") }
                    .accessibilityLabel("Put back")
            } else {
                if let onAddToAlbum {
                    Button(action: onAddToAlbum) { Image(systemName: "rectangle.stack.badge.plus") }
                        .accessibilityLabel("Add to album")
                }
                if canFavourite {
                    Button(action: onFavourite) { Image(systemName: "heart") }
                        .accessibilityLabel("Favourite")
                }
                Button(action: onTrash) { Image(systemName: "trash") }
                    .accessibilityLabel("Move to trash")
                    .disabled(isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
