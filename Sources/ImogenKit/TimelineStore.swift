import Foundation
import ImogenSDK
import Observation

/// The main timeline, fetched a day at a time.
///
/// The index says how many photographs each day holds, so the grid is the right length
/// before a single one is fetched. Days are then loaded as they come into view, which
/// means jumping to a date five years back costs one request rather than four hundred.
///
/// Loaded days are capped and evicted oldest-touched-first. Scrolling a fifty-thousand
/// photograph library from end to end must not end with all fifty thousand in memory.
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var index = TimelineIndex(buckets: [])
    /// Loaded photographs, by day. Days nobody has looked at are simply absent.
    public private(set) var days: [String: [Asset]] = [:]
    public private(set) var isLoading = true
    public private(set) var error: String?

    /// True while somebody is dragging the scrubber. Nothing is fetched then: a flick from
    /// one end of a decade to the other passes through hundreds of days it has no
    /// intention of stopping at.
    public var isScrubbing = false

    private let session: Session
    private var inFlight: Set<String> = []
    private var recency: [String] = []

    /// The API's own ceiling. Asking for more is refused rather than truncated.
    private let pageSize = 500

    /// Roughly two thousand photographs on a typical library, which is more than any
    /// screen shows and few enough to hold without thinking about it.
    private let maxLoadedDays = 60

    public init(session: Session) {
        self.session = session
        Task { await refresh() }
    }

    public func refresh() async {
        isLoading = true
        error = nil
        inFlight.removeAll()
        recency.removeAll()
        days.removeAll()

        do {
            let timeline = try await session.client.assets.timeline()
            index = TimelineIndex(buckets: timeline.buckets)
            isLoading = false
        } catch {
            self.error = describe(error)
            isLoading = false
        }
    }

    /// Asks for a day, and for the ones either side of it, if they are not already here.
    ///
    /// Reading one day ahead means scrolling on lands on photographs rather than on a
    /// screen of placeholders that fill in a moment later.
    public func load(around day: Int) {
        guard !isScrubbing, !index.isEmpty else { return }
        let from = max(day - 1, 0)
        let to = min(day + 1, index.dayCount - 1)
        for position in from...to { load(date: index.date(ofDay: position)) }
    }

    public func load(date: String) {
        guard days[date] == nil, !inFlight.contains(date) else { return }
        inFlight.insert(date)

        Task {
            defer { inFlight.remove(date) }
            let bounds = dayBounds(date)
            var collected: [Asset] = []
            var cursor: String?

            do {
                // A day usually fits in one request. A wedding does not, so the loop is
                // here — but it runs once for almost every day in almost every library.
                repeat {
                    let page = try await session.client.assets.list(
                        AssetQuery(
                            cursor: cursor,
                            limit: pageSize,
                            takenAfter: bounds.after,
                            takenBefore: bounds.before,
                            sort: .capturedAt,
                            order: .desc
                        )
                    )
                    collected.append(contentsOf: page.items)
                    cursor = page.nextCursor
                } while cursor != nil
            } catch {
                return
            }

            days[date] = collected
            touch(date)
        }
    }

    private func touch(_ date: String) {
        recency.removeAll { $0 == date }
        recency.append(date)
        while recency.count > maxLoadedDays {
            days[recency.removeFirst()] = nil
        }
    }

    // MARK: - Edits

    public func setFavorite(_ asset: Asset, _ favorite: Bool) {
        edit(asset, AssetUpdate(favorite: favorite)) { $0.favorite = favorite }
    }

    public func setDescription(_ asset: Asset, _ description: String) {
        edit(asset, AssetUpdate(description: description)) { $0.description = description }
    }

    /// Archiving takes a photograph out of the timeline entirely — the server leaves
    /// archived ones out of the buckets, so the grid has to lose the cell as well.
    public func archive(_ asset: Asset) {
        removeLocally([asset])
        Task {
            _ = try? await session.client.assets.update(asset.id, AssetUpdate(archived: true))
        }
    }

    public func trash(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        removeLocally(assets)
        Task {
            do {
                _ = try await session.client.assets.trash(assets.map(\.id))
            } catch {
                // The grid is now lying about what is on the server. Only a refetch can
                // put that right, and it is better than leaving a hole where a photograph
                // still is.
                await refresh()
            }
        }
    }

    private func edit(_ asset: Asset, _ patch: AssetUpdate, _ optimistic: (inout Asset) -> Void) {
        // Applied here first and sent afterwards. Pressing the heart should colour it in
        // immediately; waiting for a round trip to a server in somebody's cupboard makes a
        // responsive gesture feel broken.
        var updated = asset
        optimistic(&updated)
        replaceLocally(updated)

        Task {
            do {
                replaceLocally(try await session.client.assets.update(asset.id, patch))
            } catch {
                // Put it back the way it was. A heart that stays filled on a server that
                // refused the change is a lie the interface keeps telling.
                replaceLocally(asset)
            }
        }
    }

    private func replaceLocally(_ asset: Asset) {
        let date = String(asset.capturedAt.prefix(10))
        guard var day = days[date], let position = day.firstIndex(where: { $0.id == asset.id })
        else { return }
        day[position] = asset
        days[date] = day
    }

    private func removeLocally(_ assets: [Asset]) {
        let ids = Set(assets.map(\.id))
        var perDay: [String: Int] = [:]
        for asset in assets {
            perDay[String(asset.capturedAt.prefix(10)), default: 0] += 1
        }

        index = index.removing(perDay)
        for (date, _) in perDay {
            days[date] = days[date]?.filter { !ids.contains($0.id) }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? ImogenError)?.message ?? "Could not reach the server."
    }
}
