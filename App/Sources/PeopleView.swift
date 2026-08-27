import ImogenKit
import ImogenSDK
import Observation
import SwiftUI

/// Face grouping is optional and off until a server administrator turns it on, so this has
/// to have something sensible to say when there is nothing to show — and that is not the
/// same as "no people found".
@MainActor
@Observable
final class PeopleStore {
    private(set) var people: [Person] = []
    private(set) var isLoading = true
    /// False when the server has face grouping switched off, which is the default.
    private(set) var available = true
    private(set) var message: String?

    private let session: Session

    init(session: Session) {
        self.session = session
        Task { await refresh() }
    }

    func refresh() async {
        defer { isLoading = false }

        guard let status = try? await session.client.people.status(), status.enabled else {
            available = false
            message = "This server does not have face grouping switched on."
            return
        }
        available = true

        guard let found = try? await session.client.people.list() else {
            message = "Could not load people."
            return
        }
        people = found
        message = found.isEmpty && status.pending > 0
            ? "Still looking. \(status.pending) photographs left to scan."
            : nil
    }

    func rename(_ person: Person, to name: String) {
        Task {
            try? await session.client.people.update(person.id, PersonUpdate(name: name))
            await refresh()
        }
    }
}

struct PeopleView: View {
    let session: Session
    @Bindable var store: PeopleStore
    let columns: Int
    let onOpen: (Person) -> Void

    @State private var renaming: Person?

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.available {
                ContentUnavailableView(
                    "People are not switched on",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(
                        store.message
                            ?? "An administrator can enable face grouping on the server."
                    )
                )
            } else if store.people.isEmpty {
                ContentUnavailableView(
                    "Nobody yet",
                    systemImage: "person.2",
                    description: Text(
                        store.message
                            ?? "People appear here once the server has grouped some faces."
                    )
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: min(columns, 8)
                        ),
                        spacing: 16
                    ) {
                        ForEach(store.people) { person in
                            PersonFace(session: session, person: person)
                                .onTapGesture { onOpen(person) }
                                .contextMenu {
                                    Button("Name this person") { renaming = person }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .alert("Name this person", isPresented: .init(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            PersonNameField(initial: renaming?.name ?? "") { name in
                if let person = renaming { store.rename(person, to: name) }
                renaming = nil
            }
        }
    }
}

private struct PersonNameField: View {
    let initial: String
    let onConfirm: (String) -> Void

    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
        Button("Cancel", role: .cancel) {}
        Button("Save") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onConfirm(trimmed) }
        }
        .onAppear { name = initial }
    }
}

struct PersonFace: View {
    let session: Session
    let person: Person

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.secondary.opacity(0.15))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(Circle())
                }
            }
            .aspectRatio(1, contentMode: .fit)

            // An unnamed cluster is still browsable, and calling it "Unnamed" is more
            // honest than leaving a blank where a name goes.
            Text(person.name ?? "Unnamed")
                .font(.caption)
                .lineLimit(1)
        }
        .task(id: person.coverFaceId) {
            guard let face = person.coverFaceId,
                let url = session.faceThumbnailURL(face)
            else { return }
            image = await ThumbnailCache.shared.image(
                for: url, key: "\(session.accountId):face:\(face)", session: session
            )
        }
    }
}

/// One person's photographs.
///
/// The people endpoint hands back a person with their photographs attached rather than a
/// cursor-paged query, so there is nothing here to page through — and pretending otherwise
/// would mean an `AssetQuery` filter the API does not have.
struct PersonDetailView: View {
    let session: Session
    let person: Person
    let columns: Int

    @State private var photos: [Asset]?
    @State private var opened: Asset?
    @State private var details: Asset?

    var body: some View {
        Group {
            if let photos {
                if photos.isEmpty {
                    ContentUnavailableView(
                        "No photographs",
                        systemImage: "photo",
                        description: Text("Nothing here is grouped under this person.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 2), count: columns
                            ),
                            spacing: 2
                        ) {
                            ForEach(photos) { asset in
                                PhotoCell(
                                    session: session, asset: asset,
                                    selected: false, selecting: false
                                ) {
                                    opened = asset
                                } onLongPress: {}
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(person.name ?? "Unnamed")
        .task(id: person.id) {
            photos = (try? await session.client.people.get(person.id).photos) ?? []
        }
        .fullScreenCover(item: $opened) { asset in
            ViewerView(
                session: session,
                assets: photos ?? [asset],
                initial: asset,
                mode: .library,
                // Editing from here would need the list refetching to stay honest, and a
                // person's page is somewhere you look rather than somewhere you tidy.
                onFavorite: { _, _ in },
                onArchive: { _ in },
                onTrash: { _ in },
                onRestore: { _ in },
                onDetails: { details = $0 }
            )
        }
        .sheet(item: $details) { asset in
            DetailsView(asset: asset) { _ in }
        }
    }
}
