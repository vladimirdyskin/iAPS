#if canImport(LoopKit)
    import Foundation
    import LoopKit
    // MinimedKit не импортируется: PumpModel, HistoryPage, TimestampedHistoryEvent — in-module (Medtronic/)

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
        /// - Прошивка не имеет реального указателя страниц Medtronic — getHistoryInfo
        ///   (0x14) всегда заглушка (currentPage=0, pageOffset=0). Поэтому всегда идём
        ///   MinimedKit-walk'ом: читаем страницы с 0, пока страница даёт события после
        ///   startDate (back-pressure по hasMore).
        func sync(lastSyncedPage: UInt8, after startDate: Date) async throws -> Result {
            let info = try? await client.getHistoryInfo()

            // Прошивка всегда отдаёт заглушку (currentPage=0, pageOffset=0) — реального
            // указателя страниц у Medtronic нет. Любой такой ответ → walk с нуля.
            let infoLooksStubbed: Bool = {
                guard let info else { return true }
                return info.currentPage == 0 && info.pageOffset == 0
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
            // Валидны только 1022 (данные без CRC) или ≥1024 (с CRC). 1023 — битая
            // длина, иначе дописанный CRC даст 1025 байт парсеру. Короткое → пропуск.
            guard raw.count == 1022 || raw.count >= 1024 else { return ([], false) }

            // Прошивка шлёт 1024 = 1022 данных + 2 байта CRC16 BE (валидирует на устройстве).
            // HistoryPage.init ожидает 1024. Если пришло ровно 1022 (старая прошивка) —
            // пересчитываем CRC и дописываем. Если ≥1024 — используем как есть.
            var pageData: Data
            if raw.count < 1024 {
                let crc = pickleComputeCRC16(raw)
                pageData = raw
                pageData.append(UInt8(crc >> 8)) // hi byte BE
                pageData.append(UInt8(crc & 0xFF)) // lo byte BE
            } else {
                pageData = raw
            }

            guard pageData.count >= 1024 else { return ([], false) }
            let page = try HistoryPage(pageData: pageData, pumpModel: pumpModel)
            let result = page.timestampedEvents(after: startDate, timeZone: timeZone, model: pumpModel)
            return (result.events, result.hasMoreEvents && !result.cancelledEarly)
        }

        /// Однократный бэкафилл: сканирует историю без фильтра по дате, ищет
        /// самое свежее событие смены резервуара (.rewind) и смены набора
        /// (.replaceComponent(.infusionSet)). Останавливается, когда найдены
        /// оба события или достигнут лимит страниц.
        ///
        /// - Parameter maxPages: максимум страниц для чтения (по умолчанию 16).
        /// - Returns: (rewindDate, setChangeDate) — nil если событие не найдено.
        func findLastRewindAndSetChange(maxPages: UInt8 = 16) async throws -> (rewindDate: Date?, setChangeDate: Date?) {
            // Используем distantPast как startDate — timestampedEvents вернёт ВСЕ
            // события страницы (ни одно не отсекается по дате), hasMoreEvents = true.
            let epoch = Date.distantPast
            var latestRewind: Date?
            var latestSetChange: Date?

            var hadError = false
            for pageIndex in 0 ..< maxPages {
                let raw: Data
                do {
                    raw = try await client.getHistory(page: pageIndex)
                } catch {
                    // Слабый сигнал / firmware-сбой на этой странице — НЕ бросаем весь
                    // скан, пробуем следующую. Помечаем, что скан получился неполным.
                    hadError = true
                    continue
                }
                guard let (events, _) = try? decode(raw, after: epoch) else {
                    hadError = true
                    continue
                }
                let pumpEvents = events.pumpEvents(from: pumpModel)

                for event in pumpEvents {
                    switch event.type {
                    case .rewind:
                        if latestRewind == nil || event.date > latestRewind! {
                            latestRewind = event.date
                        }
                    case .replaceComponent(componentType: .infusionSet):
                        if latestSetChange == nil || event.date > latestSetChange! {
                            latestSetChange = event.date
                        }
                    default:
                        break
                    }
                }

                // Оба события найдены — дальше читать не нужно.
                if latestRewind != nil, latestSetChange != nil {
                    break
                }
            }

            // Ничего не нашли И были сбои чтения — бросаем, чтобы вызывающий не помечал
            // backfillDone=true с пустотой (иначе «Возраст» скрыт навсегда) и повторил позже.
            if latestRewind == nil, latestSetChange == nil, hadError {
                throw SmartBridgeError.timeout
            }

            return (latestRewind, latestSetChange)
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
