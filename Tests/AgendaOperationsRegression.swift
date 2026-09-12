// Compiled and executed by the macOS workflow; no network, account or OS notifications.
import Foundation

@main
struct AgendaOperationsRegression {
    @MainActor
    static func main() throws {
        NSTimeZone.default = TimeZone(identifier: "Europe/Rome")!
        let suite = "AgendaOperationsRegression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgendaStore(defaults: defaults, loadSession: { nil })
        store.events = []
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func rejects(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure("Expected rejection: " + message) }
            catch { checks += 1 }
        }
        func date(_ key: String, _ slot: Int) throws -> Date { try AgendaTime.date(key: key, slot: slot) }
        let id = UUID(), templateID = UUID()
        let legacyJSON = """
        {"id":"\(id)","templateID":"\(templateID)","name":"Palestra","durationSlots":4,"colorHex":"#BFE5C5","dateKey":"2030-01-10","startSlot":40}
        """
        var gym = try JSONDecoder().decode(AgendaEvent.self, from: Data(legacyJSON.utf8))
        check(gym.notes == nil && gym.latitude == nil && gym.priority == nil && gym.seriesID == nil, "Old event JSON must decode")
        let legacyBlock = """
        {"id":"\(templateID)","name":"Palestra","durationSlots":4,"colorHex":"#BFE5C5"}
        """
        var block = try JSONDecoder().decode(BlockTemplate.self, from: Data(legacyBlock.utf8))
        check(block.notes == nil && block.category == nil, "Old template JSON must decode")
        gym.notes = "Portare scarpe"; gym.location = "Eden Bibbiano"
        gym.latitude = 44.662; gym.longitude = 10.474; gym.priority = 3; gym.category = "Sport"
        gym.reminderMinutes = 17
        block.notes = gym.notes; block.latitude = gym.latitude; block.longitude = gym.longitude
        block.category = gym.category; block.priority = gym.priority
        let payload = AgendaPayload(templates: [block], events: [gym])
        let decoded = try JSONDecoder().decode(AgendaPayload.self, from: JSONEncoder().encode(payload))
        check(decoded == payload, "Sync payload must round-trip all optional metadata")
        try store.insertEvents([gym])
        let reloaded = AgendaStore(defaults: defaults, loadSession: { nil })
        check(reloaded.events == [gym], "Metadata survives local persistence")
        for minutes in [15, 30, 45, 60, 75, -15, -30, -45, -60, -75] {
            let moved = try store.shifted(gym, minutes: minutes)
            check(moved.startSlot == gym.startSlot + minutes / 15 && moved.durationSlots == gym.durationSlots && moved.notes == gym.notes, "Shift preserves duration and metadata")
        }
        rejects("non-grid shift") { _ = try store.shifted(gym, minutes: 17) }
        rejects("non-grid duration") { _ = try AgendaTime.slots(17) }
        rejects("negative duration") { _ = try AgendaTime.slots(-15) }
        rejects("zero duration") { _ = try AgendaTime.slots(0) }
        rejects("overflow input") { _ = try AgendaTime.slots(Int.max, signed: true) }
        var midnightEvent = gym; midnightEvent.startSlot = -32
        let previousDay = try store.shifted(midnightEvent, minutes: -60)
        check(previousDay.dateKey == "2030-01-09" && previousDay.startSlot == 60, "Shift crosses date backwards")
        let followingDay = try store.shifted(gym, minutes: 1440)
        check(followingDay.dateKey == "2030-01-11" && followingDay.startSlot == gym.startSlot, "Shift crosses date forwards")
        var invalid = gym; invalid.durationSlots = 0
        rejects("zero event duration") { try store.commitEvent(invalid) }
        invalid.durationSlots = 30
        rejects("cross-midnight duration") { try store.commitEvent(invalid) }
        check(store.events == [gym], "Rejected changes leave storage untouched")
        var collision = gym; collision.id = UUID(); collision.startSlot = 44
        try store.insertEvents([collision])
        var longer = gym; longer.durationSlots = 6
        rejects("extension overlaps") { try store.commitEvent(longer) }
        var shorter = gym; shorter.durationSlots = 2
        try store.commitEvent(shorter)
        check(try store.requireEvent(gym.id).durationSlots == 2, "Shorten commits")
        shorter.reminderMinutes = nil
        try store.commitEvent(shorter)
        check(try store.requireEvent(gym.id).reminderMinutes == nil, "Remove reminder")
        shorter.reminderMinutes = -1
        rejects("negative reminder") { try store.commitEvent(shorter) }
        rejects("half coordinates") { try AgendaTime.metadata(reminder: nil, latitude: 45, longitude: nil, priority: nil) }
        rejects("bad coordinates") { try AgendaTime.metadata(reminder: nil, latitude: .nan, longitude: 0, priority: nil) }
        rejects("bad priority") { try AgendaTime.metadata(reminder: nil, latitude: nil, longitude: nil, priority: 4) }
        let copies = try store.copies(of: gym, firstStart: date("2030-01-11", 40), count: 3, intervalDays: 7)
        check(Set(copies.map(\.id)).count == 3 && copies[0].seriesID != nil && Set(copies.compactMap(\.seriesID)).count == 1, "Copies have new IDs and one new series")
        check(copies[2].dateKey == "2030-01-25" && copies[0].notes == gym.notes && copies[0].reminderMinutes == 17, "Weekly copies retain metadata")
        try store.insertEvents(copies)
        let before = store.events
        let batch = try store.copies(of: gym, firstStart: date("2030-01-04", 40), count: 2, intervalDays: 7)
        rejects("second copy overlaps, no partial batch") { try store.insertEvents(batch) }
        check(store.events == before, "Batch is atomic")
        try store.removeEvents([copies[1]])
        check(store.events.contains(where: { $0.id == copies[0].id }) && !store.events.contains(where: { $0.id == copies[1].id }), "Skip only selected occurrence")
        rejects("excessive recurrence") { _ = try store.copies(of: gym, firstStart: date("2030-02-01", 40), count: 105, intervalDays: 7) }
        let free = try store.nextFreeStart(after: date("2030-01-10", 40), durationSlots: 4, fromHour: 18, toHour: 22, days: 1)
        check(try AgendaTime.slot(free) == 48, "Search skips busy intervals")
        let afterSeconds = try date("2030-01-12", 0).addingTimeInterval(1)
        let rounded = try store.nextFreeStart(after: afterSeconds, durationSlots: 4, fromHour: 8, toHour: 20, days: 1)
        check(try AgendaTime.slot(rounded) == 1, "Search rounds lower bound forward, never into past")
        rejects("invalid free search range") { _ = try store.nextFreeStart(after: free, durationSlots: 4, fromHour: 20, toHour: 8, days: 1) }
        rejects("no space in chosen window") { _ = try store.nextFreeStart(after: date("2030-01-10", 40), durationSlots: 8, fromHour: 18, toHour: 20, days: 1) }
        // Rome changes to summer time on 2030-03-31: 02:00 does not exist.
        rejects("nonexistent DST time") { _ = try date("2030-03-31", -24) }
        let spring = try store.copies(of: gym, firstStart: date("2030-03-30", 40), count: 3, intervalDays: 1)
        check(spring.map(\.startSlot) == [40, 40, 40] && spring[1].dateKey == "2030-03-31", "Recurrence preserves local clock across DST")
        let midnight = try date("2030-01-10", 64)
        check(AgendaTime.key(midnight) == "2030-01-11", "24:00 means next midnight")
        if case .shift(let name, let m) = try AgendaVoiceCommand.parse("sposta Palestra avanti di 15 minuti") { check(name == "Palestra" && m == 15, "Italian shift") } else { preconditionFailure() }
        if case .shift(_, let m) = try AgendaVoiceCommand.parse("anticipa Studio di mezz’ora") { check(m == -30, "Italian half hour") } else { preconditionFailure() }
        if case .resize(_, let m) = try AgendaVoiceCommand.parse("allunga Lezione di 30 minuti") { check(m == 30, "Italian extension") } else { preconditionFailure() }
        if case .create(let name, let day, let h, let m, let duration, let reminder, let location) = try AgendaVoiceCommand.parse("metti Palestra domani alle 18 per un'ora con promemoria 15 minuti prima e luogo Eden Bibbiano") {
            check(name == "Palestra" && day == "domani" && h == 18 && m == 0 && duration == 60 && reminder == 15 && location == "Eden Bibbiano", "Complete Italian creation phrase")
        } else { preconditionFailure() }
        rejects("unknown voice grammar") { _ = try AgendaVoiceCommand.parse("cancella tutto senza chiedere") }
        let healthyEvents = store.events
        store.cacheHealthy = false
        rejects("unhealthy cache") { try store.removeEvents(healthyEvents) }
        check(store.events == healthyEvents, "Unhealthy cache never mutated")
        print("PASS: \(checks) agenda regression checks, old JSON decoding, persistence, metadata, shifts, bounds, conflicts, batch atomicity, recurrence, slots, DST and Italian commands.")
    }
}
