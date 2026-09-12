import Foundation
import AppIntents
import UIKit

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

    static func slot(for date: Date) throws -> Int { try AgendaTime.slot(date) }

    static func slots(minutes: Int) throws -> Int { try AgendaTime.slots(minutes) }

    static func slots(from start: Date, to end: Date) throws -> Int {
        let first = try AgendaTime.slot(start)
        let key = AgendaTime.key(start)
        let last: Int
        if end == (try AgendaTime.date(key: key, slot: 64)) { last = 64 }
        else {
            guard AgendaTime.key(end) == key else { throw AgendaOperationError.invalid("La fine deve essere nello stesso giorno o a mezzanotte.") }
            last = try AgendaTime.slot(end)
        }
        return try AgendaTime.slots((last - first) * 15)
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
        try AgendaTime.metadata(reminder: reminderMinutes, latitude: nil, longitude: nil, priority: nil)
        if let repeatWeeks, !(1...104).contains(repeatWeeks) { throw AgendaOperationError.invalid("Indica da 1 a 104 settimane.") }
        template.name = trimmed
        template.durationSlots = durationSlots
        if let repeatWeeks { template.repeatWeeks = max(1, repeatWeeks) }
        if let reminderMinutes { template.reminderMinutes = max(0, reminderMinutes) }
        if let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            template.location = location
            template.latitude = nil
            template.longitude = nil
        }

        let item = AgendaEvent(id: UUID(), templateID: template.id, name: template.name, durationSlots: durationSlots, colorHex: template.colorHex, dateKey: dateKey(start), startSlot: startSlot, reminderMinutes: template.reminderMinutes, location: template.location, notes: template.notes, latitude: template.latitude, longitude: template.longitude, category: template.category, priority: template.priority)
        let created = try store.copies(of: item, firstStart: start, count: template.repeatWeeks ?? 1, intervalDays: 7)
        try store.insertEvents(created)
        return created[0]
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
}

struct AddReusableBlockToAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Aggiungi blocco all'agenda"
    static var description = IntentDescription("Inserisce uno dei blocchi riutilizzabili in un giorno e orario dell'agenda.")

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
        let item = AgendaEvent(id: UUID(), templateID: template.id, name: template.name, durationSlots: template.durationSlots, colorHex: template.colorHex, dateKey: AgendaTime.key(start), startSlot: try AgendaTime.slot(start), reminderMinutes: template.reminderMinutes, location: template.location, notes: template.notes, latitude: template.latitude, longitude: template.longitude, category: template.category, priority: template.priority)
        try store.insertEvents(store.copies(of: item, firstStart: start, count: template.repeatWeeks ?? 1, intervalDays: 7))
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
    static var title: LocalizedStringResource = "Crea blocco riutilizzabile"
    static var description = IntentDescription("Crea un nuovo blocco da riutilizzare nell'agenda.")

    @Parameter(title: "Nome") var name: String
    @Parameter(title: "Durata in minuti", default: 60) var durationMinutes: Int
    @Parameter(title: "Colore", default: .azzurro) var color: AgendaColorChoice
    @Parameter(title: "Luogo") var location: String?
    @Parameter(title: "Promemoria, minuti prima") var reminderMinutes: Int?
    @Parameter(title: "Ripeti per quante settimane") var repeatWeeks: Int?

    @Parameter(title: "Note") var notes: String?
    @Parameter(title: "Latitudine") var latitude: Double?
    @Parameter(title: "Longitudine") var longitude: Double?
    @Parameter(title: "Categoria") var category: String?
    @Parameter(title: "Priorità da 0 a 3") var priority: Int?

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
        guard store.cacheHealthy else { throw AgendaOperationError.invalid("Apri l'app per ripristinare la cache.") }
        try AgendaTime.metadata(reminder: reminderMinutes, latitude: latitude, longitude: longitude, priority: priority)
        if let repeatWeeks, !(1...104).contains(repeatWeeks) { throw AgendaOperationError.invalid("Indica da 1 a 104 settimane.") }
        store.templates.append(BlockTemplate(id: UUID(), name: trimmed, durationSlots: duration, colorHex: color.hex, repeatWeeks: repeatWeeks, reminderMinutes: reminderMinutes, location: location, notes: notes, latitude: latitude, longitude: longitude, category: category, priority: priority))
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Ho creato il blocco \(trimmed), durata \(AgendaIntentBridge.durationText(slots: duration))."))
    }
}

struct EditReusableBlockIntent: AppIntent {
    static var title: LocalizedStringResource = "Modifica blocco riutilizzabile"
    static var description = IntentDescription("Modifica nome, durata o colore di un blocco esistente.")

    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Nuovo nome") var newName: String?
    @Parameter(title: "Nuova durata in minuti") var durationMinutes: Int?
    @Parameter(title: "Nuovo colore") var color: AgendaColorChoice?

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
            updated.latitude = nil
            updated.longitude = nil
        }
        if let reminderMinutes { updated.reminderMinutes = reminderMinutes }
        try store.commitEvent(updated)
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

