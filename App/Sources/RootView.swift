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

    /// What a phone shows along the bottom.
    ///
    /// Apple puts the ceiling at five and means it: seven tabs is a "More" list nobody
    /// finds. The three left out are at the top of the Albums screen instead.
    static let compact: [Destination] = [.photos, .search, .albums, .settings]

    /// The three that do not fit, in the order they appear on the Albums screen.
    static let collections: [Destination] = [.people, .favourites, .trash]
}

/// The whole application, above the individual screens.
///
/// There is no account until somebody adds one, and every screen below here needs a session
/// to be worth drawing — so the decision about which of those two worlds we are in is made
/// once, here, rather than by each screen guarding itself.
struct RootView: View {
    @Environment(AppModel.self) private var model

    /// What the last announcement said, so the same warning is not said twice.
    @State private var announced: String?

    var body: some View {
        Group {
            if let account = model.active {
                LibraryView(account: account)
                    // A different account is a different library: rebuilding the whole
                    // tree is what guarantees no screen is left showing the last one's
                    // photographs.
                    .id(account.id)
            } else if model.accounts.accountsUnreadable {
                // Not AddAccountView. The store is refusing to write, so a sign-in here
                // would last until the app closed and no longer — and it is the one
                // action that makes the read unrepeatable, because a book with something
                // in it can no longer be replaced by the device's own.
                AccountsUnreadableView()
            } else {
                // Signing out the last account is a save like any other, and this is the
                // only screen left to say it did not land on.
                AddAccountView().accountsNotSaved()
            }
        }
        // Announced once, here, rather than by the banner: the banner is attached in
        // several places at a time — a stack, and the viewer presented over it — and each
        // of them announcing would say it twice to somebody who cannot see either.
        //
        // On appear as well as on change: a read that failed is recorded before any of
        // this is on screen, so there is no change to notice — and that is the failure
        // somebody most needs told, because the screen behind it looks like a device with
        // no accounts on it.
        .onAppear { announce(model.accounts.lastFailure) }
        .onChange(of: model.accounts.lastFailure?.consequence) { _, _ in
            announce(model.accounts.lastFailure)
        }
    }

    private func announce(_ failure: AccountStoreFailure?) {
        guard let failure else {
            // A write that landed. Whatever comes next is news again, even if it says
            // the same words as the failure before it.
            announced = nil
            return
        }
        let warning = "\(failure.standing) \(failure.consequence)"

        // `onAppear` fires again whenever the branch below changes child — adding the
        // first account, and every switch after that, since the library is rebuilt by
        // `.id`. Repeating a warning somebody has already heard is noise on top of the
        // thing it is trying to make audible.
        guard warning != announced else { return }
        announced = warning
        AccessibilityNotification.Announcement(warning).post()
    }
}

extension View {
    /// Says, wherever this is, that the accounts are not reaching the keychain.
    ///
    /// Applied to whole navigation stacks and to anything presented over one, because a
    /// write fails where the person happens to be: a token refresh runs behind the
    /// photograph they are looking at, and a warning waiting at the root of a stack they
    /// are three screens into is one they read after they have been signed out.
    ///
    /// Along the bottom, and reserving its space rather than floating over it. Inset at
    /// the top of a stack takes the navigation bar's room and every screen loses its
    /// title; inset at the stack's root keeps the title but does not follow anybody who
    /// pushes a screen; an overlay anywhere covers whatever is under it, and this one has
    /// nothing to tap and does not go away, so it would swallow those touches for good —
    /// the viewer's own controls sit exactly there. An inset at the bottom moves them up.
    func accountsNotSaved() -> some View {
        safeAreaInset(edge: .bottom) { SaveFailureBanner() }
    }
}

