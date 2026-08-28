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
    /// Something that went wrong with one action rather than with the screen. A bulk trash
    /// that the server refused must say so: it is the one destructive thing here, and
    /// refetching afterwards makes a failure look exactly like a success.
    public var notice: String?

    /// True while somebody is dragging the scrubber. Nothing is fetched then: a flick from
    /// one end of a decade to the other passes through hundreds of days it has no
    /// intention of stopping at.
    public var isScrubbing = false

    /// Which photographs this timeline is of. Empty means the whole library.
    public let filter: AssetFilter

    private let session: Session
    private var inFlight: Set<String> = []
    private var recency: [String] = []
    /// Bumped by every refresh, so a day fetched against the library as it was cannot land
    /// in the one it has become. Without it, trashing everything and refetching leaves the
    /// day that was already in flight sitting there as a screen of cells that 404.
    private var generation = 0

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
        generation += 1
        inFlight.removeAll()
        recency.removeAll()
        days.removeAll()

        let mine = generation
        do {
            let timeline = try await session.client.assets.timeline(TimelineQuery(filter: filter))
            // Two refreshes can be in the air at once — a pull while a bulk trash finishes
            // — and the slower one landing last would leave the index describing the
            // library as it was before the faster one.
            guard mine == generation else { return }
            index = TimelineIndex(buckets: timeline.buckets)
            isLoading = false
        } catch {
            guard mine == generation else { return }
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
            let mine = generation
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

            guard mine == generation else { return }
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

    /// By id rather than by tile, because a selection outlives the days it was made in:
    /// scroll far enough and the tile has been evicted while the id is still ticked. The
    /// optimistic update is what needs the tile, and it is simply skipped when there is
    /// none to redraw.
    public func setFavorite(_ id: String, _ favorite: Bool) {
        // Applied here first and sent afterwards. Pressing the heart should colour it in
        // immediately; waiting for a round trip to a server in somebody's cupboard makes a
        // responsive gesture feel broken.
        let before = loadedTile(id)
        if var updated = before {
            updated.favorite = favorite
            replaceLocally(updated)
        }

        Task {
            do {
                _ = try await session.client.assets.update(id, AssetUpdate(favorite: favorite))
            } catch {
                // Put it back the way it was. A heart that stays filled on a server that
                // refused the change is a lie the interface keeps telling.
                if let before { replaceLocally(before) }
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
    public func archive(_ id: String) {
        let removed = removeLocally([id])
        Task {
            do {
                _ = try await session.client.assets.update(id, AssetUpdate(archived: true))
                // Its day was not loaded, so the index still counts it and the grid would
                // keep a placeholder cell for a photograph that has left the timeline.
                if removed == 0 { await refresh() }
            } catch {
                // The cell is gone and the photograph is not. Only a refetch puts the grid
                // back in step with the library.
                await refresh()
            }
        }
    }

    public func trash(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let removed = removeLocally(ids)
        Task {
            do {
                _ = try await session.client.assets.trash(AssetSelection(assetIds: Array(ids)))
                // Anything whose day had been evicted was trashed on the server but never
                // taken out of the index, which is now counting photographs that are gone.
                if removed < ids.count { await refresh() }
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
    ///
    /// The refetch afterwards would hide a refusal perfectly — the grid empties or does
    /// not, and either looks deliberate — so a failure is said out loud.
    public func trashEverything(except excluded: Set<String>) {
        Task {
            do {
                _ = try await session.client.assets.trash(everything(except: excluded))
            } catch {
                notice = (error as? ImogenError)?.message
                    ?? "Those could not be moved to the trash."
            }
            await refresh()
        }
    }

    private func loadedTile(_ id: String) -> TimelineTile? {
        days.values.lazy.compactMap { $0.first { $0.id == id } }.first
    }

    private func replaceLocally(_ tile: TimelineTile) {
        let date = dayKey(of: tile)
        guard var day = days[date], let position = day.firstIndex(where: { $0.id == tile.id })
        else { return }
        day[position] = tile
        days[date] = day
    }

    /// Takes ids out of whatever days are loaded, and tells the caller how many it found.
    /// A day that has been evicted holds none of them, so the count is how much of the
    /// index could be corrected without going back to the server.
    @discardableResult
    private func removeLocally(_ ids: Set<String>) -> Int {
        var perDay: [String: Int] = [:]
        for (date, tiles) in days {
            let remaining = tiles.filter { !ids.contains($0.id) }
            guard remaining.count != tiles.count else { continue }
            perDay[date] = tiles.count - remaining.count
            days[date] = remaining
        }

        index = index.removing(perDay)
        return perDay.values.reduce(0, +)
    }

    private func describe(_ error: Error) -> String {
        (error as? ImogenError)?.message ?? "Could not reach the server."
    }
}
