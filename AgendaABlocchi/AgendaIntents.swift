import Foundation
import AppIntents

extension Notification.Name {
    static let agendaIntentDidModifyData = Notification.Name("it.agendaablocchi.intentDidModifyData")
}

enum AgendaIntentFailure: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

enum AgendaColorChoice: String, AppEnum {
    case azzurro
    case rosa
    case verde
    case giallo
    case lilla
    case arancio
    case grigio
    case turchese

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Colore"
    static var caseDisplayRepresentations: [AgendaColorChoice: DisplayRepresentation] = [
        .azzurro: "Azzurro",
        .rosa: "Rosa",
        .verde: "Verde",
        .giallo: "Giallo",
        .lilla: "Lilla",
        .arancio: "Arancio",
        .grigio: "Grigio",
        .turchese: "Turchese"
    ]

    var hex: String {
        switch self {
        case .azzurro: return "#B8DFF5"
        case .rosa: return "#F2B6C8"
        case .verde: return "#BFE5C5"
        case .giallo: return "#FFE59A"
        case .lilla: return "#D9C2F0"
        case .arancio: return "#F7C59F"
        case .grigio: return "#D7DCE2"
        case .turchese: return "#AEE5E2"
        }
    }
}

enum AgendaShiftDirection: String, AppEnum {
    case avanti
    case indietro

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Direzione"
    static var caseDisplayRepresentations: [AgendaShiftDirection: DisplayRepresentation] = [
        .avanti: "Avanti",
        .indietro: "Indietro"
    ]

    var sign: Int { self == .avanti ? 1 : -1 }
}

struct AgendaBlockEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Blocco riutilizzabile"
    static var defaultQuery = AgendaBlockQuery()

    let id: UUID
    let name: String
    let durationSlots: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(AgendaIntentBridge.durationText(slots: durationSlots))"
        )
    }
}

struct AgendaBlockQuery: EntityStringQuery {
    func entities(for identifiers: [AgendaBlockEntity.ID]) async throws -> [AgendaBlockEntity] {
        await MainActor.run {
            let ids = Set(identifiers)
            return AgendaStore().templates
                .filter { ids.contains($0.id) }
                .map { AgendaBlockEntity(id: $0.id, name: $0.name, durationSlots: $0.durationSlots) }
        }
    }

    func entities(matching string: String) async throws -> [AgendaBlockEntity] {
        await MainActor.run {
            AgendaStore().templates
                .filter { $0.name.localizedCaseInsensitiveContains(string) }
                .map { AgendaBlockEntity(id: $0.id, name: $0.name, durationSlots: $0.durationSlots) }
        }
    }

    func suggestedEntities() async throws -> [AgendaBlockEntity] {
        await MainActor.run {
            AgendaStore().templates.map {
                AgendaBlockEntity(id: $0.id, name: $0.name, durationSlots: $0.durationSlots)
            }
        }
    }
}

struct AgendaEventEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Impegno"
    static var defaultQuery = AgendaEventQuery()

    let id: UUID
    let name: String
    let dateKey: String
    let startSlot: Int
    let durationSlots: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(AgendaIntentBridge.entitySubtitle(dateKey: dateKey, startSlot: startSlot))"
        )
    }
}

struct AgendaEventQuery: EntityStringQuery {
    func entities(for identifiers: [AgendaEventEntity.ID]) async throws -> [AgendaEventEntity] {
        await MainActor.run {
            let ids = Set(identifiers)
            return AgendaStore().events
                .filter { ids.contains($0.id) }
                .map(AgendaIntentBridge.eventEntity)
        }
    }

    func entities(matching string: String) async throws -> [AgendaEventEntity] {
        await MainActor.run {
            AgendaStore().events
                .filter { $0.name.localizedCaseInsensitiveContains(string) }
                .sorted(by: AgendaIntentBridge.eventSort)
                .prefix(40)
                .map(AgendaIntentBridge.eventEntity)
        }
    }

    func suggestedEntities() async throws -> [AgendaEventEntity] {
        await MainActor.run {
            let store = AgendaStore()
            let now = Date()
            return store.events
                .filter { (AgendaIntentBridge.eventDate($0) ?? .distantPast) >= Calendar.current.date(byAdding: .day, value: -1, to: now)! }
                .sorted(by: AgendaIntentBridge.eventSort)
                .prefix(40)
                .map(AgendaIntentBridge.eventEntity)
        }
    }
}

@MainActor
enum AgendaIntentBridge {
    static func makeStore() -> AgendaStore {
        AgendaStore()
    }

    static func dialog(_ text: String) -> IntentDialog {
        IntentDialog(LocalizedStringResource(stringLiteral: text))
    }