struct AgendaAppShortcuts: AppShortcutsProvider {
    // Apple permits at most ten automatic shortcuts; every AppIntent remains available in Shortcuts.
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddReusableBlockToAgendaIntent(),
            phrases: ["Aggiungi \(\.$block) in \(.applicationName)", "Pianifica \(\.$block) con \(.applicationName)"],
            shortTitle: "Aggiungi blocco", systemImageName: "calendar.badge.plus")
        AppShortcut(intent: CreateAdvancedAgendaIntent(),
            phrases: ["Aggiungi un impegno in \(.applicationName)", "Crea un impegno con \(.applicationName)", "Metti un impegno in \(.applicationName)"],
            shortTitle: "Nuovo impegno", systemImageName: "plus.rectangle.on.rectangle")
        AppShortcut(intent: MoveAgendaEventIntent(),
            phrases: ["Sposta un impegno in \(.applicationName)"],
            shortTitle: "Sposta impegno", systemImageName: "arrow.right")
        AppShortcut(intent: Delay15AgendaIntent(),
            phrases: ["Sposta \(\.$event) avanti di 15 minuti in \(.applicationName)", "Posticipa \(\.$event) di un quarto d’ora in \(.applicationName)"],
            shortTitle: "Posticipa 15 minuti", systemImageName: "arrow.forward")
        AppShortcut(intent: Advance30AgendaIntent(),
            phrases: ["Anticipa \(\.$event) di mezz’ora in \(.applicationName)", "Sposta \(\.$event) indietro di 30 minuti in \(.applicationName)"],
            shortTitle: "Anticipa mezz’ora", systemImageName: "arrow.backward")
        AppShortcut(intent: Extend30AgendaIntent(),
            phrases: ["Allunga \(\.$event) di 30 minuti in \(.applicationName)"],
            shortTitle: "Allunga 30 minuti", systemImageName: "arrow.up.and.down")
        AppShortcut(intent: OpenNextEventMapsIntent(),
            phrases: ["Apri il luogo del prossimo impegno in Mappe con \(.applicationName)"],
            shortTitle: "Luogo prossimo impegno", systemImageName: "map")
        AppShortcut(intent: ItalianAgendaCommandIntent(),
            phrases: ["Esegui un comando in \(.applicationName)", "Gestisci la mia agenda con \(.applicationName)"],
            shortTitle: "Comando in italiano", systemImageName: "waveform")
        AppShortcut(intent: AgendaForDayIntent(),
            phrases: ["Cosa ho oggi in \(.applicationName)", "Mostra la mia giornata in \(.applicationName)"],
            shortTitle: "Agenda del giorno", systemImageName: "calendar")
        AppShortcut(intent: SyncAgendaIntent(),
            phrases: ["Sincronizza \(.applicationName)"],
            shortTitle: "Sincronizza", systemImageName: "arrow.triangle.2.circlepath")
    }
    static var shortcutTileColor: ShortcutTileColor { .blue }
}

// MARK: - v5.6 extended actions

