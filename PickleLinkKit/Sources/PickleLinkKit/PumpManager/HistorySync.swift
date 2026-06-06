#if canImport(LoopKit)
    import Foundation
    import LoopKit
    import MinimedKit

    struct PickleLinkHistorySync {
        let client: PickleLinkClient
        let pumpModel: PumpModel
        let timeZone: TimeZone

        /// Result of a sync pass.
        struct Result {
            var events: [NewPumpEvent]
            var newLastSyncedPage: UInt8
        }

        /// Walk history from `state.lastSyncedHistoryPage` up to the current page.
        ///
        /// - `startDate`: events on/before this are ignored (Loop filter date).
        /// - Handles the firmware's known 0x14 stub (currentPage=0/max=35) by falling
        ///   back to a MinimedKit-style walk: keep reading older pages until a page
        ///   yields no events after `startDate`.
        func sync(lastSyncedPage: UInt8, after startDate: Date) async throws -> Result {
            let info = try? await client.getHistoryInfo()

            // Detect stub: currentPage==0 with maxPage at the documented x22/x23 stub value (35),
            // or pageOffset==0 — treat as "info unavailable, walk pages".
            let infoLooksStubbed: Bool = {
                guard let info else { return true }
                return info.currentPage == 0 && info.maxPage == 35 && info.pageOffset == 0
            }()

            var collected: [TimestampedHistoryEvent] = []
            var highestPageRead = lastSyncedPage

            if let info, !infoLooksStubbed {
                // Targeted sync: pages [lastSyncedPage ... currentPage].
                let upper = max(info.currentPage, lastSyncedPage)
                var page = lastSyncedPage
                while page <= upper {
                    let raw = try await client.getHistory(page: page)
                    let (events, _) = try decode(raw, after: startDate)
                    collected.append(contentsOf: events)
                    highestPageRead = max(highestPageRead, page)
                    if page == UInt8.max { break }
                    page += 1
                }
            } else {
                // Stub fallback: walk from page 0 forward until a page reports no
                // more events after startDate (MinimedKit-style back-pressure).
                var page: UInt8 = 0
                let maxPages: UInt8 = 36 // x22/x23 ring is 36 pages (0...35).
                while page < maxPages {
                    let raw = try await client.getHistory(page: page)
                    let (events, hasMore) = try decode(raw, after: startDate)
                    collected.append(contentsOf: events)
                    highestPageRead = max(highestPageRead, page)
                    if !hasMore { break }
                    page += 1
                }
            }

            // Convert + dedupe (by raw event bytes).
            let pumpEvents = collected.pumpEvents(from: pumpModel)
            let deduped = dedupe(pumpEvents)

            return Result(events: deduped, newLastSyncedPage: highestPageRead)
        }

        /// Decode a raw page; returns its timestamped events after `startDate`
        /// and whether the page suggests more (older) events exist.
        private func decode(_ raw: Data, after startDate: Date) throws -> ([TimestampedHistoryEvent], hasMore: Bool) {
            // GET_HISTORY may return short data on a stubbed/empty page — skip gracefully.
            guard raw.count >= 1022 else { return ([], false) }
            let page = try HistoryPage(pageData: raw, pumpModel: pumpModel)
            let result = page.timestampedEvents(after: startDate, timeZone: timeZone, model: pumpModel)
            return (result.events, result.hasMoreEvents && !result.cancelledEarly)
        }

        private func dedupe(_ events: [NewPumpEvent]) -> [NewPumpEvent] {
            var seen = Set<Data>()
            var out: [NewPumpEvent] = []
            for e in events {
                if seen.insert(e.raw).inserted {
                    out.append(e)
                }
            }
            return out
        }
    }
#endif