    static func spokenResult(_ text: String) -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        .result(value: text, dialog: dialog(text))
    }

    static func notifyMutation() {
        NotificationCenter.default.post(name: .agendaIntentDidModifyData, object: nil)
    }

    static func finishMutation(_ store: AgendaStore) async {
        // AgendaStore starts an automatic sync after every local edit. Give that task a
        // chance to finish, then explicitly retry if the cache is still dirty.
        for _ in 0..<30 {
            if !store.syncBusy { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if store.dirty && !store.syncBusy {
            await store.synchronize()
        }
        // Refresh parameterized Siri phrases when reusable blocks change.
        AgendaAppShortcuts.updateAppShortcutParameters()
        notifyMutation()
    }

    static func dateKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func slot(for date: Date) throws -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else {
            throw AgendaIntentFailure.message("Non riesco a leggere l'orario.")
        }
        let minutesFromMidnight = hour * 60 + minute
        let relative = Double(minutesFromMidnight - 8 * 60) / 15.0
        let slot = Int(relative.rounded())
        guard (-32..<64).contains(slot) else {
            throw AgendaIntentFailure.message("L'orario deve essere compreso tra mezzanotte e le 23:45.")
        }
        return slot
    }

    static func slots(minutes: Int) throws -> Int {
        guard minutes > 0 else {
            throw AgendaIntentFailure.message("La durata deve essere maggiore di zero.")
        }
        return max(1, Int(ceil(Double(minutes) / 15.0)))
    }

    static func slots(from start: Date, to end: Date) throws -> Int {
        let seconds = end.timeIntervalSince(start)
        guard seconds > 0 else {
            throw AgendaIntentFailure.message("L'orario di fine deve essere successivo all'inizio.")
        }
        return try slots(minutes: Int(ceil(seconds / 60.0)))
    }

    static func eventDate(_ event: AgendaEvent) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: event.dateKey) else { return nil }
        let minutes = 8 * 60 + event.startSlot * 15
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    static func eventSort(_ lhs: AgendaEvent, _ rhs: AgendaEvent) -> Bool {
        (eventDate(lhs) ?? .distantFuture) < (eventDate(rhs) ?? .distantFuture)
    }

    static func eventEntity(_ event: AgendaEvent) -> AgendaEventEntity {
        AgendaEventEntity(
            id: event.id,
            name: event.name,
            dateKey: event.dateKey,
            startSlot: event.startSlot,
            durationSlots: event.durationSlots
        )
    }

    nonisolated static func durationText(slots: Int) -> String {
        let total = slots * 15
        let hours = total / 60
        let minutes = total % 60
        if hours > 0 && minutes > 0 { return "\(hours) h \(minutes) min" }
        if hours > 0 { return "\(hours) h" }
        return "\(minutes) min"
    }

    nonisolated static func timeText(slot: Int) -> String {
        let total = 8 * 60 + slot * 15
        let normalized = (total % (24 * 60) + 24 * 60) % (24 * 60)
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }

    nonisolated static func entitySubtitle(dateKey: String, startSlot: Int) -> String {
        let input = DateFormatter()
        input.calendar = Calendar(identifier: .gregorian)
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: dateKey) else {
            return "\(dateKey) · \(timeText(slot: startSlot))"
        }
        let output = DateFormatter()
        output.locale = Locale(identifier: "it_IT")
        output.dateFormat = "EEE d MMM"
        return "\(output.string(from: date)) · \(timeText(slot: startSlot))"
    }

    static func spokenDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateFormat = "EEEE d MMMM 'alle' HH:mm"
        return formatter.string(from: date)
    }

    static func matchingTemplate(named name: String, in store: AgendaStore) -> BlockTemplate? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.templates.first { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    @discardableResult
    static func addCustomEvent(
        to store: AgendaStore,
        name: String,
        start: Date,
        durationSlots: Int,
        repeatWeeks: Int?,
        reminderMinutes: Int?,
        location: String?
    ) throws -> AgendaEvent {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AgendaIntentFailure.message("Dimmi un nome per l'impegno.")
        }

        let startSlot = try slot(for: start)
        guard startSlot + durationSlots <= 64 else {
            throw AgendaIntentFailure.message("L'impegno supererebbe la mezzanotte.")
        }

        var template = matchingTemplate(named: trimmed, in: store) ?? BlockTemplate(
            id: UUID(),
            name: trimmed,
            durationSlots: durationSlots,
            colorHex: "#B8DFF5",
            repeatWeeks: nil,
            reminderMinutes: nil,
            location: nil
        )
        template.name = trimmed
        template.durationSlots = durationSlots
        if let repeatWeeks { template.repeatWeeks = max(1, repeatWeeks) }
        if let reminderMinutes { template.reminderMinutes = max(0, reminderMinutes) }
        if let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            template.location = location
        }

        let oldIDs = Set(store.events.map(\.id))
        if let error = store.addEvent(template: template, dateKey: dateKey(start), startSlot: startSlot) {
            throw AgendaIntentFailure.message(error)
        }
        guard let created = store.events.first(where: { !oldIDs.contains($0.id) }) else {
            throw AgendaIntentFailure.message("Non sono riuscito a creare l'impegno.")
        }
        return created
    }

    static func dayEvents(_ store: AgendaStore, date: Date) -> [AgendaEvent] {
        store.events(on: dateKey(date))
    }

    static func daySummary(_ store: AgendaStore, date: Date) -> String {
        let events = dayEvents(store, date: date)
        let day = DateFormatter()
        day.locale = Locale(identifier: "it_IT")
        day.dateFormat = "EEEE d MMMM"
        let heading = day.string(from: date)
        guard !events.isEmpty else { return "Per \(heading) non hai impegni in Agenda a Blocchi." }
        let lines = events.map { event in
            "\(timeText(slot: event.startSlot)) \(event.name)"
        }
        return "Per \(heading): " + lines.joined(separator: "; ") + "."
    }

    static func freeIntervals(store: AgendaStore, date: Date, minimumMinutes: Int, fromHour: Int, toHour: Int) throws -> [(Int, Int)] {
        guard (0...23).contains(fromHour), (1...24).contains(toHour), toHour > fromHour else {
            throw AgendaIntentFailure.message("L'intervallo orario non è valido.")
        }
        let minimumSlots = try slots(minutes: minimumMinutes)
        let rangeStart = Int((Double(fromHour * 60 - 8 * 60) / 15.0).rounded())
        let rangeEnd = Int((Double(toHour * 60 - 8 * 60) / 15.0).rounded())
        let busy = dayEvents(store, date: date)
            .map { (max(rangeStart, $0.startSlot), min(rangeEnd, $0.startSlot + $0.durationSlots)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }

        var merged: [(Int, Int)] = []
        for interval in busy {
            if let last = merged.last, interval.0 <= last.1 {
                merged[merged.count - 1].1 = max(last.1, interval.1)
            } else {
                merged.append(interval)
            }
        }

        var cursor = rangeStart
        var free: [(Int, Int)] = []
        for interval in merged {
            if interval.0 - cursor >= minimumSlots { free.append((cursor, interval.0)) }
            cursor = max(cursor, interval.1)
        }
        if rangeEnd - cursor >= minimumSlots { free.append((cursor, rangeEnd)) }
        return free
    }

    static func event(named name: String, in store: AgendaStore) -> AgendaEvent? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        let matching = store.events.filter { event in
            event.name.compare(needle, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame ||
            event.name.localizedCaseInsensitiveContains(needle) ||
            needle.localizedCaseInsensitiveContains(event.name)
        }
        return matching
            .sorted { lhs, rhs in
                let ld = eventDate(lhs) ?? .distantFuture
                let rd = eventDate(rhs) ?? .distantFuture
                let lFuture = ld >= now
                let rFuture = rd >= now
                if lFuture != rFuture { return lFuture }
                return abs(ld.timeIntervalSince(now)) < abs(rd.timeIntervalSince(now))
            }
            .first
    }

    static func eventRangeText(_ event: AgendaEvent) -> String {
        "\(event.name) dalle \(timeText(slot: event.startSlot)) alle \(timeText(slot: event.startSlot + event.durationSlots))"
    }

    static func dateByShifting(_ event: AgendaEvent, minutes: Int) throws -> Date {
        guard let date = eventDate(event),
              let shifted = Calendar.current.date(byAdding: .minute, value: minutes, to: date) else {
            throw AgendaIntentFailure.message("Non riesco a calcolare il nuovo orario.")
        }
        return shifted
    }

    static func nextFreeStart(
        store: AgendaStore,
        date: Date,
        durationSlots: Int,
        fromHour: Int,
        toHour: Int,
        excluding eventID: UUID? = nil
    ) throws -> Int? {
        guard (0...23).contains(fromHour), (1...24).contains(toHour), toHour > fromHour else {
            throw AgendaIntentFailure.message("L’intervallo orario non è valido.")
        }
        let rangeStart = Int((Double(fromHour * 60 - 8 * 60) / 15.0).rounded())
        let rangeEnd = Int((Double(toHour * 60 - 8 * 60) / 15.0).rounded())
        let dateKey = dateKey(date)
        let busy = store.events(on: dateKey)
            .filter { $0.id != eventID }
            .sorted { $0.startSlot < $1.startSlot }

        var cursor = rangeStart
        for item in busy {
            if cursor + durationSlots <= item.startSlot { return cursor }
            cursor = max(cursor, item.startSlot + item.durationSlots)
        }
        return cursor + durationSlots <= rangeEnd ? cursor : nil
    }

    static func dateFor(dateKey: String, slot: Int) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: dateKey) else { return nil }
        let minutes = 8 * 60 + slot * 15
        return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "it_IT"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func minutesMentioned(in text: String) -> Int? {
        let value = normalized(text)
        if value.contains("un quarto d'ora") || value.contains("un quarto d’ora") { return 15 }
        if value.contains("un'ora e mezza") || value.contains("un’ora e mezza") || value.contains("una ora e mezza") { return 90 }
        if value.contains("due ore") || value.contains("2 ore") { return 120 }
        if value.contains("tre ore") || value.contains("3 ore") { return 180 }
        if value.contains("quattro ore") || value.contains("4 ore") { return 240 }
        if value.contains("mezz'ora") || value.contains("mezz’ora") || value.contains("mezza ora") { return 30 }
        if value.contains("un'ora") || value.contains("un’ora") || value.contains("una ora") || value.contains("1 ora") { return 60 }
        let pattern = #"(\d{1,3})\s*(minuti|minuto|min)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range(at: 1), in: value) {
            return Int(value[range])
        }
        return nil
    }

    static func hourMentioned(in text: String, baseDate: Date) -> Date? {
        let normalized = normalized(text)
        let pattern = #"(?:alle|ore)\s*(\d{1,2})(?:[:\.]([0-5]\d))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let hourRange = Range(match.range(at: 1), in: normalized),
              let hour = Int(normalized[hourRange]), (0...23).contains(hour) else { return nil }
        var minute = 0
        if match.range(at: 2).location != NSNotFound,
           let minuteRange = Range(match.range(at: 2), in: normalized) {
            minute = Int(normalized[minuteRange]) ?? 0
        }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: baseDate)
    }

    static func dayMentioned(in text: String) -> Date {
        let value = normalized(text)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if value.contains("dopodomani") { return calendar.date(byAdding: .day, value: 2, to: today) ?? today }
        if value.contains("domani") { return calendar.date(byAdding: .day, value: 1, to: today) ?? today }
        if value.contains("oggi") { return today }

        let names: [(String, Int)] = [
            ("domenica", 1), ("lunedi", 2), ("martedi", 3), ("mercoledi", 4),
            ("giovedi", 5), ("venerdi", 6), ("sabato", 7)
        ]
        if let targetWeekday = names.first(where: { value.contains($0.0) })?.1 {
            let currentWeekday = calendar.component(.weekday, from: today)
            var delta = (targetWeekday - currentWeekday + 7) % 7
            if delta == 0 && value.contains("prossim") { delta = 7 }
            return calendar.date(byAdding: .day, value: delta, to: today) ?? today
        }
        return today
    }

    static func colorMentioned(in text: String) -> AgendaColorChoice? {
        let value = normalized(text)
        let aliases: [(AgendaColorChoice, [String])] = [
            (.azzurro, ["azzurro", "blu", "celeste"]),
            (.rosa, ["rosa", "fucsia"]),
            (.verde, ["verde"]),
            (.giallo, ["giallo"]),
            (.lilla, ["lilla", "viola"]),
            (.arancio, ["arancio", "arancione"]),
            (.grigio, ["grigio"]),
            (.turchese, ["turchese"])
        ]
        return aliases.first { item in item.1.contains(where: { value.contains($0) }) }?.0
    }

    static func reminderMentioned(in text: String) -> Int? {
        let value = normalized(text)
        let anchors = ["promemoria", "ricord", "avvis"]
        guard let anchor = anchors.compactMap({ value.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) else { return nil }
        let tail = String(value[anchor.lowerBound...])
        return minutesMentioned(in: tail) ?? 15
    }

    static func locationMentioned(in text: String) -> String? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized(original)
        let anchors = [" luogo ", " presso ", " posto "]
        for anchor in anchors {
            guard let range = value.range(of: anchor) else { continue }
            let offset = value.distance(from: value.startIndex, to: range.upperBound)
            let idx = original.index(original.startIndex, offsetBy: min(offset, original.count))
            var tail = String(original[idx...]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            for stop in [" con promemoria", " promemoria", " per ", " e promemoria"] {
                if let cut = tail.lowercased().range(of: stop) { tail = String(tail[..<cut.lowerBound]) }
            }
            if !tail.isEmpty { return tail }
        }
        return nil
    }

    static func repeatWeeksMentioned(in text: String) -> Int? {
        let value = normalized(text)
        guard value.contains("settim") || value.contains("ripet") else { return nil }
        let pattern = #"(\d{1,2})\s*settim"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range(at: 1), in: value) {
            return max(1, Int(value[range]) ?? 1)
        }
        if value.contains("ogni settimana") || value.contains("settimanale") { return 2 }
        return nil
    }

    static func duplicateEvent(_ event: AgendaEvent, in store: AgendaStore, dateKey: String, startSlot: Int) throws -> AgendaEvent {
        let template = BlockTemplate(
            id: event.templateID,
            name: event.name,
            durationSlots: event.durationSlots,
            colorHex: event.colorHex,
            repeatWeeks: nil,
            reminderMinutes: event.reminderMinutes,
            location: event.location
        )
        let oldIDs = Set(store.events.map(\.id))
        if let error = store.addEvent(template: template, dateKey: dateKey, startSlot: startSlot) {
            throw AgendaIntentFailure.message(error)
        }
        guard let created = store.events.first(where: { !oldIDs.contains($0.id) }) else {
            throw AgendaIntentFailure.message("Non sono riuscito a duplicare l'impegno.")
        }
        return created
    }

    static func templateMentioned(in text: String, store: AgendaStore) -> BlockTemplate? {
        let normalizedText = normalized(text)
        return store.templates
            .sorted { $0.name.count > $1.name.count }
            .first { normalizedText.contains(normalized($0.name)) }
    }

    static func eventMentioned(in text: String, store: AgendaStore) -> AgendaEvent? {
        let normalizedText = normalized(text)
        let candidates = store.events.filter { normalizedText.contains(normalized($0.name)) }
        let now = Date()
        return candidates.sorted { lhs, rhs in
            let ld = eventDate(lhs) ?? .distantFuture
            let rd = eventDate(rhs) ?? .distantFuture
            let lf = ld >= now
            let rf = rd >= now
            if lf != rf { return lf }
            return abs(ld.timeIntervalSince(now)) < abs(rd.timeIntervalSince(now))
        }.first
    }

    static func timeMentions(in text: String, baseDate: Date) -> [Date] {
        let value = normalized(text)
        let pattern = #"(?:dalle|alle|ore)\s*(\d{1,2})(?:[:\.]([0-5]\d))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let hourRange = Range(match.range(at: 1), in: value),
                  let hour = Int(value[hourRange]), (0...23).contains(hour) else { return nil }
            var minute = 0
            if match.range(at: 2).location != NSNotFound,
               let minuteRange = Range(match.range(at: 2), in: value) {
                minute = Int(value[minuteRange]) ?? 0
            }
            return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: baseDate)
        }
    }

    static func durationMinutesMentioned(in text: String) -> Int? {
        var value = normalized(text)
        // A reminder often contains a number of minutes; don't confuse it with event duration.
        for anchor in [" promemoria", " ricord", " avvis"] {
            if let cut = value.range(of: anchor) {
                value = String(value[..<cut.lowerBound])
            }
        }
        if value.contains("un quarto d'ora") || value.contains("un quarto d’ora") { return 15 }
        if value.contains("mezz'ora") || value.contains("mezz’ora") || value.contains("mezza ora") { return 30 }
        if value.contains("un'ora e mezza") || value.contains("un’ora e mezza") || value.contains("una ora e mezza") { return 90 }
        if value.contains("due ore") || value.contains("2 ore") { return 120 }
        if value.contains("tre ore") || value.contains("3 ore") { return 180 }
        if value.contains("quattro ore") || value.contains("4 ore") { return 240 }
        if value.contains("un'ora") || value.contains("un’ora") || value.contains("una ora") || value.contains("1 ora") { return 60 }
        let pattern = #"(?:per|durata(?: di)?)\s*(\d{1,3})\s*(minuti|minuto|min)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
           let range = Range(match.range(at: 1), in: value) {
            return Int(value[range])
        }
        return nil
    }

    static func guessedNewEventName(in text: String) -> String? {
        let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized(original)
        let anchors = [
            "evento chiamato ", "evento chiamata ", "impegno chiamato ", "appuntamento chiamato ",
            "crea un evento ", "crea evento ", "aggiungi un evento ", "aggiungi evento ",
            "crea un impegno ", "aggiungi un impegno ", "programma un evento ", "programma evento ",
            "inserisci un evento ", "inserisci evento ", "appuntamento "
        ]
        for anchor in anchors {
            guard let range = value.range(of: anchor) else { continue }
            var tail = String(value[range.upperBound...])
            let stops = [
                " oggi", " domani", " dopodomani", " lunedi", " martedi", " mercoledi", " giovedi", " venerdi", " sabato", " domenica",
                " alle ", " dalle ", " ore ", " per ", " con ", " presso ", " luogo ", " promemoria ", " durata "
            ]
            if let cut = stops.compactMap({ tail.range(of: $0)?.lowerBound }).min() {
                tail = String(tail[..<cut])
            }
            let cleaned = tail.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !cleaned.isEmpty {
                return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
            }
        }
        return nil
    }

    static func guessedNewBlockName(in text: String) -> String? {
        let normalizedText = normalized(text)
        let anchors = ["chiamato ", "chiamata ", "blocco preimpostato ", "blocco riutilizzabile ", "nuovo blocco ", "crea un blocco ", "crea blocco "]
        for anchor in anchors {
            guard let range = normalizedText.range(of: anchor) else { continue }
            var tail = String(normalizedText[range.upperBound...])
            let stops = [" da ", " di ", " durata ", " con ", " per ", " colore ", " promemoria ", " luogo "]
            if let cut = stops.compactMap({ tail.range(of: $0)?.lowerBound }).min() {
                tail = String(tail[..<cut])
            }
            let cleaned = tail.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if !cleaned.isEmpty {
                return cleaned.prefix(1).uppercased() + cleaned.dropFirst()
            }
        }
        return nil
    }
}