struct DelayCustomAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Posticipa impegno di minuti personalizzati"
    static var description = IntentDescription("Posticipa impegno di minuti personalizzati. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti", default: 15) var minutes: Int

    static var parameterSummary: some ParameterSummary { Summary("Posticipa \(\.$event) di \(\.$minutes) minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard (15...525600).contains(minutes) else { throw AgendaOperationError.invalid("Indica un numero positivo di minuti, massimo 525600.") }
        let updated = try store.shifted(store.requireEvent(event.id), minutes: minutes)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Delay15AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Posticipa impegno di 15 minuti"
    static var description = IntentDescription("Posticipa impegno di 15 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Posticipa \(\.$event) di 15 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let updated = try store.shifted(store.requireEvent(event.id), minutes: 15)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Delay30AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Posticipa impegno di 30 minuti"
    static var description = IntentDescription("Posticipa impegno di 30 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Posticipa \(\.$event) di 30 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let updated = try store.shifted(store.requireEvent(event.id), minutes: 30)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Delay45AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Posticipa impegno di 45 minuti"
    static var description = IntentDescription("Posticipa impegno di 45 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Posticipa \(\.$event) di 45 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let updated = try store.shifted(store.requireEvent(event.id), minutes: 45)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Delay60AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Posticipa impegno di 60 minuti"
    static var description = IntentDescription("Posticipa impegno di 60 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Posticipa \(\.$event) di 60 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let updated = try store.shifted(store.requireEvent(event.id), minutes: 60)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct AdvanceCustomAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Anticipa impegno di minuti personalizzati"
    static var description = IntentDescription("Anticipa impegno di minuti personalizzati. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti", default: 15) var minutes: Int

    static var parameterSummary: some ParameterSummary { Summary("Anticipa \(\.$event) di \(\.$minutes) minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard (15...525600).contains(minutes) else { throw AgendaOperationError.invalid("Indica un numero positivo di minuti, massimo 525600.") }
        let updated = try store.shifted(store.requireEvent(event.id), minutes: -minutes)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Advance15AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Anticipa impegno di 15 minuti"
    static var description = IntentDescription("Anticipa impegno di 15 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Anticipa \(\.$event) di 15 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let updated = try store.shifted(store.requireEvent(event.id), minutes: -15)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Advance30AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Anticipa impegno di 30 minuti"
    static var description = IntentDescription("Anticipa impegno di 30 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Anticipa \(\.$event) di 30 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let updated = try store.shifted(store.requireEvent(event.id), minutes: -30)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Advance45AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Anticipa impegno di 45 minuti"
    static var description = IntentDescription("Anticipa impegno di 45 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Anticipa \(\.$event) di 45 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let updated = try store.shifted(store.requireEvent(event.id), minutes: -45)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Advance60AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Anticipa impegno di 60 minuti"
    static var description = IntentDescription("Anticipa impegno di 60 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Anticipa \(\.$event) di 60 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let updated = try store.shifted(store.requireEvent(event.id), minutes: -60)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct ExtendCustomAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Allunga impegno di minuti personalizzati"
    static var description = IntentDescription("Allunga impegno di minuti personalizzati. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti", default: 30) var minutes: Int

    static var parameterSummary: some ParameterSummary { Summary("Allunga \(\.$event) di \(\.$minutes) minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let change = try AgendaTime.slots(minutes)
        updated.durationSlots += change
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Extend15AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Allunga impegno di 15 minuti"
    static var description = IntentDescription("Allunga impegno di 15 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Allunga \(\.$event) di 15 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let change = try AgendaTime.slots(15)
        updated.durationSlots += change
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Extend30AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Allunga impegno di 30 minuti"
    static var description = IntentDescription("Allunga impegno di 30 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Allunga \(\.$event) di 30 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let change = try AgendaTime.slots(30)
        updated.durationSlots += change
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Extend60AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Allunga impegno di 60 minuti"
    static var description = IntentDescription("Allunga impegno di 60 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Allunga \(\.$event) di 60 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let change = try AgendaTime.slots(60)
        updated.durationSlots += change
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct ShortenCustomAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Accorcia impegno di minuti personalizzati"
    static var description = IntentDescription("Accorcia impegno di minuti personalizzati. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti", default: 30) var minutes: Int

    static var parameterSummary: some ParameterSummary { Summary("Accorcia \(\.$event) di \(\.$minutes) minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let change = try AgendaTime.slots(minutes)
        updated.durationSlots -= change
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Shorten15AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Accorcia impegno di 15 minuti"
    static var description = IntentDescription("Accorcia impegno di 15 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Accorcia \(\.$event) di 15 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let change = try AgendaTime.slots(15)
        updated.durationSlots -= change
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Shorten30AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Accorcia impegno di 30 minuti"
    static var description = IntentDescription("Accorcia impegno di 30 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Accorcia \(\.$event) di 30 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let change = try AgendaTime.slots(30)
        updated.durationSlots -= change
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct Shorten60AgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Accorcia impegno di 60 minuti"
    static var description = IntentDescription("Accorcia impegno di 60 minuti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity

    static var parameterSummary: some ParameterSummary { Summary("Accorcia \(\.$event) di 60 minuti") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let change = try AgendaTime.slots(60)
        updated.durationSlots -= change
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct DuplicateAtDateAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Duplica impegno"
    static var description = IntentDescription("Duplica impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Inizio della copia", kind: .dateTime) var start: Date


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let original = try store.requireEvent(event.id)
        try store.insertEvents(store.copies(of: original, firstStart: start, count: 1, intervalDays: 1))
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct DuplicateTomorrowAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Duplica impegno al giorno successivo"
    static var description = IntentDescription("Duplica impegno al giorno successivo. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let original = try store.requireEvent(event.id)
        let moved = try store.shifted(original, minutes: 1440)
        let start = try AgendaTime.date(key: moved.dateKey, slot: moved.startSlot)
        try store.insertEvents(store.copies(of: original, firstStart: start, count: 1, intervalDays: 1))
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct DuplicateNextWeekAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Duplica impegno alla settimana successiva"
    static var description = IntentDescription("Duplica impegno alla settimana successiva. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let original = try store.requireEvent(event.id)
        let moved = try store.shifted(original, minutes: 10080)
        let start = try AgendaTime.date(key: moved.dateKey, slot: moved.startSlot)
        try store.insertEvents(store.copies(of: original, firstStart: start, count: 1, intervalDays: 1))
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetStartOnlyAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia solo inizio impegno"
    static var description = IntentDescription("Cambia solo inizio impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nuovo inizio", kind: .dateTime) var start: Date


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        guard AgendaTime.key(start) == updated.dateKey else { throw AgendaOperationError.invalid("Per cambiare giorno usa Sposta impegno. La fine resta fissa.") }
        let endSlot = updated.startSlot + updated.durationSlots
        updated.startSlot = try AgendaTime.slot(start)
        updated.durationSlots = endSlot - updated.startSlot
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetEndOnlyAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia solo fine impegno"
    static var description = IntentDescription("Cambia solo fine impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nuova fine", kind: .dateTime) var end: Date


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let midnight = try AgendaTime.date(key: updated.dateKey, slot: 64)
        let endSlot: Int
        if end == midnight { endSlot = 64 }
        else {
            guard AgendaTime.key(end) == updated.dateKey else { throw AgendaOperationError.invalid("La fine deve essere nello stesso giorno o a mezzanotte.") }
            endSlot = try AgendaTime.slot(end)
        }
        updated.durationSlots = endSlot - updated.startSlot
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetReminderAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Aggiungi o cambia promemoria"
    static var description = IntentDescription("Aggiungi o cambia promemoria. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Minuti prima", default: 15) var minutes: Int


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.reminderMinutes = minutes
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct RemoveReminderAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Rimuovi promemoria"
    static var description = IntentDescription("Rimuovi promemoria. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.reminderMinutes = nil
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetLocationAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia luogo e coordinate"
    static var description = IntentDescription("Cambia luogo e coordinate. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Luogo") var location: String
    @Parameter(title: "Latitudine") var latitude: Double?
    @Parameter(title: "Longitudine") var longitude: Double?


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.latitude = latitude
        updated.longitude = longitude
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct RemoveLocationAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Rimuovi luogo e coordinate"
    static var description = IntentDescription("Rimuovi luogo e coordinate. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.location = nil
        updated.latitude = nil
        updated.longitude = nil
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetNotesAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Scrivi note impegno"
    static var description = IntentDescription("Scrivi note impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Note") var notes: String


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.notes = notes
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct AppendNotesAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Aggiungi testo alle note"
    static var description = IntentDescription("Aggiungi testo alle note. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Testo da aggiungere") var text: String


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.notes = [updated.notes, text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct ClearNotesAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancella note impegno"
    static var description = IntentDescription("Cancella note impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.notes = nil
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct MarkNotesAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Segna nota completata"
    static var description = IntentDescription("Segna nota completata. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Nota da marcare") var text: String


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgendaOperationError.invalid("Indica la nota completata.") }
        updated.notes = [updated.notes, "✓ " + text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetColorAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia colore impegno"
    static var description = IntentDescription("Cambia colore impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Colore") var color: AgendaColorChoice


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.colorHex = color.hex
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetCategoryAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia categoria impegno"
    static var description = IntentDescription("Cambia categoria impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Categoria (vuota per rimuovere)") var category: String


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.category = category.isEmpty ? nil : category
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetPriorityAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia priorità impegno"
    static var description = IntentDescription("Cambia priorità impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Priorità da 0 a 3", default: 2) var priority: Int


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        updated.priority = priority
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SetAssociatedBlockAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Cambia blocco associato"
    static var description = IntentDescription("Cambia blocco associato. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Usa anche nome e colore del blocco", default: true) var useAppearance: Bool


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        guard let template = store.template(id: block.id) else { throw AgendaOperationError.invalid("Blocco non trovato.") }
        updated.templateID = template.id
        if useAppearance { updated.name = template.name; updated.colorHex = template.colorHex }
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct ReadNotesAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Leggi note e dettagli impegno"
    static var description = IntentDescription("Leggi note e dettagli impegno. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let store = AgendaIntentBridge.makeStore()
        let item = try store.requireEvent(event.id)
        let answer = "\(item.name). Note: \(item.notes ?? "nessuna"). Categoria: \(item.category ?? "nessuna"). Priorità: \(item.priority ?? 0). Luogo: \(item.location ?? "nessuno"). Promemoria: " + (item.reminderMinutes.map { "\($0) minuti prima" } ?? "nessuno")

        return .result(value: answer, dialog: AgendaIntentBridge.dialog(answer))
    }
}

struct CreateRecurringCopiesAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Crea più copie ricorrenti"
    static var description = IntentDescription("Crea più copie ricorrenti. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Inizio prima copia", kind: .dateTime) var start: Date
    @Parameter(title: "Numero copie", default: 4) var count: Int
    @Parameter(title: "Intervallo in giorni", default: 7) var intervalDays: Int


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let original = try store.requireEvent(event.id)
        try store.insertEvents(store.copies(of: original, firstStart: start, count: count, intervalDays: intervalDays))

        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct SkipOccurrenceAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Salta questa occorrenza"
    static var description = IntentDescription("Salta questa occorrenza. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let item = try store.requireEvent(event.id)
        guard item.seriesID != nil else { throw AgendaOperationError.invalid("Questo impegno non appartiene a una serie.") }
        try store.removeEvents([item])

        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct DeleteDayAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Elimina impegni del giorno con conferma"
    static var description = IntentDescription("Elimina impegni del giorno con conferma. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Giorno", kind: .date) var date: Date


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let selected = store.events(on: AgendaTime.key(date))
        guard !selected.isEmpty else { return .result(dialog: AgendaIntentBridge.dialog("Non ci sono impegni da eliminare.")) }
        let listing = selected.prefix(8).map { $0.name }.joined(separator: ", ")
        try await requestConfirmation(result: .result(dialog: AgendaIntentBridge.dialog("Eliminare tutti i \(selected.count) impegni del \(AgendaTime.key(date))? \(listing). Le altre date resteranno in agenda.")))
        // Reload after the system confirmation; never delete data changed in the meantime.
        let current = AgendaIntentBridge.makeStore()
        guard current.events(on: AgendaTime.key(date)) == selected else { throw AgendaOperationError.invalid("L'agenda è cambiata durante la conferma. Riprova per confermare l'elenco aggiornato.") }
        try current.removeEvents(selected)
        await AgendaIntentBridge.finishMutation(current)

        return .result(dialog: AgendaIntentBridge.dialog("Eliminati \(selected.count) impegni."))
    }
}

struct NextFreeSlotAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Trova il prossimo spazio libero"
    static var description = IntentDescription("Trova il prossimo spazio libero. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Cerca a partire da", kind: .dateTime) var after: Date?
    @Parameter(title: "Dalle ore", default: 8) var fromHour: Int
    @Parameter(title: "Alle ore", default: 20) var toHour: Int
    @Parameter(title: "Giorni da cercare", default: 30) var days: Int
    @Parameter(title: "Durata in minuti", default: 60) var durationMinutes: Int


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Date> {
        let store = AgendaIntentBridge.makeStore()
        let duration = try AgendaTime.slots(durationMinutes)
        let start = try store.nextFreeStart(after: after ?? Date(), durationSlots: duration, fromHour: fromHour, toHour: toHour, days: days)

        return .result(value: start, dialog: AgendaIntentBridge.dialog("Spazio libero \(AgendaIntentBridge.spokenDateTime(start)), per \(durationMinutes) minuti."))
    }
}

struct MoveToNextFreeSlotAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Sposta impegno al prossimo spazio libero"
    static var description = IntentDescription("Sposta impegno al prossimo spazio libero. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity
    @Parameter(title: "Cerca a partire da", kind: .dateTime) var after: Date?
    @Parameter(title: "Dalle ore", default: 8) var fromHour: Int
    @Parameter(title: "Alle ore", default: 20) var toHour: Int
    @Parameter(title: "Giorni da cercare", default: 30) var days: Int


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        var updated = try store.requireEvent(event.id)
        let originalStart = try AgendaTime.date(key: updated.dateKey, slot: updated.startSlot)
        let lowerBound = after ?? max(Date(), originalStart.addingTimeInterval(15 * 60))
        let start = try store.nextFreeStart(after: lowerBound, durationSlots: updated.durationSlots, fromHour: fromHour, toHour: toHour, days: days, excluding: updated.id)
        updated.dateKey = AgendaTime.key(start)
        updated.startSlot = try AgendaTime.slot(start)
        try store.commitEvent(updated)
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct InsertBlockNextFreeSlotAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Inserisci blocco nel prossimo spazio libero"
    static var description = IntentDescription("Inserisci blocco nel prossimo spazio libero. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Cerca a partire da", kind: .dateTime) var after: Date?
    @Parameter(title: "Dalle ore", default: 8) var fromHour: Int
    @Parameter(title: "Alle ore", default: 20) var toHour: Int
    @Parameter(title: "Giorni da cercare", default: 30) var days: Int


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard let template = store.template(id: block.id) else { throw AgendaOperationError.invalid("Blocco non trovato.") }
        let start = try store.nextFreeStart(after: after ?? Date(), durationSlots: template.durationSlots, fromHour: fromHour, toHour: toHour, days: days)
        let item = AgendaEvent(id: UUID(), templateID: template.id, name: template.name, durationSlots: template.durationSlots, colorHex: template.colorHex, dateKey: AgendaTime.key(start), startSlot: try AgendaTime.slot(start), reminderMinutes: template.reminderMinutes, location: template.location, notes: template.notes, latitude: template.latitude, longitude: template.longitude, category: template.category, priority: template.priority)
        try store.insertEvents([item])

        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

extension AgendaIntentBridge {
    static func mapsURL(_ item: AgendaEvent) throws -> URL {
        try AgendaTime.metadata(reminder: nil, latitude: item.latitude, longitude: item.longitude, priority: nil)
        var parts = URLComponents(string: "https://maps.apple.com/")!
        if let lat = item.latitude, let lon = item.longitude {
            parts.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lon)"), URLQueryItem(name: "q", value: item.location ?? item.name)]
        } else if let text = item.location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            parts.queryItems = [URLQueryItem(name: "q", value: text)]
        } else { throw AgendaOperationError.invalid("Questo impegno non ha un luogo. Aggiungilo prima di aprire Mappe.") }
        guard let url = parts.url else { throw AgendaOperationError.invalid("Luogo non valido.") }
        return url
    }
}

struct OpenEventMapsIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri luogo impegno in Mappe"
    static var openAppWhenRun: Bool = true
    static var description = IntentDescription("Apri luogo impegno in Mappe. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Impegno") var event: AgendaEventEntity


    @MainActor
    func perform() async throws -> some IntentResult {
        let store = AgendaIntentBridge.makeStore()
        let item = try store.requireEvent(event.id)
        let url = try AgendaIntentBridge.mapsURL(item)

        guard await UIApplication.shared.open(url, options: [:]) else {
            throw AgendaOperationError.invalid("Non riesco ad aprire Mappe per questo luogo.")
        }
        return .result()
    }
}

struct OpenNextEventMapsIntent: AppIntent {
    static var title: LocalizedStringResource = "Apri il luogo del prossimo impegno in Mappe"
    static var openAppWhenRun: Bool = true
    static var description = IntentDescription("Apri il luogo del prossimo impegno in Mappe. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")


    @MainActor
    func perform() async throws -> some IntentResult {
        let store = AgendaIntentBridge.makeStore()
        guard let item = store.events.filter({ (AgendaIntentBridge.eventDate($0) ?? .distantPast) >= Date() }).sorted(by: AgendaIntentBridge.eventSort).first else { throw AgendaOperationError.invalid("Non hai impegni futuri.") }
        let url = try AgendaIntentBridge.mapsURL(item)

        guard await UIApplication.shared.open(url, options: [:]) else {
            throw AgendaOperationError.invalid("Non riesco ad aprire Mappe per questo luogo.")
        }
        return .result()
    }
}

struct CreateAdvancedAgendaIntent: AppIntent {
    static var title: LocalizedStringResource = "Crea impegno con durata e opzioni"
    static var description = IntentDescription("Crea impegno con durata e opzioni. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Nome") var name: String
    @Parameter(title: "Inizio", kind: .dateTime) var start: Date
    @Parameter(title: "Nome personalizzato") var customName: String?
    @Parameter(title: "Fine (alternativa alla durata)", kind: .dateTime) var end: Date?
    @Parameter(title: "Durata esplicita in minuti") var durationMinutes: Int?
    @Parameter(title: "Colore") var color: AgendaColorChoice?
    @Parameter(title: "Luogo") var location: String?
    @Parameter(title: "Latitudine") var latitude: Double?
    @Parameter(title: "Longitudine") var longitude: Double?
    @Parameter(title: "Note") var notes: String?
    @Parameter(title: "Promemoria, minuti prima") var reminderMinutes: Int?
    @Parameter(title: "Categoria") var category: String?
    @Parameter(title: "Priorità da 0 a 3") var priority: Int?
    @Parameter(title: "Numero occorrenze", default: 1) var count: Int
    @Parameter(title: "Ogni quanti giorni", default: 7) var intervalDays: Int

    static var parameterSummary: some ParameterSummary { Summary("Metti \(\.$name) da \(\.$start)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var template = AgendaIntentBridge.matchingTemplate(named: clean, in: store) ?? BlockTemplate(id: UUID(), name: clean, durationSlots: 4, colorHex: "#B8DFF5")
        let startSlot = try AgendaTime.slot(start)
        if let end {
            let midnight = try AgendaTime.date(key: AgendaTime.key(start), slot: 64)
            let endSlot: Int
            if end == midnight { endSlot = 64 }
            else {
                guard AgendaTime.key(end) == AgendaTime.key(start) else { throw AgendaOperationError.invalid("La fine deve essere nello stesso giorno o a mezzanotte.") }
                endSlot = try AgendaTime.slot(end)
            }
            template.durationSlots = endSlot - startSlot
            if let durationMinutes, try AgendaTime.slots(durationMinutes) != template.durationSlots { throw AgendaOperationError.invalid("Fine e durata indicano intervalli diversi. Specifica uno dei due o valori coerenti.") }
        } else if let durationMinutes { template.durationSlots = try AgendaTime.slots(durationMinutes) }
        if let customName { template.name = customName.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let color { template.colorHex = color.hex }
        if let location { template.location = location; template.latitude = nil; template.longitude = nil }
        if latitude != nil || longitude != nil { template.latitude = latitude; template.longitude = longitude }
        if let notes { template.notes = notes }
        if let reminderMinutes { template.reminderMinutes = reminderMinutes }
        if let category { template.category = category }
        if let priority { template.priority = priority }
        let item = AgendaEvent(id: UUID(), templateID: template.id, name: template.name, durationSlots: template.durationSlots, colorHex: template.colorHex, dateKey: AgendaTime.key(start), startSlot: startSlot, reminderMinutes: template.reminderMinutes, location: template.location, notes: template.notes, latitude: template.latitude, longitude: template.longitude, category: template.category, priority: template.priority)
        try store.insertEvents(store.copies(of: item, firstStart: start, count: count, intervalDays: intervalDays))

        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct CreateFromBlockAdvancedIntent: AppIntent {
    static var title: LocalizedStringResource = "Crea impegno da blocco con opzioni"
    static var description = IntentDescription("Crea impegno da blocco con opzioni. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Inizio", kind: .dateTime) var start: Date
    @Parameter(title: "Nome personalizzato") var customName: String?
    @Parameter(title: "Fine (alternativa alla durata)", kind: .dateTime) var end: Date?
    @Parameter(title: "Durata esplicita in minuti") var durationMinutes: Int?
    @Parameter(title: "Colore") var color: AgendaColorChoice?
    @Parameter(title: "Luogo") var location: String?
    @Parameter(title: "Latitudine") var latitude: Double?
    @Parameter(title: "Longitudine") var longitude: Double?
    @Parameter(title: "Note") var notes: String?
    @Parameter(title: "Promemoria, minuti prima") var reminderMinutes: Int?
    @Parameter(title: "Categoria") var category: String?
    @Parameter(title: "Priorità da 0 a 3") var priority: Int?
    @Parameter(title: "Numero occorrenze", default: 1) var count: Int
    @Parameter(title: "Ogni quanti giorni", default: 7) var intervalDays: Int

    static var parameterSummary: some ParameterSummary { Summary("Pianifica \(\.$block) da \(\.$start)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var template = store.template(id: block.id) else { throw AgendaOperationError.invalid("Blocco non trovato.") }
        let startSlot = try AgendaTime.slot(start)
        if let end {
            let midnight = try AgendaTime.date(key: AgendaTime.key(start), slot: 64)
            let endSlot: Int
            if end == midnight { endSlot = 64 }
            else {
                guard AgendaTime.key(end) == AgendaTime.key(start) else { throw AgendaOperationError.invalid("La fine deve essere nello stesso giorno o a mezzanotte.") }
                endSlot = try AgendaTime.slot(end)
            }
            template.durationSlots = endSlot - startSlot
            if let durationMinutes, try AgendaTime.slots(durationMinutes) != template.durationSlots { throw AgendaOperationError.invalid("Fine e durata indicano intervalli diversi. Specifica uno dei due o valori coerenti.") }
        } else if let durationMinutes { template.durationSlots = try AgendaTime.slots(durationMinutes) }
        if let customName { template.name = customName.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let color { template.colorHex = color.hex }
        if let location { template.location = location; template.latitude = nil; template.longitude = nil }
        if latitude != nil || longitude != nil { template.latitude = latitude; template.longitude = longitude }
        if let notes { template.notes = notes }
        if let reminderMinutes { template.reminderMinutes = reminderMinutes }
        if let category { template.category = category }
        if let priority { template.priority = priority }
        let item = AgendaEvent(id: UUID(), templateID: template.id, name: template.name, durationSlots: template.durationSlots, colorHex: template.colorHex, dateKey: AgendaTime.key(start), startSlot: startSlot, reminderMinutes: template.reminderMinutes, location: template.location, notes: template.notes, latitude: template.latitude, longitude: template.longitude, category: template.category, priority: template.priority)
        try store.insertEvents(store.copies(of: item, firstStart: start, count: count, intervalDays: intervalDays))

        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct ConfigureBlockDefaultsIntent: AppIntent {
    static var title: LocalizedStringResource = "Configura opzioni del blocco"
    static var description = IntentDescription("Configura opzioni del blocco. Gli orari seguono la griglia di 15 minuti; i conflitti vengono segnalati senza sovrascrivere altri impegni.")
    @Parameter(title: "Blocco") var block: AgendaBlockEntity
    @Parameter(title: "Luogo") var location: String?
    @Parameter(title: "Latitudine") var latitude: Double?
    @Parameter(title: "Longitudine") var longitude: Double?
    @Parameter(title: "Note") var notes: String?
    @Parameter(title: "Promemoria, minuti prima") var reminderMinutes: Int?
    @Parameter(title: "Rimuovi promemoria", default: false) var removeReminder: Bool
    @Parameter(title: "Categoria") var category: String?
    @Parameter(title: "Priorità da 0 a 3") var priority: Int?
    @Parameter(title: "Ripeti per quante settimane") var repeatWeeks: Int?


    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        guard var template = store.template(id: block.id), store.cacheHealthy else { throw AgendaOperationError.invalid("Blocco non disponibile.") }
        if let location { template.location = location; template.latitude = nil; template.longitude = nil }
        if latitude != nil || longitude != nil { template.latitude = latitude; template.longitude = longitude }
        if let notes { template.notes = notes }
        if let category { template.category = category }
        if let priority { template.priority = priority }
        if let reminderMinutes { template.reminderMinutes = reminderMinutes }
        if removeReminder { template.reminderMinutes = nil }
        if let repeatWeeks {
            guard (1...104).contains(repeatWeeks) else { throw AgendaOperationError.invalid("Indica da 1 a 104 settimane.") }
            template.repeatWeeks = repeatWeeks > 1 ? repeatWeeks : nil
        }
        try AgendaTime.metadata(reminder: template.reminderMinutes, latitude: template.latitude, longitude: template.longitude, priority: template.priority)
        store.updateTemplate(template)

        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog("Fatto. Agenda aggiornata."))
    }
}

struct ItalianAgendaCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Esegui comando agenda in italiano"
    static var description = IntentDescription("Spostamenti, durate e creazione da una frase italiana. Esempio: metti Palestra domani alle 18 per un'ora con promemoria 15 minuti prima e luogo Eden Bibbiano. Per nomi ambigui usa l'azione con selezione dell'impegno.")
    @Parameter(title: "Comando", requestValueDialog: "Quale comando vuoi eseguire? Puoi dire: sposta Palestra avanti di 15 minuti.") var command: String

    static var parameterSummary: some ParameterSummary { Summary("Esegui \(\.$command)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AgendaIntentBridge.makeStore()
        let parsed = try AgendaVoiceCommand.parse(command)
        let answer: String
        switch parsed {
        case .shift(let name, let minutes), .resize(let name, let minutes):
            let matches = store.events.filter {
                $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame &&
                (AgendaIntentBridge.eventDate($0)?.addingTimeInterval(Double($0.durationSlots * 900)) ?? .distantPast) > Date()
            }
            guard matches.count == 1, var item = matches.first else {
                throw AgendaOperationError.invalid(matches.isEmpty ? "Non trovo un impegno futuro chiamato \(name)." : "Ci sono più impegni chiamati \(name). Usa l'azione Sposta impegno o Allunga impegno e scegli la data: non ne ho modificato nessuno.")
            }
            switch parsed {
            case .shift: item = try store.shifted(item, minutes: minutes)
            default: item.durationSlots += try AgendaTime.slots(minutes, signed: true)
            }
            try store.commitEvent(item)
            answer = "\(item.name): \(AgendaIntentBridge.entitySubtitle(dateKey: item.dateKey, startSlot: item.startSlot)), durata \(item.durationSlots * 15) minuti."
        case .create(let name, let day, let hour, let minute, let duration, let reminder, let location):
            let date: Date
            if let offset = ["oggi": 0, "domani": 1, "dopodomani": 2][day] {
                date = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
            } else { date = try AgendaTime.day(day) }
            guard minute % 15 == 0 else { throw AgendaOperationError.invalid("L'orario deve essere sulla griglia di 15 minuti.") }
            let start = try AgendaTime.date(key: AgendaTime.key(date), slot: hour * 4 + minute / 15 - 32)
            let item = try AgendaIntentBridge.addCustomEvent(to: store, name: name, start: start, durationSlots: AgendaTime.slots(duration), repeatWeeks: 1, reminderMinutes: reminder, location: location)
            answer = "Inserito \(item.name), \(AgendaIntentBridge.spokenDateTime(start)), per \(duration) minuti."
        }
        await AgendaIntentBridge.finishMutation(store)
        return .result(dialog: AgendaIntentBridge.dialog(answer))
    }
}
