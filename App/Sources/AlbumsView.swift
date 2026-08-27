import ImogenKit
import ImogenSDK
import Observation
import SwiftUI

@MainActor
@Observable
final class AlbumsStore {
    private(set) var albums: [Album] = []
    private(set) var isLoading = true
    private(set) var error: String?
    /// Set after adding photographs, so the screen can say how many actually landed.
    var notice: String?

    private let session: Session

    init(session: Session) {
        self.session = session
        Task { await refresh() }
    }

    func refresh() async {
        isLoading = true
        do {
            albums = try await session.client.albums.list()
            error = nil
        } catch {
            self.error = (error as? ImogenError)?.message ?? "Could not reach the server."
        }
        isLoading = false
    }

    func create(_ name: String, with assetIds: [String]? = nil) {
        Task {
            guard let album = try? await session.client.albums.create(
                AlbumCreate(name: name, assetIds: assetIds)
            ) else { return }
            albums.append(album)
            if assetIds != nil { notice = "Added to \(album.name)" }
        }
    }

    func rename(_ album: Album, to name: String) {
        Task {
            guard let updated = try? await session.client.albums.update(
                album.id, AlbumUpdate(name: name)
            ) else { return }
            if let position = albums.firstIndex(where: { $0.id == updated.id }) {
                albums[position] = updated
            }
        }
    }

    func delete(_ album: Album) {
        // Gone from the list at once. Deleting an album does not delete its photographs,
        // so there is nothing here worth a confirmation round trip.
        albums.removeAll { $0.id == album.id }
        Task {
            do { try await session.client.albums.remove(album.id) } catch { await refresh() }
        }
    }

    /// Adding is idempotent server-side, and the result says what actually changed — so a
    /// photograph already in the album is reported as skipped rather than as added twice.
    func add(_ assetIds: [String], to album: Album) {
        Task {
            do {
                let result = try await session.client.albums.addAssets(album.id, assetIds)
                if let position = albums.firstIndex(where: { $0.id == album.id }) {
                    albums[position].assetCount = result.assetCount
                }
                notice = switch (result.added, result.skipped) {
                case (0, _): "Already in that album"
                case (let added, let skipped) where skipped > 0:
                    "Added \(added), \(skipped) already there"
                case (let added, _): "Added \(added)"
                }
            } catch {
                notice = (error as? ImogenError)?.message ?? "Could not add those."
            }
        }
    }
}

/// The albums, as covers.
///
/// A list of names would be smaller and would tell you almost nothing: people remember an
/// album by the photograph on the front of it, which is why the cover is the control and
/// the name sits underneath.
struct AlbumsView: View {
    let session: Session
    @Bindable var store: AlbumsStore
    let columns: Int
    let onOpen: (Album) -> Void

    @State private var naming = false
    @State private var renaming: Album?

    var body: some View {
        Group {
            if store.isLoading && store.albums.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.albums.isEmpty {
                ContentUnavailableView(
                    "No albums yet",
                    systemImage: "rectangle.stack",
                    description: Text(
                        "An album is a way to keep a set of photographs together — a trip, "
                            + "a person, a year."
                    )
                )
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: min(columns, 6)
                        ),
                        spacing: 16
                    ) {
                        ForEach(store.albums) { album in
                            AlbumCover(session: session, album: album)
                                .onTapGesture { onOpen(album) }
                                .contextMenu {
                                    Button("Rename") { renaming = album }
                                    Button("Delete", role: .destructive) { store.delete(album) }
                                }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { naming = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New album")
            }
        }
        .alert("New album", isPresented: $naming) {
            AlbumNameFields { store.create($0) }
        }
        .alert("Rename album", isPresented: .init(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            AlbumNameFields(initial: renaming?.name ?? "") { name in
                if let album = renaming { store.rename(album, to: name) }
                renaming = nil
            }
        }
    }
}

/// The text field and buttons an alert needs, in one place, because there are two alerts
/// and they differ only in their title.
private struct AlbumNameFields: View {
    var initial: String = ""
    let onConfirm: (String) -> Void

    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
        Button("Cancel", role: .cancel) {}
        Button("Save") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onConfirm(trimmed) }
            name = ""
        }
        .onAppear { name = initial }
    }
}

struct AlbumCover: View {
    let session: Session
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.15))
                if let cover = album.coverAssetId {
                    CoverImage(session: session, assetId: cover)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(album.name).font(.subheadline.weight(.medium)).lineLimit(1)
            Text("\(album.assetCount) \(album.assetCount == 1 ? "photo" : "photos")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// An album cover is an asset id without an `Asset`, so it cannot use `AssetImage`.
private struct CoverImage: View {
    let session: Session
    let assetId: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.clear
            }
        }
        .task(id: assetId) {
            guard let url = session.assetURL(assetId, variant: "thumbnail") else { return }
            image = await ThumbnailCache.shared.image(
                for: url, key: "\(session.accountId):\(assetId):thumbnail", session: session
            )
        }
    }
}

/// Where a selection goes.
///
/// "New album…" sits at the top rather than the bottom: somebody who has just selected
/// fifteen photographs of one afternoon usually wants a new album for them, and putting
/// that below a scrolling list of the existing ones hides the likeliest answer.
struct AlbumPicker: View {
    let albums: [Album]
    let onChoose: (Album) -> Void
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var naming = false

    var body: some View {
        NavigationStack {
            List {
                Button {
                    naming = true
                } label: {
                    Label("New album…", systemImage: "plus")
                }

                ForEach(albums) { album in
                    Button {
                        onChoose(album)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(album.name).foregroundStyle(.primary)
                            Text("\(album.assetCount) \(album.assetCount == 1 ? "photo" : "photos")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Add to album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("New album", isPresented: $naming) {
                AlbumNameFields { name in
                    onCreate(name)
                    dismiss()
                }
            }
        }
    }
}