struct AddReusableBlockToAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Programma blocco preimpostato"
    static var description = IntentDescription("Inserisce nel calendario un blocco preimpostato già esistente. Questa azione programma un evento; non crea un nuovo blocco preimpostato.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Inizio", kind: .dateTime) var start: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Aggiungi \(\.$block) alle \(\.$start)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let template = store.templates.first(where: { $0.id == block.id }) else {
            throw AgendaIntentFailure.message("Quel blocco non esiste più. Apri l'app e riprova.")
        }
        let startSlot = try AgendaIntentBridge.slot(for: start)
        if let error = store.addEvent(template: template, dateKey: AgendaIntentBridge.dateKey(start), startSlot: startSlot) {
            throw AgendaIntentFailure.message(error)
        }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho aggiunto \(template.name) \(AgendaIntentBridge.spokenDateTime(start))."))
    }
}

struct AddAgendaEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Aggiungi impegno"
    static var description = IntentDescription("Crea un nuovo impegno anche se non esiste già un blocco riutilizzabile con quel nome.")

    @Parameter(title: "Nome") var name: String
    @Parameter(title: "Inizio", kind: .dateTime) var start: Date
    @Parameter(title: "Fine", kind: .dateTime) var end: Date
    @Parameter(title: "Luogo") var location: String?
    @Parameter(title: "Promemoria, minuti prima") var reminderMinutes: Int?
    @Parameter(title: "Ripeti per quante settimane") var repeatWeeks: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Aggiungi \(\.$name) da \(\.$start) a \(\.$end)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let duration = try AgendaIntentBridge.slots(from: start, to: end)
        let created = try AgendaIntentBridge.addCustomEvent(
            to: store,
            name: name,
            start: start,
            durationSlots: duration,
            repeatWeeks: repeatWeeks,
            reminderMinutes: reminderMinutes,
            location: location
        )
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho aggiunto \(created.name) \(AgendaIntentBridge.spokenDateTime(start))."))
    }
}

struct CreateReusableBlockIntent: AppIntent {
    static var title: LocalizedStringResource = "Crea blocco preimpostato"
    static var description = IntentDescription("Crea soltanto un nuovo blocco preimpostato e riutilizzabile. Non crea un evento e non richiede una data o un orario.")

    @Parameter(title: "Nome del blocco") var name: String
    @Parameter(title: "Durata in minuti", default: 60) var durationMinutes: Int
    @Parameter(title: "Colore", default: .azzurro) var color: AgendaColorChoice
    @Parameter(title: "Luogo") var location: String?
    @Parameter(title: "Promemoria, minuti prima") var reminderMinutes: Int?
    @Parameter(title: "Ripeti per quante settimane") var repeatWeeks: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Crea il blocco \(\.$name) di \(\.$durationMinutes) minuti")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgendaIntentFailure.message("Dimmi un nome per il blocco.") }
        if AgendaIntentBridge.matchingTemplate(named: trimmed, in: store) != nil {
            throw AgendaIntentFailure.message("Esiste già un blocco chiamato \(trimmed).")
        }
        let duration = try AgendaIntentBridge.slots(minutes: durationMinutes)
        store.addTemplate(
            name: trimmed,
            durationSlots: duration,
            colorHex: color.hex,
            repeatWeeks: repeatWeeks.map { max(1, $0) },
            reminderMinutes: reminderMinutes.map { max(0, $0) },
            location: location
        )
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho creato il blocco preimpostato \(trimmed), durata \(AgendaIntentBridge.durationText(slots: duration)). Non l’ho inserito nel calendario."))
    }
}

struct EditReusableBlockIntent: AppIntent {
    static var title: LocalizedStringResource = "Modifica blocco riutilizzabile"
    static var description = IntentDescription("Modifica nome, durata o colore di un blocco esistente.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Nuovo nome") var newName: String?
    @Parameter(title: "Nuova durata in minuti") var durationMinutes: Int?
    @Parameter(title: "Nuovo colore") var color: AgendaColorChoice?
    @Parameter(title: "Luogo predefinito") var location: String?
    @Parameter(title: "Promemoria predefinito, minuti prima") var reminderMinutes: Int?
    @Parameter(title: "Ripeti per quante settimane") var repeatWeeks: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var template = store.templates.first(where: { $0.id == block.id }) else {
            throw AgendaIntentFailure.message("Quel blocco non esiste più.")
        }
        if let newName {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { template.name = trimmed }
        }
        if let durationMinutes { template.durationSlots = try AgendaIntentBridge.slots(minutes: durationMinutes) }
        if let color { template.colorHex = color.hex }
        if let location {
            let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            template.location = trimmed.isEmpty ? nil : trimmed
        }
        if let reminderMinutes { template.reminderMinutes = max(0, reminderMinutes) }
        if let repeatWeeks { template.repeatWeeks = max(1, repeatWeeks) }
        store.updateTemplate(template)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Blocco \(template.name) aggiornato."))
    }
}

struct DeleteReusableBlockIntent: AppIntent {
    static var title: LocalizedStringResource = "Elimina blocco riutilizzabile"
    static var description = IntentDescription("Elimina un blocco riutilizzabile. Gli impegni già messi in calendario restano.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let template = store.templates.first(where: { $0.id == block.id }) else {
            throw AgendaIntentFailure.message("Quel blocco non esiste più.")
        }
        store.deleteTemplate(template)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Ho eliminato il blocco \(template.name). Gli impegni già presenti restano in agenda."))
    }
}

