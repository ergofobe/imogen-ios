import Foundation
import ImogenSDK
import Observation

/// One query's worth of the library, a page at a time.
///
/// The main timeline does not use this — it is built from day counts, because cursor
/// paging does not survive fifty thousand photographs. Everything else does: an album, a
/// search, the favourites, the trash. Those are bounded by something a person made, and a
/// cursor is the right tool for a list you read from the top.
///
/// Cursors rather than offsets, because the server says so and it is right to: a list that
/// grows while somebody scrolls shifts every later page by one, and an offset-paged grid
/// duplicates and skips photographs in front of them as it happens.
@MainActor
@Observable
public final class AssetFeed {
    public private(set) var items: [Asset] = []
    public private(set) var isLoading = true
    public private(set) var isAppending = false
    public private(set) var exhausted = false
    public private(set) var error: String?

    private let session: Session
    private let query: AssetQuery
    private var cursor: String?

    private let pageSize = 120

    public init(session: Session, query: AssetQuery) {
        self.session = session
        self.query = query
        Task { await refresh() }
    }

    public func refresh() async {
        cursor = nil
        exhausted = false
        error = nil
        isLoading = true

        do {
            var first = query
            first.limit = pageSize
            let page = try await session.client.assets.list(first)
            items = page.items
            cursor = page.nextCursor
            exhausted = page.nextCursor == nil
        } catch {
            self.error = describe(error)
        }
        isLoading = false
    }

    public func loadMore() async {
        guard !isLoading, !isAppending, !exhausted, let next = cursor else { return }
        isAppending = true
        defer { isAppending = false }

        do {
            var more = query
            more.cursor = next
            more.limit = pageSize
            let page = try await session.client.assets.list(more)
            // Guard against a page arriving twice, which a fast scroll and a slow network
            // can otherwise arrange between them.
            let known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { !known.contains($0.id) })
            cursor = page.nextCursor
            exhausted = page.nextCursor == nil
        } catch {
            // A failed page is not a failed feed: what is already here is still good.
        }
    }

    /// True once the grid is close enough to the end that the next page should be asked
    /// for. "Near" rather than "at": asking when the last row is on screen means a gap.
    public func shouldLoadMore(showing index: Int) -> Bool {
        !exhausted && index >= items.count - 24
    }

    // MARK: - Edits

    public func setFavorite(_ asset: Asset, _ favorite: Bool) {
        edit(asset, AssetUpdate(favorite: favorite)) { $0.favorite = favorite }
    }

    public func setDescription(_ asset: Asset, _ description: String) {
        edit(asset, AssetUpdate(description: description)) { $0.description = description }
    }

    public func archive(_ asset: Asset, _ archived: Bool) {
        edit(asset, AssetUpdate(archived: archived)) { $0.archived = archived }
    }

    public func trash(_ ids: [String]) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        Task {
            do {
                _ = try await session.client.assets.trash(ids)
            } catch {
                putBack(removed)
            }
        }
    }

    public func restore(_ ids: [String]) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        Task {
            do {
                _ = try await session.client.assets.restore(ids)
            } catch {
                putBack(removed)
            }
        }
    }

    private func edit(_ asset: Asset, _ patch: AssetUpdate, _ optimistic: (inout Asset) -> Void) {
        guard let position = items.firstIndex(where: { $0.id == asset.id }) else { return }
        let before = items[position]
        optimistic(&items[position])

        Task {
            do {
                let updated = try await session.client.assets.update(asset.id, patch)
                if let now = items.firstIndex(where: { $0.id == updated.id }) {
                    items[now] = updated
                }
            } catch {
                if let now = items.firstIndex(where: { $0.id == before.id }) {
                    items[now] = before
                }
            }
        }
    }

    private func putBack(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        items.append(contentsOf: assets)
        items.sort { $0.capturedAt > $1.capturedAt }
    }

    private func describe(_ error: Error) -> String {
        (error as? ImogenError)?.message ?? "Could not reach the server."
    }
}
