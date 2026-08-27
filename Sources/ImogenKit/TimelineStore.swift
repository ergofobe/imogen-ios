import Foundation
import ImogenSDK
import Observation

/// The main timeline, fetched a day at a time.
///
/// The index says how many photographs each day holds, so the grid is the right length
/// before a single one is fetched. Days are then loaded as they come into view, which
/// means jumping to a date five years back costs one request rather than four hundred.
///
/// What a day loads is tiles, not assets. A square draws an id, a colour, a duration and a
/// heart; an `Asset` carries checksum, exif, mime types and both captured-at corrections as
/// well, which over a heavy month is the difference between one round trip and three. The
/// viewer fetches the whole asset for the one photograph it is showing.
///
/// A filter makes this the timeline of a subset — one person's photographs, say — with the
/// same day headings, the same rail and the same windowing as the library's own.
///
/// Loaded days are capped and evicted oldest-touched-first. Scrolling a fifty-thousand
/// photograph library from end to end must not end with all fifty thousand in memory.
@MainActor
@Observable
public final class TimelineStore {
    public private(set) var index = TimelineIndex(buckets: [])
    /// Loaded tiles, by day. Days nobody has looked at are simply absent.
    public private(set) var days: [String: [TimelineTile]] = [:]
    public private(set) var isLoading = true
    public private(set) var error: String?

    /// True while somebody is dragging the scrubber. Nothing is fetched then: a flick from
    /// one end of a decade to the other passes through hundreds of days it has no
    /// intention of stopping at.
    public var isScrubbing = false

    /// Which photographs this timeline is of. Empty means the whole library.
    public let filter: AssetFilter

    private let session: Session
    private var inFlight: Set<String> = []
    private var recency: [String] = []

    /// Roughly two thousand photographs on a typical library, which is more than any
    /// screen shows and few enough to hold without thinking about it.
    private let maxLoadedDays = 60

    public init(session: Session, filter: AssetFilter = AssetFilter()) {
        self.session = session
        self.filter = filter
        Task { await refresh() }
    }

    public func refresh() async {
        isLoading = true
        error = nil
        inFlight.removeAll()
        recency.removeAll()
        days.removeAll()

        do {
            let timeline = try await session.client.assets.timeline(TimelineQuery(filter: filter))
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
            var collected: [TimelineTile] = []
            var cursor: String?

            do {
                // A day usually fits in one request. A wedding does not, so the loop is
                // here — but it runs once for almost every day in almost every library.
                // No limit is sent: the server's default is the right page size to ask
                // for, and hard-coding one here would be this client's guess at it.
                repeat {
                    let page = try await session.client.assets.timelineBucket(
                        TimelineBucketQuery(period: date, filter: filter, cursor: cursor)
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

    public func setFavorite(_ tile: TimelineTile, _ favorite: Bool) {
        // Applied here first and sent afterwards. Pressing the heart should colour it in
        // immediately; waiting for a round trip to a server in somebody's cupboard makes a
        // responsive gesture feel broken.
        var updated = tile
        updated.favorite = favorite
        replaceLocally(updated)

        Task {
            do {
                _ = try await session.client.assets.update(
                    tile.id, AssetUpdate(favorite: favorite))
            } catch {
                // Put it back the way it was. A heart that stays filled on a server that
                // refused the change is a lie the interface keeps telling.
                replaceLocally(tile)
            }
        }
    }

    /// A description is not on a tile and is not drawn by the grid, so there is nothing
    /// here to update optimistically — the details sheet holds the asset it edited.
    public func setDescription(_ assetId: String, _ description: String) {
        Task {
            _ = try? await session.client.assets.update(
                assetId, AssetUpdate(description: description))
        }
    }

    /// Archiving takes a photograph out of the timeline entirely — the server leaves
    /// archived ones out of the buckets, so the grid has to lose the cell as well.
    public func archive(_ tile: TimelineTile) {
        removeLocally([tile])
        Task {
            _ = try? await session.client.assets.update(tile.id, AssetUpdate(archived: true))
        }
    }

    public func trash(_ tiles: [TimelineTile]) {
        guard !tiles.isEmpty else { return }
        removeLocally(tiles)
        Task {
            do {
                _ = try await session.client.assets.trash(
                    AssetSelection(assetIds: tiles.map(\.id)))
            } catch {
                // The grid is now lying about what is on the server. Only a refetch can
                // put that right, and it is better than leaving a hole where a photograph
                // still is.
                await refresh()
            }
        }
    }

    // MARK: - Everything this timeline is of

    /// The whole timeline as a selection, minus whatever was unticked.
    ///
    /// A filter rather than a list of ids: "select all" on a ninety-thousand photograph
    /// library is not a request body, it is the query the person was already looking at.
    public func everything(except excluded: Set<String>) -> AssetSelection {
        AssetSelection(query: filter, except: excluded.isEmpty ? nil : Array(excluded))
    }

    /// How many photographs a by-query action would touch, fetched before it is offered.
    ///
    /// The whole point of a selection by query is that the client never counted them, and
    /// "delete all photos?" is not a question anybody can answer. So the buckets are asked
    /// again — one cheap request, no images — and the confirmation states a number. The
    /// index is the same figure from the same endpoint, so it stands in if the request
    /// fails rather than leaving the question unanswerable.
    public func resolvedCount(except excluded: Set<String>) async -> Int {
        let counted = try? await session.client.assets.timeline(TimelineQuery(filter: filter))
        let total = counted?.buckets.reduce(0) { $0 + $1.count } ?? index.photoCount
        return max(total - excluded.count, 0)
    }

    /// Trashes everything the filter matches. Only ever called behind a confirmation that
    /// states the count from `resolvedCount(except:)`.
    public func trashEverything(except excluded: Set<String>) {
        Task {
            _ = try? await session.client.assets.trash(everything(except: excluded))
            await refresh()
        }
    }

    private func replaceLocally(_ tile: TimelineTile) {
        let date = dayKey(of: tile)
        guard var day = days[date], let position = day.firstIndex(where: { $0.id == tile.id })
        else { return }
        day[position] = tile
        days[date] = day
    }

    private func removeLocally(_ tiles: [TimelineTile]) {
        let ids = Set(tiles.map(\.id))
        var perDay: [String: Int] = [:]
        for tile in tiles {
            perDay[dayKey(of: tile), default: 0] += 1
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