struct MoveAgendaEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Sposta impegno"
    static var description = IntentDescription("Sposta un impegno esistente a un altro giorno o orario.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nuovo inizio", kind: .dateTime) var newStart: Date

    static var parameterSummary: some ParameterSummary {
        Summary("Sposta \(\.$event) a \(\.$newStart)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard store.events.contains(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        let slot = try AgendaIntentBridge.slot(for: newStart)
        if let error = store.moveEvent(id: event.id, toDateKey: AgendaIntentBridge.dateKey(newStart), startSlot: slot) {
            throw AgendaIntentFailure.message(error)
        }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Ho spostato \(event.name) \(AgendaIntentBridge.spokenDateTime(newStart))."))
    }
}

struct EditAgendaEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Modifica impegno"
    static var description = IntentDescription("Modifica nome, orario, durata, luogo o promemoria di un impegno.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nuovo nome") var newName: String?
    @Parameter(title: "Nuovo inizio", kind: .dateTime) var newStart: Date?
    @Parameter(title: "Nuova durata in minuti") var durationMinutes: Int?
    @Parameter(title: "Nuovo luogo") var location: String?
    @Parameter(title: "Nuovo promemoria, minuti prima") var reminderMinutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var updated = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        if let newName {
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { updated.name = trimmed }
        }
        if let newStart {
            updated.dateKey = AgendaIntentBridge.dateKey(newStart)
            updated.startSlot = try AgendaIntentBridge.slot(for: newStart)
        }
        if let durationMinutes { updated.durationSlots = try AgendaIntentBridge.slots(minutes: durationMinutes) }
        if let location {
            let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.location = trimmed.isEmpty ? nil : trimmed
        }
        if let reminderMinutes { updated.reminderMinutes = max(0, reminderMinutes) }
        if let error = store.updateEvent(updated) { throw AgendaIntentFailure.message(error) }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Impegno \(updated.name) aggiornato."))
    }
}

struct DeleteAgendaEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Elimina impegno"
    static var description = IntentDescription("Elimina un impegno specifico dall'agenda.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        store.deleteEvent(existing)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Ho eliminato \(existing.name) dall'agenda."))
    }
}

struct AgendaForDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Mostra agenda del giorno"
    static var description = IntentDescription("Legge gli impegni di oggi o di una data specifica.")

    @Parameter(title: "Data", kind: .date) var date: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = AgendaIntentBridge.makeStore()
        let target = date ?? Date()
        let summary = AgendaIntentBridge.daySummary(store, date: target)
        return .result(value: summary, dialog: AgendaIntentBridge.dialog(summary))
    }
}

struct AgendaForWeekIntent: AppIntent {
    static var title: LocalizedStringResource = "Mostra agenda della settimana"
    static var description = IntentDescription("Riassume gli impegni della settimana che contiene la data indicata.")

    @Parameter(title: "Settimana della data", kind: .date) var date: Date?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = AgendaIntentBridge.makeStore()
        let calendar = Calendar.current
        let target = date ?? Date()
        let weekday = calendar.component(.weekday, from: target)
        let distanceToMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -distanceToMonday, to: calendar.startOfDay(for: target)) ?? target
        var parts: [String] = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else { continue }
            let events = AgendaIntentBridge.dayEvents(store, date: day)
            if !events.isEmpty {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "it_IT")
                formatter.dateFormat = "EEEE"
                let lines = events.map { "\(AgendaIntentBridge.timeText(slot: $0.startSlot)) \($0.name)" }.joined(separator: ", ")
                parts.append("\(formatter.string(from: day)): \(lines)")
            }
        }
        let text = parts.isEmpty ? "Non hai impegni questa settimana." : parts.joined(separator: "; ") + "."
        return .result(value: text, dialog: AgendaIntentBridge.dialog(text))
    }
}

struct NextAgendaEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Prossimo impegno"
    static var description = IntentDescription("Dice qual è il prossimo impegno futuro in Agenda a Blocchi.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = AgendaIntentBridge.makeStore()
        let now = Date()
        let next = store.events
            .compactMap { event -> (AgendaEvent, Date)? in
                guard let date = AgendaIntentBridge.eventDate(event), date >= now else { return nil }
                return (event, date)
            }
            .min { $0.1 < $1.1 }
        let text: String
        if let next {
            text = "Il prossimo impegno è \(next.0.name), \(AgendaIntentBridge.spokenDateTime(next.1))."
        } else {
            text = "Non risultano impegni futuri in Agenda a Blocchi."
        }
        return .result(value: text, dialog: AgendaIntentBridge.dialog(text))
    }
}

struct FindFreeTimeIntent: AppIntent {
    static var title: LocalizedStringResource = "Trova tempo libero"
    static var description = IntentDescription("Trova gli intervalli liberi di una certa durata in un giorno.")

    @Parameter(title: "Data", kind: .date) var date: Date?
    @Parameter(title: "Durata minima in minuti", default: 60) var minimumMinutes: Int
    @Parameter(title: "Dalle ore", default: 8) var fromHour: Int
    @Parameter(title: "Alle ore", default: 20) var toHour: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Trova almeno \(\.$minimumMinutes) minuti liberi")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = AgendaIntentBridge.makeStore()
        let target = date ?? Date()
        let free = try AgendaIntentBridge.freeIntervals(
            store: store,
            date: target,
            minimumMinutes: minimumMinutes,
            fromHour: fromHour,
            toHour: toHour
        )
        let text: String
        if free.isEmpty {
            text = "Non trovo intervalli liberi di almeno \(minimumMinutes) minuti tra le \(fromHour) e le \(toHour)."
        } else {
            let first = free.prefix(5).map { "\(AgendaIntentBridge.timeText(slot: $0.0))–\(AgendaIntentBridge.timeText(slot: $0.1))" }
            text = "Hai libero: " + first.joined(separator: ", ") + "."
        }
        return .result(value: text, dialog: AgendaIntentBridge.dialog(text))
    }
}

struct SearchAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cerca impegni"
    static var description = IntentDescription("Cerca impegni per nome nell'agenda.")

    @Parameter(title: "Testo da cercare") var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = AgendaIntentBridge.makeStore()
        let matches = store.events
            .filter { $0.name.localizedCaseInsensitiveContains(text) }
            .sorted(by: AgendaIntentBridge.eventSort)
            .prefix(8)
        let answer: String
        if matches.isEmpty {
            answer = "Non trovo impegni che contengono \(text)."
        } else {
            answer = matches.compactMap { event in
                guard let date = AgendaIntentBridge.eventDate(event) else { return nil }
                return "\(event.name), \(AgendaIntentBridge.spokenDateTime(date))"
            }.joined(separator: "; ") + "."
        }
        return .result(value: answer, dialog: AgendaIntentBridge.dialog(answer))
    }
}

struct ListReusableBlocksIntent: AppIntent {
    static var title: LocalizedStringResource = "Elenca blocchi riutilizzabili"
    static var description = IntentDescription("Elenca i blocchi che puoi inserire rapidamente nell'agenda.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = AgendaIntentBridge.makeStore()
        let text: String
        if store.templates.isEmpty {
            text = "Non hai ancora blocchi riutilizzabili."
        } else {
            text = "I tuoi blocchi sono: " + store.templates.map { "\($0.name), \(AgendaIntentBridge.durationText(slots: $0.durationSlots))" }.joined(separator: "; ") + "."
        }
        return .result(value: text, dialog: AgendaIntentBridge.dialog(text))
    }
}

struct SyncAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Sincronizza agenda"
    static var description = IntentDescription("Sincronizza manualmente Agenda a Blocchi con Supabase.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        await store.synchronize()
        let text: String
        if let error = store.syncError {
            text = "Sincronizzazione non completata: \(error)"
        } else if store.session == nil {
            text = "L'agenda è salvata sul dispositivo, ma devi accedere a Supabase nell'app per sincronizzarla."
        } else {
            text = store.syncStatus
        }
        AgendaIntentBridge.notifyMutation()
        return .result(dialog: AgendaIntentBridge.dialog(text))
    }
}


struct ShiftAgendaEventByMinutesIntent: AppIntent {
    static var title: LocalizedStringResource = "Sposta impegno di minuti"
    static var description = IntentDescription("Anticipa o posticipa un impegno di 15, 30, 45, 60 minuti o di un valore personalizzato, mantenendo la stessa durata.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti", default: 15) var minutes: Int
    @Parameter(title: "Direzione", default: .avanti) var direction: AgendaShiftDirection

    static var parameterSummary: some ParameterSummary {
        Summary("Sposta \(\.$event) \(\.$direction) di \(\.$minutes) minuti")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        guard minutes > 0 else { throw AgendaIntentFailure.message("I minuti devono essere maggiori di zero.") }
        let delta = direction.sign * minutes
        let newStart = try AgendaIntentBridge.dateByShifting(existing, minutes: delta)
        let newSlot = try AgendaIntentBridge.slot(for: newStart)
        if let error = store.moveEvent(id: existing.id, toDateKey: AgendaIntentBridge.dateKey(newStart), startSlot: newSlot) {
            throw AgendaIntentFailure.message(error)
        }
        await AgendaIntentBridge.finishMutation(store)
        let verb = direction == .avanti ? "posticipato" : "anticipato"
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho \(verb) \(existing.name) di \(minutes) minuti. Ora inizia alle \(AgendaIntentBridge.timeText(slot: newSlot))."))
    }
}