private struct LibraryView: View {
    let account: Account

    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var destination: Destination = .photos
    @State private var pickingAlbumFor: AssetSelection?

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
            if let pickingAlbumFor {
                AlbumPickerHost(session: session, selection: pickingAlbumFor)
            }
        }
    }

    /// A phone: a tab bar, and everything else behind Settings.
    private func phone(_ session: Session) -> some View {
        TabView(selection: $destination) {
            ForEach(Destination.compact) { entry in
                NavigationStack {
                    content(entry, session, columns: 3)
                }
                .accountsNotSaved()
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
            .accountsNotSaved()
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
            AlbumsHost(
                session: session,
                columns: columns,
                // Only where there is no sidebar: on an iPad these are already in it, and
                // offering the same three things twice on one screen is clutter.
                showsCollections: sizeClass == .compact,
                onAddToAlbum: { pickingAlbumFor = $0 }
            )
        case .people:
            PeopleHost(session: session, columns: columns, onAddToAlbum: { pickingAlbumFor = $0 })
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
    let onAddToAlbum: (AssetSelection) -> Void

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
    var onAddToAlbum: ((AssetSelection) -> Void)?

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
    var showsCollections: Bool = false
    let onAddToAlbum: (AssetSelection) -> Void

    @State private var store: AlbumsStore?
    @State private var openedCollection: Destination?

    var body: some View {
        Group {
            if let store {
                AlbumsView(
                    session: session,
                    store: store,
                    columns: columns,
                    onOpen: { openedAlbum = $0 },
                    shortcuts: showsCollections ? collectionShortcuts : []
                )
                .navigationDestination(item: $openedCollection) { destination in
                    // The same screens the sidebar shows on an iPad, so there is one
                    // implementation of each rather than two.
                    CollectionView(
                        session: session,
                        columns: columns,
                        destination: destination,
                        onAddToAlbum: onAddToAlbum
                    )
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

    private var collectionShortcuts: [CollectionShortcut] {
        Destination.collections.map { destination in
            CollectionShortcut(label: destination.label, icon: destination.icon) {
                openedCollection = destination
            }
        }
    }
}

/// One of the destinations a phone has no room for along the bottom.
private struct CollectionView: View {
    let session: Session
    let columns: Int
    let destination: Destination
    let onAddToAlbum: (AssetSelection) -> Void

    var body: some View {
        switch destination {
        case .people:
            PeopleHost(session: session, columns: columns, onAddToAlbum: onAddToAlbum)
        case .favourites:
            FeedHost(
                session: session,
                columns: columns,
                query: AssetQuery(favorite: true),
                title: "Favourites",
                emptyTitle: "No favourites yet",
                emptyBody: "Tap the heart while looking at a photograph to keep it here.",
                onAddToAlbum: onAddToAlbum
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
        default:
            EmptyView()
        }
    }
}

private struct PeopleHost: View {
    let session: Session
    let columns: Int
    var onAddToAlbum: ((AssetSelection) -> Void)?

    @State private var store: PeopleStore?
    @State private var openedPerson: Person?

    var body: some View {
        Group {
            if let store {
                PeopleView(session: session, store: store, columns: columns) { person in
                    openedPerson = person
                }
                .navigationDestination(item: $openedPerson) { person in
                    PersonDetailView(
                        session: session,
                        person: person,
                        columns: columns,
                        onAddToAlbum: onAddToAlbum
                    )
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
    let selection: AssetSelection

    @State private var store: AlbumsStore?

    var body: some View {
        Group {
            if let store {
                AlbumPicker(
                    albums: store.albums,
                    onChoose: { store.add(selection, to: $0) },
                    onCreate: { store.create($0, with: selection) }
                )
            } else {
                ProgressView()
            }
        }
        .onAppear { if store == nil { store = AlbumsStore(session: session) } }
    }
}

/// There are no accounts to show because none could be read.
///
/// The same three lines the banner carries, but as the whole screen. There is nothing else
/// to put here, and along the bottom of an otherwise empty page they read as a footnote
/// about something else — while the page itself says, wrongly, that this device has never
/// had an account on it.
private struct AccountsUnreadableView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            if let failure = model.accounts.lastFailure {
                VStack(spacing: 12) {
                    Text(failure.standing).font(.headline)
                    Text(failure.consequence)
                    Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                }
                // One element, for the same reason the banner is: three labels make
                // somebody swipe through a warning three times to learn one thing. The
                // button below stays its own, or it could not be reached.
                .accessibilityElement(children: .combine)

                // Always available, whichever kind: a read costs nothing, and a screen
                // that says "unlocking it and trying again should bring them up" to
                // somebody already unlocked and already here needs something for them to
                // try. It is also the only way out of a seal inside one launch — the
                // automatic reread waits for a foreground transition that a launch
                // refused at startup never produces.
                Button("Try again", action: tryAgain)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }

            // A pairing link or an OAuth redirect arrives through `onOpenURL` wherever
            // somebody is, and this is where they are when nothing can be stored. Without
            // this the refusal has nowhere to appear at all: there is no AddAccountView
            // on screen to carry it.
            if case .failed(let message) = model.link {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private func tryAgain() {
        guard !model.accounts.retryRead() else {
            // The screen after this one renders the same link state, and a refusal from
            // while the store was sealed is not true of a store that is reading again.
            model.clearLinkState()
            return
        }

        // Said here rather than through the announcement at the root, which drops a
        // warning identical to the one it last said — and a second refusal is word for
        // word the first. Nothing on screen changes either, so without this the button
        // is indistinguishable from a button that does nothing.
        AccessibilityNotification.Announcement("Still could not read your accounts.").post()
    }
}

/// The accounts are not reaching the keychain.
///
/// Two lines, because they answer different questions and go stale at different times. The
/// standing one is true until a write lands; the consequence below it is about the most
/// recent change, and a later failure is allowed to replace it — which is only safe
/// because the line above does not move.
///
/// Not dismissible. The thing it reports is still true after it is read, and a warning
/// that can be put away while it remains true is the silence this exists to break.
private struct SaveFailureBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let failure = model.accounts.lastFailure {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.standing).foregroundStyle(.red)
                    Text(failure.consequence)
                    Text(failure.reason).foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .font(.caption)
            .padding(12)
            .background(.thinMaterial, in: .rect(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            // One element: three separate labels make somebody swipe through a warning
            // three times to learn one thing.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
        }
    }
}
