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

/// One person's photographs, which is an ordinary timeline with a filter on it.
///
/// It used to be `people.get(id).photos`. That endpoint caps at five hundred and selects
/// with no ordering, so somebody with three thousand photographs got an arbitrary five
/// hundred in uuid order — which, grouped by day, reads as scattered noise rather than as a
/// life. `personId` on the filter makes this the same screen as the library's own, and it
/// gets the day headings, the rail and the windowing for nothing.
struct PersonDetailView: View {
    let session: Session
    let person: Person
    let columns: Int
    var onAddToAlbum: ((AssetSelection) -> Void)?

    @State private var store: TimelineStore?

    var body: some View {
        Group {
            if let store {
                TimelineView(
                    session: session,
                    store: store,
                    columns: columns,
                    onAddToAlbum: onAddToAlbum,
                    emptyTitle: "No photographs",
                    emptyBody: "Nothing here is grouped under this person."
                )
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(person.name ?? "Unnamed")
        // Keyed on the person rather than on the store being absent: a detail pane that
        // swaps one person for another keeps the view and would otherwise keep the last
        // one's photographs.
        .onAppear {
            if store?.filter.personId != person.id {
                store = TimelineStore(
                    session: session, filter: AssetFilter(personId: person.id)
                )
            }
        }
    }
}