struct ExtendAgendaEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Allunga impegno"
    static var description = IntentDescription("Allunga la durata di un impegno senza cambiarne l'ora di inizio.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti da aggiungere", default: 15) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var updated = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        let extra = try AgendaIntentBridge.slots(minutes: minutes)
        updated.durationSlots += extra
        if let error = store.updateEvent(updated) { throw AgendaIntentFailure.message(error) }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho allungato \(updated.name) di \(minutes) minuti. Ora termina alle \(AgendaIntentBridge.timeText(slot: updated.startSlot + updated.durationSlots))."))
    }
}

struct ShortenAgendaEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Accorcia impegno"
    static var description = IntentDescription("Accorcia la durata di un impegno mantenendo lo stesso inizio.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti da togliere", default: 15) var minutes: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var updated = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        let reduction = try AgendaIntentBridge.slots(minutes: minutes)
        guard updated.durationSlots - reduction >= 1 else {
            throw AgendaIntentFailure.message("La durata minima è 15 minuti.")
        }
        updated.durationSlots -= reduction
        if let error = store.updateEvent(updated) { throw AgendaIntentFailure.message(error) }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho accorciato \(updated.name) di \(minutes) minuti. Ora termina alle \(AgendaIntentBridge.timeText(slot: updated.startSlot + updated.durationSlots))."))
    }
}

struct DuplicateAgendaEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Duplica impegno"
    static var description = IntentDescription("Crea una copia di un impegno in una nuova data e ora.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nuovo inizio", kind: .dateTime) var newStart: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        let slot = try AgendaIntentBridge.slot(for: newStart)
        let created = try AgendaIntentBridge.duplicateEvent(existing, in: store, dateKey: AgendaIntentBridge.dateKey(newStart), startSlot: slot)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho duplicato \(created.name) \(AgendaIntentBridge.spokenDateTime(newStart))."))
    }
}

struct DuplicateAgendaEventTomorrowIntent: AppIntent {
    static var title: LocalizedStringResource = "Duplica impegno domani"
    static var description = IntentDescription("Duplica un impegno domani alla stessa ora.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }),
              let sourceDate = AgendaIntentBridge.eventDate(existing),
              let target = Calendar.current.date(byAdding: .day, value: 1, to: sourceDate) else {
            throw AgendaIntentFailure.message("Non riesco a duplicare quell'impegno.")
        }
        let created = try AgendaIntentBridge.duplicateEvent(existing, in: store, dateKey: AgendaIntentBridge.dateKey(target), startSlot: existing.startSlot)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho copiato \(created.name) a domani alla stessa ora."))
    }
}

struct DuplicateAgendaEventNextWeekIntent: AppIntent {
    static var title: LocalizedStringResource = "Duplica impegno settimana prossima"
    static var description = IntentDescription("Duplica un impegno sette giorni dopo alla stessa ora.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }),
              let sourceDate = AgendaIntentBridge.eventDate(existing),
              let target = Calendar.current.date(byAdding: .day, value: 7, to: sourceDate) else {
            throw AgendaIntentFailure.message("Non riesco a duplicare quell'impegno.")
        }
        let created = try AgendaIntentBridge.duplicateEvent(existing, in: store, dateKey: AgendaIntentBridge.dateKey(target), startSlot: existing.startSlot)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho copiato \(created.name) alla settimana prossima, alla stessa ora."))
    }
}

struct CopyAgendaEventToDateIntent: AppIntent {
    static var title: LocalizedStringResource = "Copia impegno in un altro giorno"
    static var description = IntentDescription("Copia un impegno in un giorno specifico mantenendo lo stesso orario e la stessa durata.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nuovo giorno", kind: .date) var date: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        let created = try AgendaIntentBridge.duplicateEvent(existing, in: store, dateKey: AgendaIntentBridge.dateKey(date), startSlot: existing.startSlot)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho copiato \(created.name) nel giorno richiesto alle \(AgendaIntentBridge.timeText(slot: created.startSlot))."))
    }
}

struct SetEventReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Imposta promemoria impegno"
    static var description = IntentDescription("Aggiunge o cambia il promemoria di un impegno.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti prima", default: 15) var minutesBefore: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var updated = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        updated.reminderMinutes = max(0, minutesBefore)
        if let error = store.updateEvent(updated) { throw AgendaIntentFailure.message(error) }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ti ricorderò \(updated.name) \(max(0, minutesBefore)) minuti prima."))
    }
}

struct RemoveEventReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Rimuovi promemoria impegno"
    static var description = IntentDescription("Rimuove il promemoria da un impegno.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var updated = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        updated.reminderMinutes = nil
        if let error = store.updateEvent(updated) { throw AgendaIntentFailure.message(error) }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho rimosso il promemoria da \(updated.name)."))
    }
}

struct SetEventLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Imposta luogo impegno"
    static var description = IntentDescription("Aggiunge o cambia il luogo di un impegno.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Luogo") var location: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var updated = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgendaIntentFailure.message("Dimmi un luogo.") }
        updated.location = trimmed
        if let error = store.updateEvent(updated) { throw AgendaIntentFailure.message(error) }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Il luogo di \(updated.name) è \(trimmed)."))
    }
}

struct RemoveEventLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Rimuovi luogo impegno"
    static var description = IntentDescription("Rimuove il luogo associato a un impegno.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var updated = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        updated.location = nil
        if let error = store.updateEvent(updated) { throw AgendaIntentFailure.message(error) }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho rimosso il luogo da \(updated.name)."))
    }
}

struct ChangeEventStartIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia inizio impegno"
    static var description = IntentDescription("Cambia soltanto l'ora o il giorno di inizio di un impegno e mantiene invariata la durata.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nuovo inizio", kind: .dateTime) var newStart: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        let slot = try AgendaIntentBridge.slot(for: newStart)
        if let error = store.moveEvent(id: existing.id, toDateKey: AgendaIntentBridge.dateKey(newStart), startSlot: slot) {
            throw AgendaIntentFailure.message(error)
        }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. \(existing.name) ora inizia \(AgendaIntentBridge.spokenDateTime(newStart))."))
    }
}

struct ChangeEventEndIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia fine impegno"
    static var description = IntentDescription("Cambia l'ora di fine di un impegno lasciando invariato l'inizio.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nuova fine", kind: .dateTime) var newEnd: Date

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var updated = store.events.first(where: { $0.id == event.id }),
              let start = AgendaIntentBridge.eventDate(updated) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        updated.durationSlots = try AgendaIntentBridge.slots(from: start, to: newEnd)
        if let error = store.updateEvent(updated) { throw AgendaIntentFailure.message(error) }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. \(updated.name) ora termina alle \(AgendaIntentBridge.timeText(slot: updated.startSlot + updated.durationSlots))."))
    }
}

struct ScheduleBlockNextFreeIntent: AppIntent {
    static var title: LocalizedStringResource = "Metti blocco nel prossimo spazio libero"
    static var description = IntentDescription("Trova il primo spazio libero in una giornata e ci inserisce un blocco preimpostato.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Giorno", kind: .date) var date: Date
    @Parameter(title: "Dalle ore", default: 8) var fromHour: Int
    @Parameter(title: "Alle ore", default: 20) var toHour: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let template = store.templates.first(where: { $0.id == block.id }) else {
            throw AgendaIntentFailure.message("Quel blocco non esiste più.")
        }
        guard let slot = try AgendaIntentBridge.nextFreeStart(store: store, date: date, durationSlots: template.durationSlots, fromHour: fromHour, toHour: toHour) else {
            throw AgendaIntentFailure.message("Non trovo uno spazio libero abbastanza lungo in quell'intervallo.")
        }
        if let error = store.addEvent(template: template, dateKey: AgendaIntentBridge.dateKey(date), startSlot: slot) {
            throw AgendaIntentFailure.message(error)
        }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho messo \(template.name) nel primo spazio libero, dalle \(AgendaIntentBridge.timeText(slot: slot)) alle \(AgendaIntentBridge.timeText(slot: slot + template.durationSlots))."))
    }
}

struct MoveEventNextFreeIntent: AppIntent {
    static var title: LocalizedStringResource = "Sposta impegno al prossimo spazio libero"
    static var description = IntentDescription("Sposta un impegno nel primo spazio libero disponibile, mantenendo la stessa durata.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Giorno", kind: .date) var date: Date
    @Parameter(title: "Dalle ore", default: 8) var fromHour: Int
    @Parameter(title: "Alle ore", default: 20) var toHour: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        guard let slot = try AgendaIntentBridge.nextFreeStart(store: store, date: date, durationSlots: existing.durationSlots, fromHour: fromHour, toHour: toHour, excluding: existing.id) else {
            throw AgendaIntentFailure.message("Non trovo uno spazio libero abbastanza lungo in quell'intervallo.")
        }
        if let error = store.moveEvent(id: existing.id, toDateKey: AgendaIntentBridge.dateKey(date), startSlot: slot) {
            throw AgendaIntentFailure.message(error)
        }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho spostato \(existing.name) nel primo spazio libero, alle \(AgendaIntentBridge.timeText(slot: slot))."))
    }
}

struct AddCustomEventNextFreeIntent: AppIntent {
    static var title: LocalizedStringResource = "Crea impegno nel prossimo spazio libero"
    static var description = IntentDescription("Crea un nuovo impegno nel primo spazio libero disponibile in una giornata.")

