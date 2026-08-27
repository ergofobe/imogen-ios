import ImogenKit
import ImogenSDK
import SwiftUI

/// Search.
///
/// The query is only sent when somebody says so — on the search key, or when a filter
/// changes. Searching on every keystroke would mean a request per letter to a server that
/// may be a Raspberry Pi at the end of a domestic uplink, and the results would flicker
/// through nonsense on the way to the word.
struct SearchView: View {
    let session: Session
    let columns: Int
    var onAddToAlbum: (([String]) -> Void)?

    @State private var text = ""
    @State private var type: AssetType?
    @State private var favouritesOnly = false
    @State private var feed: AssetFeed?

    var body: some View {
        VStack(spacing: 0) {
            filters

            if let feed {
                FeedGridView(
                    session: session,
                    feed: feed,
                    columns: columns,
                    emptyTitle: "Nothing matched",
                    emptyBody: "Try fewer words, or a different filter.",
                    onAddToAlbum: onAddToAlbum
                )
            } else {
                ContentUnavailableView(
                    "Search the library",
                    systemImage: "magnifyingglass",
                    description: Text(
                        "imogen looks through filenames, descriptions, camera models and places."
                    )
                )
            }
        }
        .searchable(text: $text, prompt: "Filename, description, camera, place")
        .onSubmit(of: .search) { submit() }
        .onChange(of: text) { _, value in
            // Clearing the field puts the prompt back rather than searching for nothing.
            if value.isEmpty, type == nil, !favouritesOnly { feed = nil }
        }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip("Photos", on: type == .image) {
                    type = type == .image ? nil : .image
                    submit()
                }
                FilterChip("Videos", on: type == .video) {
                    type = type == .video ? nil : .video
                    submit()
                }
                FilterChip("Favourites", on: favouritesOnly) {
                    favouritesOnly.toggle()
                    submit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || type != nil || favouritesOnly else {
            feed = nil
            return
        }
        // A new feed rather than a new query on the old one, so pages from the last search
        // cannot arrive late and land underneath this one's.
        feed = AssetFeed(
            session: session,
            query: AssetQuery(
                q: trimmed.isEmpty ? nil : trimmed,
                type: type,
                favorite: favouritesOnly ? true : nil
            )
        )
    }
}

private struct FilterChip: View {
    let label: String
    let on: Bool
    let action: () -> Void

    init(_ label: String, on: Bool, action: @escaping () -> Void) {
        self.label = label
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}
