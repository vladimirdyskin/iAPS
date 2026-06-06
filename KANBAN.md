---
kanban-plugin: board
tags: [code, kanban, project, iAPS, picklelink]
---

## Backlog

- [ ] 🔴 **Unfinalized doses are never reported to LoopKit as pump events — IOB undercount until async history walk** `PickleLinkPumpManager.swift:265-270, 305-309, 414-431`
- [ ] 🔴 **enactBolus drops an already-delivered dose when post-bolus status reports !bolusing (reports failure, never records IOB)** `PickleLinkPumpManager.swift:254-271`
- [ ] 🟠 **Temp basal always sent as absolute mU/h without checking the pump's tempBasalType (percent vs absolute)** `PickleLinkPumpManager.swift:301-309`
- [ ] 🟠 **No bolus-cancel path despite firmware SUSPEND (0x0E) — patient cannot abort an in-progress overdelivery** `PickleLinkPumpManager.swift:280-283`
- [ ] 🟠 **syncHistory targeted window misses newer events after the 36-page history ring wraps** `HistorySync.swift:36-47`
- [ ] 🟠 **didDisconnectPeripheral unconditionally auto-reconnects — explicit disconnect/deactivation cannot stick** `PickleLinkBLEManager.swift:122-132`
- [ ] 🟠 **BLE manager shared dictionaries mutated from CB main queue AND arbitrary caller queues without synchronization (data race/crash)** `PickleLinkBLEManager.swift:24-31, 57-69, 99-110, 122-132`
- [ ] 🟠 **willRestoreState rebuilds connected[] but never discovers characteristics or fires didConnect — restored link is inert / client stays nil** `PickleLinkBLEManager.swift:77-84`
- [ ] 🟠 **PickleLinkPeripheral.pendingWrite continuation raced/double-resumed across CB main queue and CommandSession actor thread** `PickleLinkPeripheral.swift:12-17, 47-60, 91-104, 131-138`
- [ ] 🟠 **sendCommand evicts a prior in-flight write with .notConnected under concurrent commands — bolus/temp-basal mis-reported** `PickleLinkPeripheral.swift:49-59`
- [ ] 🟠 **CommandSession.send awaits the write inline before group.next() — the in-session timeout cannot cover a hung write** `CommandSession.swift:41-57`
- [ ] 🟠 **CommandSession registers outstanding[seq] in a concurrently-scheduled task — a fast reply arrives before registration and is dropped** `CommandSession.swift:41-57, 72-89`
- [ ] 🟡 **lastSync returns lastRadioErrorAt — a failure timestamp, never the last successful sync** `PickleLinkPumpManager.swift:193`
- [ ] 🟡 **Unfinalized doses are never finalized/cleared — stale doses persist in rawValue across relaunches** `PickleLinkPumpManager.swift:270, 309`
- [ ] 🟡 **No status-update notification when a dose merely finishes — observers stuck showing 'inProgress'** `PickleLinkPumpManager.swift:85-131`
- [ ] 🟡 **Status observer collections (NSHashTable + Swift Dictionary) mutated without the lock (data race/crash)** `PickleLinkPumpManager.swift:126-130, 215-223`
- [ ] 🟡 **ensureCurrentPumpData overwrites suspendState date with Date() on every poll, losing the true suspend time** `PickleLinkPumpManager.swift:348-352`
- [ ] 🟡 **Fragment reassembly: no buffer-size/count cap (device-driven memory pressure)** `CommandSession.swift:106-113`
- [ ] 🟡 **Fragment index never validated — dup/out-of-order/skipped fragments silently corrupt payload; status check bypassable** `CommandSession.swift:84-114`
- [ ] 🟡 **Use-after-disconnect: disconnect(id:) leaks a connecting peripheral and a stale sendCommand hangs forever** `PickleLinkBLEManager.swift:65-69, 128`
- [ ] 🟡 **didReceiveResponse spawns one unstructured Task per BLE notify — multi-fragment responses can reassemble out of order** `PickleLinkPeripheral.swift:106-123`
- [ ] 💡 Defense-in-depth: clamp/snap bolus & temp-basal to the pump grid and maxima in the driver `PickleLinkConversions.swift`
- [ ] 💡 Add a programmed>0 guard in DoseProgressEstimator.progress to mirror the timer-path guard `DoseProgressEstimator.swift`
- [ ] 💡 Document the delegate delivery-queue contract for PickleLinkBLEManagerDelegate `PickleLinkBLEManager.swift`
- [ ] 💡 Replace force-unwrap of error in CBPeripheralDelegate failure paths `PickleLinkPeripheral.swift`
- [ ] 💡 EndianRead allocates a full [UInt8] copy per call — O(N^2) decode on attacker-influenced payloads `SmartBridgeResponse.swift`
- [ ] 💡 Remove or lock the dead bolusProgressEstimator stored property `PickleLinkPumpManager.swift`
- [ ] 💡 Skip occupied seq values when allocating (cheap hardening) and read/migrate the state version `CommandSession.swift`

## In Progress

## Review

## Done

%% kanban:settings
```
{"kanban-plugin":"board","list-collapse":[false,false,false,false]}
```
%%