    @Parameter(title: "Nome") var name: String
    @Parameter(title: "Durata in minuti", default: 60) var durationMinutes: Int
    @Parameter(title: "Giorno", kind: .date) var date: Date
    @Parameter(title: "Dalle ore", default: 8) var fromHour: Int
    @Parameter(title: "Alle ore", default: 20) var toHour: Int
    @Parameter(title: "Colore", default: .azzurro) var color: AgendaColorChoice
    @Parameter(title: "Luogo") var location: String?
    @Parameter(title: "Promemoria, minuti prima") var reminderMinutes: Int?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let duration = try AgendaIntentBridge.slots(minutes: durationMinutes)
        guard let slot = try AgendaIntentBridge.nextFreeStart(store: store, date: date, durationSlots: duration, fromHour: fromHour, toHour: toHour) else {
            throw AgendaIntentFailure.message("Non trovo uno spazio libero abbastanza lungo in quell'intervallo.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgendaIntentFailure.message("Dimmi un nome per l'impegno.") }
        let template = BlockTemplate(
            id: UUID(),
            name: trimmed,
            durationSlots: duration,
            colorHex: color.hex,
            repeatWeeks: nil,
            reminderMinutes: reminderMinutes.map { max(0, $0) },
            location: location
        )
        if let error = store.addEvent(template: template, dateKey: AgendaIntentBridge.dateKey(date), startSlot: slot) {
            throw AgendaIntentFailure.message(error)
        }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho inserito \(trimmed) nel primo spazio libero alle \(AgendaIntentBridge.timeText(slot: slot))."))
    }
}

struct CreateBlockFromEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Crea blocco da impegno"
    static var description = IntentDescription("Salva un impegno esistente come nuovo blocco preimpostato riutilizzabile.")

    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nome del blocco") var newName: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let existing = store.events.first(where: { $0.id == event.id }) else {
            throw AgendaIntentFailure.message("Quell'impegno non esiste più.")
        }
        let name = (newName ?? existing.name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgendaIntentFailure.message("Dimmi un nome per il blocco.") }
        if AgendaIntentBridge.matchingTemplate(named: name, in: store) != nil {
            throw AgendaIntentFailure.message("Esiste già un blocco chiamato \(name).")
        }
        store.addTemplate(
            name: name,
            durationSlots: existing.durationSlots,
            colorHex: existing.colorHex,
            repeatWeeks: existing.repeatWeeks,
            reminderMinutes: existing.reminderMinutes,
            location: existing.location
        )
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho salvato \(name) come blocco preimpostato riutilizzabile."))
    }
}

struct SetReusableBlockReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Imposta promemoria del blocco"
    static var description = IntentDescription("Imposta il promemoria predefinito per i nuovi impegni creati da un blocco riutilizzabile.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Minuti prima", default: 15) var minutesBefore: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var template = store.templates.first(where: { $0.id == block.id }) else {
            throw AgendaIntentFailure.message("Quel blocco non esiste più.")
        }
        template.reminderMinutes = max(0, minutesBefore)
        store.updateTemplate(template)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Il blocco \(template.name) avrà un promemoria \(max(0, minutesBefore)) minuti prima."))
    }
}

struct RemoveReusableBlockReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Rimuovi promemoria del blocco"
    static var description = IntentDescription("Rimuove il promemoria predefinito da un blocco riutilizzabile.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var template = store.templates.first(where: { $0.id == block.id }) else {
            throw AgendaIntentFailure.message("Quel blocco non esiste più.")
        }
        template.reminderMinutes = nil
        store.updateTemplate(template)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho rimosso il promemoria predefinito dal blocco \(template.name)."))
    }
}

struct SetReusableBlockLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Imposta luogo del blocco"
    static var description = IntentDescription("Imposta il luogo predefinito per un blocco riutilizzabile.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Luogo") var location: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var template = store.templates.first(where: { $0.id == block.id }) else {
            throw AgendaIntentFailure.message("Quel blocco non esiste più.")
        }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AgendaIntentFailure.message("Dimmi un luogo.") }
        template.location = trimmed
        store.updateTemplate(template)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Il luogo predefinito di \(template.name) è \(trimmed)."))
    }
}

struct RemoveReusableBlockLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Rimuovi luogo del blocco"
    static var description = IntentDescription("Rimuove il luogo predefinito da un blocco riutilizzabile.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var template = store.templates.first(where: { $0.id == block.id }) else {
            throw AgendaIntentFailure.message("Quel blocco non esiste più.")
        }
        template.location = nil
        store.updateTemplate(template)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Ho rimosso il luogo predefinito dal blocco \(template.name)."))
    }
}

struct AskAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Parla con Agenda a Blocchi"
    static var openAppWhenRun: Bool = false
    static var description = IntentDescription("Interpreta una richiesta in italiano e usa le funzioni di Agenda a Blocchi. Gli errori vengono sempre spiegati a voce invece di chiudere Siri con un errore generico.")

    @Parameter(title: "Cosa vuoi fare", requestValueDialog: IntentDialog("Cosa vuoi fare in Agenda a Blocchi?")) var request: String

    static var parameterSummary: some ParameterSummary {
        Summary("In Agenda a Blocchi: \(\.$request)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let value = AgendaIntentBridge.normalized(request)

        if let aiAnswer = await AgendaAIInterpreter.execute(request, store: store) {
            return .result(dialog: AgendaIntentBridge.dialog(aiAnswer))
        }

        func answer(_ text: String) -> some IntentResult & ProvidesDialog {
            .result(dialog: AgendaIntentBridge.dialog(text))
        }

        do {
            if value.contains("sincron") {
                await store.synchronize()
                let text = store.syncError.map { "Sincronizzazione non completata: \($0)" } ?? store.syncStatus
                AgendaIntentBridge.notifyMutation()
                return answer(text)
            }

            if value.contains("prossimo impegno") || value.contains("prossimo evento") {
                let now = Date()
                let next = store.events.compactMap { event -> (AgendaEvent, Date)? in
                    guard let date = AgendaIntentBridge.eventDate(event), date >= now else { return nil }
                    return (event, date)
                }.min { $0.1 < $1.1 }
                let text = next.map { "Il prossimo impegno è \($0.0.name), \(AgendaIntentBridge.spokenDateTime($0.1))." } ?? "Non risultano impegni futuri."
                return answer(text)
            }

            if value.contains("cosa ho") || value.contains("agenda di") || value.contains("agenda oggi") || value.contains("agenda domani") {
                let date = AgendaIntentBridge.dayMentioned(in: request)
                return answer(AgendaIntentBridge.daySummary(store, date: date))
            }

            // A reusable block is deliberately separate from a scheduled event.
            if (value.contains("crea") || value.contains("nuovo")) && value.contains("blocco") {
                guard let name = AgendaIntentBridge.guessedNewBlockName(in: request) else {
                    return answer("Dimmi anche il nome del blocco. Per esempio: crea un blocco preimpostato Palestra da un'ora e mezza.")
                }
                if AgendaIntentBridge.matchingTemplate(named: name, in: store) != nil {
                    return answer("Esiste già un blocco chiamato \(name).")
                }
                let minutes = AgendaIntentBridge.durationMinutesMentioned(in: request) ?? 60
                let duration = try AgendaIntentBridge.slots(minutes: minutes)
                let color = AgendaIntentBridge.colorMentioned(in: request) ?? .azzurro
                let reminder = AgendaIntentBridge.reminderMentioned(in: request)
                let location = AgendaIntentBridge.locationMentioned(in: request)
                let repeatWeeks = AgendaIntentBridge.repeatWeeksMentioned(in: request)
                store.addTemplate(
                    name: name,
                    durationSlots: duration,
                    colorHex: color.hex,
                    repeatWeeks: repeatWeeks,
                    reminderMinutes: reminder,
                    location: location
                )
                await AgendaIntentBridge.finishMutation(store)
                var details = "Fatto. Ho creato il blocco preimpostato \(name), durata \(AgendaIntentBridge.durationText(slots: duration))"
                if let location { details += ", luogo \(location)" }
                if let reminder { details += ", promemoria \(reminder) minuti prima" }
                details += ". Non l'ho inserito nel calendario."
                return answer(details)
            }

            // If an existing reusable block is named, schedule that block.
            if let template = AgendaIntentBridge.templateMentioned(in: request, store: store),
               value.contains("metti") || value.contains("programma") || value.contains("pianifica") || value.contains("inserisci") {
                let day = AgendaIntentBridge.dayMentioned(in: request)
                let times = AgendaIntentBridge.timeMentions(in: request, baseDate: day)
                guard let start = times.first ?? AgendaIntentBridge.hourMentioned(in: request, baseDate: day) else {
                    return answer("Ho riconosciuto il blocco \(template.name). Dimmi anche l'orario, per esempio: metti \(template.name) domani alle 18.")
                }
                let slot = try AgendaIntentBridge.slot(for: start)
                if let error = store.addEvent(template: template, dateKey: AgendaIntentBridge.dateKey(start), startSlot: slot) {
                    return answer(error)
                }
                await AgendaIntentBridge.finishMutation(store)
                return answer("Fatto. Ho messo \(template.name) \(AgendaIntentBridge.spokenDateTime(start)).")
            }

            // Natural-language custom event creation. This was missing in v5.7.
            let isCreateEventRequest = ["crea", "aggiungi", "programma", "pianifica", "inserisci", "metti"].contains(where: { value.contains($0) })
                && ["evento", "impegno", "appuntamento"].contains(where: { value.contains($0) })
            if isCreateEventRequest {
                guard let name = AgendaIntentBridge.guessedNewEventName(in: request) else {
                    return answer("Dimmi il nome dell'impegno. Per esempio: crea un evento Palestra domani alle 18 per un'ora.")
                }
                let day = AgendaIntentBridge.dayMentioned(in: request)
                let times = AgendaIntentBridge.timeMentions(in: request, baseDate: day)
                guard let start = times.first ?? AgendaIntentBridge.hourMentioned(in: request, baseDate: day) else {
                    return answer("Ho capito che vuoi creare \(name), ma mi serve anche l'orario. Per esempio: crea un evento \(name) domani alle 18 per un'ora.")
                }

                let durationSlots: Int
                if times.count >= 2, times[1] > start {
                    durationSlots = try AgendaIntentBridge.slots(from: start, to: times[1])
                } else {
                    let minutes = AgendaIntentBridge.durationMinutesMentioned(in: request) ?? 60
                    durationSlots = try AgendaIntentBridge.slots(minutes: minutes)
                }

                let created = try AgendaIntentBridge.addCustomEvent(
                    to: store,
                    name: name,
                    start: start,
                    durationSlots: durationSlots,
                    repeatWeeks: AgendaIntentBridge.repeatWeeksMentioned(in: request),
                    reminderMinutes: AgendaIntentBridge.reminderMentioned(in: request),
                    location: AgendaIntentBridge.locationMentioned(in: request)
                )
                await AgendaIntentBridge.finishMutation(store)
                return answer("Fatto. Ho aggiunto \(created.name) \(AgendaIntentBridge.spokenDateTime(start)), durata \(AgendaIntentBridge.durationText(slots: durationSlots)).")
            }

            if let existing = AgendaIntentBridge.eventMentioned(in: request, store: store) {
                if value.contains("anticip") || value.contains("indietro") || value.contains("prima") {
                    let minutes = AgendaIntentBridge.minutesMentioned(in: request) ?? 15
                    let start = try AgendaIntentBridge.dateByShifting(existing, minutes: -minutes)
                    let slot = try AgendaIntentBridge.slot(for: start)
                    if let error = store.moveEvent(id: existing.id, toDateKey: AgendaIntentBridge.dateKey(start), startSlot: slot) { return answer(error) }
                    await AgendaIntentBridge.finishMutation(store)
                    return answer("Fatto. Ho anticipato \(existing.name) di \(minutes) minuti. Ora inizia alle \(AgendaIntentBridge.timeText(slot: slot)).")
                }
                if value.contains("posticip") || value.contains("avanti") || value.contains("dopo") || value.contains("sposta") {
                    let minutes = AgendaIntentBridge.minutesMentioned(in: request) ?? 15
                    let start = try AgendaIntentBridge.dateByShifting(existing, minutes: minutes)
                    let slot = try AgendaIntentBridge.slot(for: start)
                    if let error = store.moveEvent(id: existing.id, toDateKey: AgendaIntentBridge.dateKey(start), startSlot: slot) { return answer(error) }
                    await AgendaIntentBridge.finishMutation(store)
                    return answer("Fatto. Ho posticipato \(existing.name) di \(minutes) minuti. Ora inizia alle \(AgendaIntentBridge.timeText(slot: slot)).")
                }
                if value.contains("allunga") || value.contains("prolunga") {
                    let minutes = AgendaIntentBridge.minutesMentioned(in: request) ?? 15
                    var updated = existing
                    updated.durationSlots += try AgendaIntentBridge.slots(minutes: minutes)
                    if let error = store.updateEvent(updated) { return answer(error) }
                    await AgendaIntentBridge.finishMutation(store)
                    return answer("Fatto. Ho allungato \(updated.name) di \(minutes) minuti.")
                }
                if value.contains("accorcia") || value.contains("riduci") {
                    let minutes = AgendaIntentBridge.minutesMentioned(in: request) ?? 15
                    var updated = existing
                    let reduction = try AgendaIntentBridge.slots(minutes: minutes)
                    guard updated.durationSlots - reduction >= 1 else { return answer("La durata minima è 15 minuti.") }
                    updated.durationSlots -= reduction
                    if let error = store.updateEvent(updated) { return answer(error) }
                    await AgendaIntentBridge.finishMutation(store)
                    return answer("Fatto. Ho accorciato \(updated.name) di \(minutes) minuti.")
                }
                if value.contains("rimuovi") && (value.contains("promemoria") || value.contains("avviso")) {
                    var updated = existing
                    updated.reminderMinutes = nil
                    if let error = store.updateEvent(updated) { return answer(error) }
                    await AgendaIntentBridge.finishMutation(store)
                    return answer("Fatto. Ho rimosso il promemoria da \(updated.name).")
                }
                if value.contains("promemoria") || value.contains("ricord") || value.contains("avvis") {
                    let minutes = AgendaIntentBridge.reminderMentioned(in: request) ?? 15
                    var updated = existing
                    updated.reminderMinutes = minutes
                    if let error = store.updateEvent(updated) { return answer(error) }
                    await AgendaIntentBridge.finishMutation(store)
                    return answer("Fatto. Ho impostato il promemoria di \(updated.name) \(minutes) minuti prima.")
                }
                if value.contains("rimuovi") && value.contains("luogo") {
                    var updated = existing
                    updated.location = nil
                    if let error = store.updateEvent(updated) { return answer(error) }
                    await AgendaIntentBridge.finishMutation(store)
                    return answer("Fatto. Ho rimosso il luogo da \(updated.name).")
                }
                if value.contains("luogo"), let location = AgendaIntentBridge.locationMentioned(in: request) {
                    var updated = existing
                    updated.location = location
                    if let error = store.updateEvent(updated) { return answer(error) }
                    await AgendaIntentBridge.finishMutation(store)
                    return answer("Fatto. Il luogo di \(updated.name) è \(location).")
                }
            }

            if value.contains("blocchi") || value.contains("blocchi preimpostati") {
                let text = store.templates.isEmpty
                    ? "Non hai ancora blocchi preimpostati."
                    : "I tuoi blocchi sono: " + store.templates.map { "\($0.name), \(AgendaIntentBridge.durationText(slots: $0.durationSlots))" }.joined(separator: "; ") + "."
                return answer(text)
            }

            return answer("Non ho capito con certezza. Prova a dirmi tutto in una frase, per esempio: crea un evento Palestra domani alle 18 per un'ora; crea un blocco preimpostato Studio da due ore; sposta Palestra avanti di mezz'ora; oppure cosa ho domani.")
        } catch let failure as AgendaIntentFailure {
            return answer(failure.localizedDescription)
        } catch {
            return answer("Non sono riuscito a completare la richiesta, ma non ho modificato i tuoi dati. Riprova dicendo nome, giorno e orario in una sola frase.")
        }
    }
}



