import ImogenKit
import ImogenSDK
import SwiftUI

enum Destination: String, CaseIterable, Identifiable, Hashable {
    case photos, search, albums, people, favourites, trash, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .photos: "Photos"
        case .search: "Search"
        case .albums: "Albums"
        case .people: "People"
        case .favourites: "Favourites"
        case .trash: "Trash"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .photos: "photo.on.rectangle.angled"
        case .search: "magnifyingglass"
        case .albums: "rectangle.stack"
        case .people: "person.2"
        case .favourites: "heart"
        case .trash: "trash"
        case .settings: "gearshape"
        }
    }

    /// What a phone shows along the bottom. Seven tabs do not fit on a phone, and the ones
    /// left out are reachable from Settings and from the library itself.
    static let compact: [Destination] = [.photos, .search, .albums, .settings]
}

/// The whole application, above the individual screens.
///
/// There is no account until somebody adds one, and every screen below here needs a session
/// to be worth drawing — so the decision about which of those two worlds we are in is made
/// once, here, rather than by each screen guarding itself.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let account = model.active {
            LibraryView(account: account)
                // A different account is a different library: rebuilding the whole tree
                // is what guarantees no screen is left showing the last one's photographs.
                .id(account.id)
        } else {
            AddAccountView()
        }
    }
}

private struct LibraryView: View {
    let account: Account

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var destination: Destination = .photos
    @State private var pickingAlbumFor: [String]?

    var body: some View {
        let session = model.session(for: account)

        Group {
            if sizeClass == .compact {
                phone(session)
            } else {
                tablet(session)
            }
        }
        .sheet(isPresented: .init(
            get: { pickingAlbumFor != nil },
            set: { if !$0 { pickingAlbumFor = nil } }
        )) {
            AlbumPickerHost(session: session, assetIds: pickingAlbumFor ?? [])
        }
    }

    /// A phone: a tab bar, and everything else behind Settings.
    private func phone(_ session: Session) -> some View {
        TabView(selection: $destination) {
            ForEach(Destination.compact) { entry in
                NavigationStack {
                    content(entry, session, columns: 3)
                }
                .tabItem { Label(entry.label, systemImage: entry.icon) }
                .tag(entry)
            }
        }
    }

    /// A tablet: a sidebar, which is where the destinations a phone has no room for live,
    /// and a detail pane wide enough for a real grid.
    private func tablet(_ session: Session) -> some View {
        NavigationSplitView {
            List(Destination.allCases, selection: .init(
                get: { Optional(destination) },
                set: { if let value = $0 { destination = value } }
            )) { entry in
                Label(entry.label, systemImage: entry.icon).tag(entry)
            }
            .navigationTitle(account.serverLabel)
            .listStyle(.sidebar)
        } detail: {
            NavigationStack {
                content(destination, session, columns: 6)
            }
        }
    }

    @ViewBuilder
    private func content(_ entry: Destination, _ session: Session, columns: Int) -> some View {
        switch entry {
        case .photos:
            TimelineHost(session: session, columns: columns) { pickingAlbumFor = $0 }
        case .search:
            SearchView(session: session, columns: columns) { pickingAlbumFor = $0 }
                .navigationTitle("Search")
        case .albums:
            AlbumsHost(session: session, columns: columns) { pickingAlbumFor = $0 }
        case .people:
            PeopleHost(session: session, columns: columns)
        case .favourites:
            FeedHost(
                session: session,
                columns: columns,
                query: AssetQuery(favorite: true),
                title: "Favourites",
                emptyTitle: "No favourites yet",
                emptyBody: "Tap the heart while looking at a photograph to keep it here.",
                onAddToAlbum: { pickingAlbumFor = $0 }
            )
        case .trash:
            FeedHost(
                session: session,
                columns: columns,
                query: AssetQuery(trashed: true),
                title: "Trash",
                emptyTitle: "Trash is empty",
                emptyBody: "Deleted photographs wait here before the server removes them.",
                mode: .trash
            )
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Hosts
//
// Each of these owns a store for as long as its screen is on the stack. A `@State` store
// built once and handed down is what stops a tab change from refetching a timeline that
// has not changed.

private struct TimelineHost: View {
    let session: Session
    let columns: Int
    let onAddToAlbum: ([String]) -> Void

    @State private var store: TimelineStore?

    var body: some View {
        Group {
            if let store {
                TimelineView(
                    session: session, store: store, columns: columns, onAddToAlbum: onAddToAlbum
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if store == nil { store = TimelineStore(session: session) } }
    }
}

private struct FeedHost: View {
    let session: Session
    let columns: Int
    let query: AssetQuery
    let title: String
    let emptyTitle: String
    let emptyBody: String
    var mode: ViewerMode = .library
    var onAddToAlbum: (([String]) -> Void)?

    @State private var feed: AssetFeed?

    var body: some View {
        Group {
            if let feed {
                FeedGridView(
                    session: session,
                    feed: feed,
                    columns: columns,
                    mode: mode,
                    emptyTitle: emptyTitle,
                    emptyBody: emptyBody,
                    onAddToAlbum: onAddToAlbum
                )
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .onAppear { if feed == nil { feed = AssetFeed(session: session, query: query) } }
    }
}

private struct AlbumsHost: View {
    let session: Session
    let columns: Int
    let onAddToAlbum: ([String]) -> Void

    @State private var store: AlbumsStore?

    var body: some View {
        Group {
            if let store {
                AlbumsView(session: session, store: store, columns: columns) { album in
                    openedAlbum = album
                }
                .navigationDestination(item: $openedAlbum) { album in
                    FeedHost(
                        session: session,
                        columns: columns,
                        query: AssetQuery(albumId: album.id),
                        title: album.name,
                        emptyTitle: "This album is empty",
                        emptyBody: "Select photographs anywhere in the library and add them here.",
                        onAddToAlbum: onAddToAlbum
                    )
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
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Albums")
        .onAppear { if store == nil { store = AlbumsStore(session: session) } }
    }

    @State private var openedAlbum: Album?
}

private struct PeopleHost: View {
    let session: Session
    let columns: Int

    @State private var store: PeopleStore?
    @State private var openedPerson: Person?

    var body: some View {
        Group {
            if let store {
                PeopleView(session: session, store: store, columns: columns) { person in
                    openedPerson = person
                }
                .navigationDestination(item: $openedPerson) { person in
                    PersonDetailView(session: session, person: person, columns: columns)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("People")
        .onAppear { if store == nil { store = PeopleStore(session: session) } }
    }
}

/// The album picker needs the album list, which lives in a store the picker's caller does
/// not have. One more store, built for the sheet and thrown away with it.
private struct AlbumPickerHost: View {
    let session: Session
    let assetIds: [String]

    @State private var store: AlbumsStore?

    var body: some View {
        Group {
            if let store {
                AlbumPicker(
                    albums: store.albums,
                    onChoose: { store.add(assetIds, to: $0) },
                    onCreate: { store.create($0, with: assetIds) }
                )
            } else {
                ProgressView()
            }
        }
        .onAppear { if store == nil { store = AlbumsStore(session: session) } }
    }
}