// MARK: - In-app voice assistant bridge

extension Notification.Name {
    static let agendaOpenVoiceAssistant = Notification.Name("it.agendaablocchi.openVoiceAssistant")
}

@MainActor
enum AgendaNaturalCommandEngine {
    static func execute(_ request: String, store: AgendaStore) async -> String {
        let value = AgendaIntentBridge.normalized(request)

        do {
            if value.contains("sincron") {
                await store.synchronize()
                AgendaIntentBridge.notifyMutation()
                return store.syncError.map { "Sincronizzazione non completata: \($0)" } ?? store.syncStatus
            }

            if value.contains("prossimo impegno") || value.contains("prossimo evento") || value.contains("prossimo appuntamento") {
                let now = Date()
                let next = store.events.compactMap { event -> (AgendaEvent, Date)? in
                    guard let date = AgendaIntentBridge.eventDate(event), date >= now else { return nil }
                    return (event, date)
                }.min { $0.1 < $1.1 }
                return next.map { "Il prossimo impegno è \($0.0.name), \(AgendaIntentBridge.spokenDateTime($0.1))." } ?? "Non risultano impegni futuri."
            }

            if value.contains("cosa ho") || value.contains("agenda di") || value.contains("agenda oggi") || value.contains("agenda domani") || value.contains("impegni di") {
                let date = AgendaIntentBridge.dayMentioned(in: request)
                return AgendaIntentBridge.daySummary(store, date: date)
            }

            if (value.contains("crea") || value.contains("nuovo") || value.contains("aggiungi")) && value.contains("blocco") {
                guard let name = AgendaIntentBridge.guessedNewBlockName(in: request) else {
                    return "Dimmi anche il nome del blocco. Per esempio: crea un blocco Palestra da un'ora e mezza."
                }
                if AgendaIntentBridge.matchingTemplate(named: name, in: store) != nil {
                    return "Esiste già un blocco chiamato \(name)."
                }
                let minutes = AgendaIntentBridge.durationMinutesMentioned(in: request) ?? 60
                let duration = try AgendaIntentBridge.slots(minutes: minutes)
                let color = AgendaIntentBridge.colorMentioned(in: request) ?? .azzurro
                let reminder = AgendaIntentBridge.reminderMentioned(in: request)
                let location = AgendaIntentBridge.locationMentioned(in: request)
                let repeatWeeks = AgendaIntentBridge.repeatWeeksMentioned(in: request)
                store.addTemplate(name: name, durationSlots: duration, colorHex: color.hex, repeatWeeks: repeatWeeks, reminderMinutes: reminder, location: location)
                await AgendaIntentBridge.finishMutation(store)
                var answer = "Fatto. Ho creato il blocco \(name), durata \(AgendaIntentBridge.durationText(slots: duration))"
                if let location { answer += ", luogo \(location)" }
                if let reminder { answer += ", promemoria \(reminder) minuti prima" }
                answer += ". Non l'ho inserito nel calendario."
                return answer
            }

            if let template = AgendaIntentBridge.templateMentioned(in: request, store: store),
               value.contains("metti") || value.contains("programma") || value.contains("pianifica") || value.contains("inserisci") || value.contains("aggiungi") {
                let day = AgendaIntentBridge.dayMentioned(in: request)
                let times = AgendaIntentBridge.timeMentions(in: request, baseDate: day)
                guard let start = times.first ?? AgendaIntentBridge.hourMentioned(in: request, baseDate: day) else {
                    return "Ho riconosciuto il blocco \(template.name). Dimmi anche l'orario."
                }
                let slot = try AgendaIntentBridge.slot(for: start)
                if let error = store.addEvent(template: template, dateKey: AgendaIntentBridge.dateKey(start), startSlot: slot) { return error }
                await AgendaIntentBridge.finishMutation(store)
                return "Fatto. Ho messo \(template.name) \(AgendaIntentBridge.spokenDateTime(start))."
            }

            let isCreateEventRequest = ["crea", "aggiungi", "programma", "pianifica", "inserisci", "metti"].contains(where: { value.contains($0) })
                && (["evento", "impegno", "appuntamento"].contains(where: { value.contains($0) }) || AgendaIntentBridge.hourMentioned(in: request, baseDate: AgendaIntentBridge.dayMentioned(in: request)) != nil)
            if isCreateEventRequest {
                guard let name = AgendaIntentBridge.guessedNewEventName(in: request) ?? AgendaIntentBridge.guessedNewBlockName(in: request) else {
                    return "Dimmi il nome dell'impegno. Per esempio: metti Palestra domani alle 18 per un'ora."
                }
                let day = AgendaIntentBridge.dayMentioned(in: request)
                let times = AgendaIntentBridge.timeMentions(in: request, baseDate: day)
                guard let start = times.first ?? AgendaIntentBridge.hourMentioned(in: request, baseDate: day) else {
                    return "Ho capito che vuoi creare \(name), ma mi serve anche l'orario."
                }
                let durationSlots: Int
                if times.count >= 2, times[1] > start {
                    durationSlots = try AgendaIntentBridge.slots(from: start, to: times[1])
                } else {
                    durationSlots = try AgendaIntentBridge.slots(minutes: AgendaIntentBridge.durationMinutesMentioned(in: request) ?? 60)
                }
                let created = try AgendaIntentBridge.addCustomEvent(to: store, name: name, start: start, durationSlots: durationSlots, repeatWeeks: AgendaIntentBridge.repeatWeeksMentioned(in: request), reminderMinutes: AgendaIntentBridge.reminderMentioned(in: request), location: AgendaIntentBridge.locationMentioned(in: request))
                await AgendaIntentBridge.finishMutation(store)
                return "Fatto. Ho aggiunto \(created.name) \(AgendaIntentBridge.spokenDateTime(start)), durata \(AgendaIntentBridge.durationText(slots: durationSlots))."
            }

            if let existing = AgendaIntentBridge.eventMentioned(in: request, store: store) {
                if value.contains("anticip") || value.contains("indietro") || value.contains("prima") {
                    let minutes = AgendaIntentBridge.minutesMentioned(in: request) ?? 15
                    let start = try AgendaIntentBridge.dateByShifting(existing, minutes: -minutes)
                    let slot = try AgendaIntentBridge.slot(for: start)
                    if let error = store.moveEvent(id: existing.id, toDateKey: AgendaIntentBridge.dateKey(start), startSlot: slot) { return error }
                    await AgendaIntentBridge.finishMutation(store)
                    return "Fatto. Ho anticipato \(existing.name) di \(minutes) minuti. Ora inizia alle \(AgendaIntentBridge.timeText(slot: slot))."
                }
                if value.contains("posticip") || value.contains("avanti") || value.contains("dopo") || value.contains("sposta") {
                    let minutes = AgendaIntentBridge.minutesMentioned(in: request) ?? 15
                    let start = try AgendaIntentBridge.dateByShifting(existing, minutes: minutes)
                    let slot = try AgendaIntentBridge.slot(for: start)
                    if let error = store.moveEvent(id: existing.id, toDateKey: AgendaIntentBridge.dateKey(start), startSlot: slot) { return error }
                    await AgendaIntentBridge.finishMutation(store)
                    return "Fatto. Ho posticipato \(existing.name) di \(minutes) minuti. Ora inizia alle \(AgendaIntentBridge.timeText(slot: slot))."
                }
                if value.contains("allunga") || value.contains("prolunga") {
                    let minutes = AgendaIntentBridge.minutesMentioned(in: request) ?? 15
                    var updated = existing
                    updated.durationSlots += try AgendaIntentBridge.slots(minutes: minutes)
                    if let error = store.updateEvent(updated) { return error }
                    await AgendaIntentBridge.finishMutation(store)
                    return "Fatto. Ho allungato \(updated.name) di \(minutes) minuti."
                }
                if value.contains("accorcia") || value.contains("riduci") {
                    let minutes = AgendaIntentBridge.minutesMentioned(in: request) ?? 15
                    var updated = existing
                    let reduction = try AgendaIntentBridge.slots(minutes: minutes)
                    guard updated.durationSlots - reduction >= 1 else { return "La durata minima è 15 minuti." }
                    updated.durationSlots -= reduction
                    if let error = store.updateEvent(updated) { return error }
                    await AgendaIntentBridge.finishMutation(store)
                    return "Fatto. Ho accorciato \(updated.name) di \(minutes) minuti."
                }
                if value.contains("rimuovi") && (value.contains("promemoria") || value.contains("avviso")) {
                    var updated = existing; updated.reminderMinutes = nil
                    if let error = store.updateEvent(updated) { return error }
                    await AgendaIntentBridge.finishMutation(store)
                    return "Fatto. Ho rimosso il promemoria da \(updated.name)."
                }
                if value.contains("promemoria") || value.contains("ricord") || value.contains("avvis") {
                    let minutes = AgendaIntentBridge.reminderMentioned(in: request) ?? 15
                    var updated = existing; updated.reminderMinutes = minutes
                    if let error = store.updateEvent(updated) { return error }
                    await AgendaIntentBridge.finishMutation(store)
                    return "Fatto. Ho impostato il promemoria di \(updated.name) \(minutes) minuti prima."
                }
                if value.contains("rimuovi") && value.contains("luogo") {
                    var updated = existing; updated.location = nil
                    if let error = store.updateEvent(updated) { return error }
                    await AgendaIntentBridge.finishMutation(store)
                    return "Fatto. Ho rimosso il luogo da \(updated.name)."
                }
                if value.contains("luogo"), let location = AgendaIntentBridge.locationMentioned(in: request) {
                    var updated = existing; updated.location = location
                    if let error = store.updateEvent(updated) { return error }
                    await AgendaIntentBridge.finishMutation(store)
                    return "Fatto. Il luogo di \(updated.name) è \(location)."
                }
            }

            if value.contains("blocchi") || value.contains("preimpostati") || value.contains("riutilizzabili") {
                return store.templates.isEmpty ? "Non hai ancora blocchi preimpostati." : "I tuoi blocchi sono: " + store.templates.map { "\($0.name), \(AgendaIntentBridge.durationText(slots: $0.durationSlots))" }.joined(separator: "; ") + "."
            }

            return "Non ho capito con certezza la richiesta."
        } catch let failure as AgendaIntentFailure {
            return failure.localizedDescription
        } catch {
            return "Non sono riuscito a completare la richiesta, ma non ho modificato i tuoi dati."
        }
    }
}

struct OpenAgendaAssistantIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri assistente Agenda a Blocchi"
    static var description = IntentDescription("Apre l'assistente vocale interno di Agenda a Blocchi. Non usa il Calendario Apple.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        UserDefaults.standard.set(true, forKey: "agenda.voiceAssistant.pending")
        NotificationCenter.default.post(name: .agendaOpenVoiceAssistant, object: nil)
        return .result(dialog: AgendaIntentBridge.dialog("Apro l'assistente di Agenda a Blocchi."))
    }
}

struct AgendaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateReusableBlockIntent(),
            phrases: [
                "Crea un blocco preimpostato in \(.applicationName)",
                "Crea un blocco riutilizzabile in \(.applicationName)",
                "Nuovo blocco preimpostato in \(.applicationName)",
                "Aggiungi un blocco preimpostato in \(.applicationName)"
            ],
            shortTitle: "Crea blocco preimpostato",
            systemImageName: "square.stack.3d.up.badge.plus"
        )
        AppShortcut(
            intent: AddReusableBlockToAgendaIntent(),
            phrases: [
                "Metti \(\.$block) in \(.applicationName)",
                "Programma \(\.$block) con \(.applicationName)"
            ],
            shortTitle: "Programma blocco",
            systemImageName: "calendar.badge.plus"
        )
        AppShortcut(
            intent: AddAgendaEventIntent(),
            phrases: [
                "Aggiungi un impegno in \(.applicationName)",
                "Crea un impegno con \(.applicationName)",
                "Crea un evento in \(.applicationName)",
                "Programma un evento in \(.applicationName)"
            ],
            shortTitle: "Nuovo impegno",
            systemImageName: "plus.rectangle.on.rectangle"
        )
        AppShortcut(
            intent: ShiftAgendaEventByMinutesIntent(),
            phrases: [
                "Sposta un impegno in \(.applicationName)",
                "Anticipa o posticipa un impegno in \(.applicationName)"
            ],
            shortTitle: "Sposta di minuti",
            systemImageName: "arrow.left.and.right"
        )
        AppShortcut(
            intent: AgendaForDayIntent(),
            phrases: [
                "Cosa ho oggi in \(.applicationName)",
                "Cosa ho domani in \(.applicationName)"
            ],
            shortTitle: "Agenda del giorno",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: NextAgendaEventIntent(),
            phrases: ["Qual è il prossimo impegno in \(.applicationName)"],
            shortTitle: "Prossimo impegno",
            systemImageName: "clock.badge.questionmark"
        )
        AppShortcut(
            intent: FindFreeTimeIntent(),
            phrases: ["Trova tempo libero in \(.applicationName)"],
            shortTitle: "Trova tempo libero",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: AskAgendaIntent(),
            phrases: [
                "Parla con \(.applicationName)",
                "Usa \(.applicationName)",
                "Chiedi a \(.applicationName)",
                "Gestisci la mia agenda con \(.applicationName)"
            ],
            shortTitle: "Parla con Agenda",
            systemImageName: "apple.intelligence"
        )
        AppShortcut(
            intent: ListReusableBlocksIntent(),
            phrases: ["Quali blocchi ho in \(.applicationName)"],
            shortTitle: "I miei blocchi",
            systemImageName: "square.stack.3d.up"
        )
        AppShortcut(
            intent: SyncAgendaIntent(),
            phrases: ["Sincronizza \(.applicationName)"],
            shortTitle: "Sincronizza",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .blue }
}
