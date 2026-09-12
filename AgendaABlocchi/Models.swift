import Foundation
import SwiftUI
import Combine
import UserNotifications

struct BlockTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var durationSlots: Int
    var colorHex: String

    var repeatWeeks: Int?
    var reminderMinutes: Int?
    var location: String?
    // v5.6: optional keys preserve decoding of v1/v5.5 snapshots.
    var notes: String?
    var latitude: Double?
    var longitude: Double?
    var category: String?
    var priority: Int?
}

struct AgendaEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var templateID: UUID
    var name: String
    var durationSlots: Int
    var colorHex: String
    var dateKey: String
    var startSlot: Int

    var repeatWeeks: Int?
    var reminderMinutes: Int?
    var location: String?
    var seriesID: UUID?
    // v5.6: optional keys preserve decoding of v1/v5.5 snapshots.
    var notes: String?
    var latitude: Double?
    var longitude: Double?
    var category: String?
    var priority: Int?
}

@MainActor
final class AgendaStore: ObservableObject {
    @Published var templates: [BlockTemplate] {
        didSet { save() }
    }

    @Published var events: [AgendaEvent] {
        didSet { save() }
    }

    @Published var syncStatus = "Solo su questo dispositivo"
    @Published var syncError: String?
    @Published var signedInEmail: String?
    @Published var syncBusy = false
    @Published var needsMigrationChoice = false
    @Published var needsReauthentication = false
    @Published var backups: [AgendaBackup] = []
    var session: AgendaSession?
    var localRevision = Date(timeIntervalSince1970: 0)
    var ownerID: UUID?
    var migrated = false
    var hasLegacyData = false
    var dirty = false
    var applyingSnapshot = false
    var syncAgain = false
    var cacheHealthy = true
    let defaults: UserDefaults
    var loadSession: () throws -> AgendaSession? = { try AgendaKeychain.read() }
    var saveSession: (AgendaSession) throws -> Void = { try AgendaKeychain.write($0) }
    var deleteSession: () throws -> Void = { try AgendaKeychain.remove() }
    let cacheKey = "agenda.sync.v54"

    private let templatesKey = "agenda.templates.v1"
    private let eventsKey = "agenda.events.v1"

    init(defaults: UserDefaults = .standard,
         loadSession: @escaping () throws -> AgendaSession? = { try AgendaKeychain.read() }) {
        self.defaults = defaults
        self.loadSession = loadSession
        let decoder = JSONDecoder()

        if let data = defaults.data(forKey: templatesKey),
           let decoded = try? decoder.decode([BlockTemplate].self, from: data) {
            templates = decoded
        } else {
            templates = [
                BlockTemplate(
                    id: UUID(),
                    name: "Università",
                    durationSlots: 4,
                    colorHex: "#F2B6C8",
                    repeatWeeks: nil,
                    reminderMinutes: nil,
                    location: nil
                ),
                BlockTemplate(
                    id: UUID(),
                    name: "Studio",
                    durationSlots: 8,
                    colorHex: "#B8DFF5",
                    repeatWeeks: nil,
                    reminderMinutes: nil,
                    location: nil
                ),
                BlockTemplate(
                    id: UUID(),
                    name: "Palestra",
                    durationSlots: 6,
                    colorHex: "#BFE5C5",
                    repeatWeeks: nil,
                    reminderMinutes: nil,
                    location: nil
                ),
                BlockTemplate(
                    id: UUID(),
                    name: "Pranzo",
                    durationSlots: 4,
                    colorHex: "#FFE59A",
                    repeatWeeks: nil,
                    reminderMinutes: nil,
                    location: nil
                )
            ]
        }

        if let data = defaults.data(forKey: eventsKey),
           let decoded = try? decoder.decode([AgendaEvent].self, from: data) {
            events = decoded
        } else {
            events = []
        }
        restoreSyncCache()
    }

    func addTemplate(
        name: String,
        durationSlots: Int,
        colorHex: String,
        repeatWeeks: Int?,
        reminderMinutes: Int?,
        location: String?
    ) {
        templates.append(
            BlockTemplate(
                id: UUID(),
                name: name,
                durationSlots: durationSlots,
                colorHex: colorHex,
                repeatWeeks: repeatWeeks,
                reminderMinutes: reminderMinutes,
                location: cleaned(location)
            )
        )
    }

    func updateTemplate(_ updated: BlockTemplate) {
        guard let index = templates.firstIndex(where: { $0.id == updated.id }) else {
            return
        }
        templates[index] = updated
    }

    func deleteTemplate(_ template: BlockTemplate) {
        templates.removeAll { $0.id == template.id }
    }

    func template(id: UUID) -> BlockTemplate? {
        templates.first { $0.id == id }
    }

    @discardableResult
    func addEvent(template: BlockTemplate, dateKey: String, startSlot: Int) -> String? {
        guard (1...96).contains(template.durationSlots), (1...104).contains(template.repeatWeeks ?? 1) else { return "Durata o ripetizione non valida (massimo 104 settimane)." }
        let repeatCount = max(1, template.repeatWeeks ?? 1)

        if startSlot < -32 || startSlot >= 64 {
            return "Orario non valido."
        }

        if startSlot + template.durationSlots > 64 {
            return "Il blocco supererebbe la mezzanotte."
        }

        if hasOverlap(
            dateKey: dateKey,
            startSlot: startSlot,
            durationSlots: template.durationSlots,
            excluding: nil
        ) {
            return "C'è già un impegno in quell'orario."
        }

        let series = repeatCount > 1 ? UUID() : nil

        for index in 0..<repeatCount {
            guard let occurrenceDate = dateKeyAddingWeeks(index, to: dateKey) else {
                continue
            }

            if index > 0 && hasOverlap(
                dateKey: occurrenceDate,
                startSlot: startSlot,
                durationSlots: template.durationSlots,
                excluding: nil
            ) {
                continue
            }

            let event = AgendaEvent(
                id: UUID(),
                templateID: template.id,
                name: template.name,
                durationSlots: template.durationSlots,
                colorHex: template.colorHex,
                dateKey: occurrenceDate,
                startSlot: startSlot,
                repeatWeeks: repeatCount > 1 ? repeatCount : nil,
                reminderMinutes: template.reminderMinutes,
                location: cleaned(template.location),
                seriesID: series,
                notes: template.notes, latitude: template.latitude, longitude: template.longitude,
                category: template.category, priority: template.priority
            )

            events.append(event)
            scheduleNotification(for: event)
        }

        return nil
    }

    @discardableResult
    func moveEvent(id: UUID, toDateKey dateKey: String, startSlot: Int) -> String? {
        guard let index = events.firstIndex(where: { $0.id == id }) else {
            return "Impegno non trovato."
        }

        let current = events[index]

        if startSlot < -32 || startSlot >= 64 {
            return "Orario non valido."
        }

        if startSlot + current.durationSlots > 64 {
            return "Il blocco supererebbe la mezzanotte."
        }

        if hasOverlap(
            dateKey: dateKey,
            startSlot: startSlot,
            durationSlots: current.durationSlots,
            excluding: id
        ) {
            return "C'è già un impegno in quell'orario."
        }

        cancelNotification(id: id)
        events[index].dateKey = dateKey
        events[index].startSlot = startSlot
        scheduleNotification(for: events[index])
        return nil
    }

    @discardableResult
    func updateEvent(_ updatedInput: AgendaEvent) -> String? {
        guard let index = events.firstIndex(where: { $0.id == updatedInput.id }) else {
            return "Impegno non trovato."
        }

        var updated = updatedInput
        updated.location = cleaned(updated.location)
        guard (1...96).contains(updated.durationSlots) else { return "La durata deve essere tra 15 e 1440 minuti." }

        if updated.startSlot < -32 || updated.startSlot >= 64 {
            return "Orario non valido."
        }

        if updated.startSlot + updated.durationSlots > 64 {
            return "L'impegno supererebbe la mezzanotte."
        }

        if hasOverlap(
            dateKey: updated.dateKey,
            startSlot: updated.startSlot,
            durationSlots: updated.durationSlots,
            excluding: updated.id
        ) {
            return "C'è già un impegno in quell'orario."
        }

        cancelNotification(id: events[index].id)
        events[index] = updated
        scheduleNotification(for: updated)

        return nil
    }

    func deleteEvent(_ event: AgendaEvent) {
        cancelNotification(id: event.id)
        events.removeAll { $0.id == event.id }
    }

    func events(on dateKey: String) -> [AgendaEvent] {
        events
            .filter { $0.dateKey == dateKey }
            .sorted { $0.startSlot < $1.startSlot }
    }

    private func hasOverlap(
        dateKey: String,
        startSlot: Int,
        durationSlots: Int,
        excluding eventID: UUID?
    ) -> Bool {
        let newEnd = startSlot + durationSlots

        return events.contains { event in
            if event.id == eventID {
                return false
            }

            if event.dateKey != dateKey {
                return false
            }

            let oldEnd = event.startSlot + event.durationSlots
            return startSlot < oldEnd && newEnd > event.startSlot
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value = value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func dateKeyAddingWeeks(_ weeks: Int, to dateKey: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        guard let date = formatter.date(from: dateKey) else {
            return nil
        }

        guard let nextDate = Calendar.current.date(
            byAdding: .day,
            value: weeks * 7,
            to: date
        ) else {
            return nil
        }

        return formatter.string(from: nextDate)
    }

    private func scheduleNotification(for event: AgendaEvent) {
#if !SYNC_TESTING
        guard let reminder = event.reminderMinutes else {
            return
        }

        guard let startDate = eventStartDate(event) else {
            return
        }

        let fireDate = Calendar.current.date(
            byAdding: .minute,
            value: -reminder,
            to: startDate
        ) ?? startDate

        guard fireDate > Date() else {
            return
        }

        let center = UNUserNotificationCenter.current()

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = event.name

            if let location = event.location, !location.isEmpty {
                content.body = location
            } else {
                content.body = "Hai un impegno in agenda."
            }

            content.sound = UNNotificationSound.default

            let parts = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: fireDate
            )

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: parts,
                repeats: false
            )

            let request = UNNotificationRequest(
                identifier: event.id.uuidString,
                content: content,
                trigger: trigger
            )

            center.add(request)
        }
#endif
    }

    private func cancelNotification(id: UUID) {
#if !SYNC_TESTING
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id.uuidString])
#endif
    }

    private func eventStartDate(_ event: AgendaEvent) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        guard let day = formatter.date(from: event.dateKey) else {
            return nil
        }

        let minutes = 8 * 60 + event.startSlot * 15

        return Calendar.current.date(
            bySettingHour: minutes / 60,
            minute: minutes % 60,
            second: 0,
            of: day
        )
    }

    func applySnapshot(_ payload: AgendaPayload) {
        applyingSnapshot = true
        for event in events { cancelNotification(id: event.id) }
        templates = payload.templates
        events = payload.events
        applyingSnapshot = false
        for event in events { scheduleNotification(for: event) }
    }

    private func save() {
        guard !applyingSnapshot else { return }
        recordLocalChange()
        let encoder = JSONEncoder()

        if let data = try? encoder.encode(templates) {
            defaults.set(data, forKey: templatesKey)
        }

        if let data = try? encoder.encode(events) {
            defaults.set(data, forKey: eventsKey)
        }
    }
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r: Double
        let g: Double
        let b: Double

        if cleaned.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255.0
            g = Double((value >> 8) & 0xFF) / 255.0
            b = Double(value & 0xFF) / 255.0
        } else {
            r = 0.75
            g = 0.82
            b = 0.95
        }

        self.init(red: r, green: g, blue: b)
    }

    static func darker(hex: String, amount: Double = 0.28) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        guard cleaned.count == 6 else {
            return Color.black.opacity(0.35)
        }

        let factor = max(0.0, 1.0 - amount)
        let r = Double((value >> 16) & 0xFF) / 255.0 * factor
        let g = Double((value >> 8) & 0xFF) / 255.0 * factor
        let b = Double(value & 0xFF) / 255.0 * factor

        return Color(red: r, green: g, blue: b)
    }
}

// v5.6 operations share the same validation and persistence as the agenda UI.
enum AgendaOperationError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

enum AgendaTime {
    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.current.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func day(_ key: String) throws -> Date {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Calendar.current.timeZone
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let date = f.date(from: key), self.key(date) == key else {
            throw AgendaOperationError.invalid("Data non valida.")
        }
        return date
    }
    static func slots(_ minutes: Int, signed: Bool = false) throws -> Int {
        guard (-525600...525600).contains(minutes), minutes % 15 == 0,
              signed || (15...1440).contains(minutes) else {
            throw AgendaOperationError.invalid("L'agenda usa intervalli di 15 minuti. Indica un multiplo di 15; la durata deve essere tra 15 e 1440 minuti.")
        }
        return minutes / 15
    }
    static func slot(_ date: Date) throws -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        guard let h = c.hour, let m = c.minute, m % 15 == 0, c.second == 0 else {
            throw AgendaOperationError.invalid("Indica un orario esatto sulla griglia di 15 minuti, per esempio 18:00 o 18:15.")
        }
        return (h * 60 + m - 480) / 15
    }
    static func date(key: String, slot: Int) throws -> Date {
        let day = try self.day(key)
        if slot == 64 { return Calendar.current.date(byAdding: .day, value: 1, to: day)! }
        guard (-32..<64).contains(slot) else { throw AgendaOperationError.invalid("Orario non valido.") }
        let m = 480 + slot * 15
        guard let date = Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day),
              self.key(date) == key,
              Calendar.current.component(.hour, from: date) == m / 60,
              Calendar.current.component(.minute, from: date) == m % 60 else {
            throw AgendaOperationError.invalid("L'orario non esiste nel giorno scelto a causa del cambio dell'ora.")
        }
        return date
    }
    static func metadata(reminder: Int?, latitude: Double?, longitude: Double?, priority: Int?) throws {
        if let reminder, !(0...525600).contains(reminder) { throw AgendaOperationError.invalid("Il promemoria deve essere tra 0 e 525600 minuti prima.") }
        if (latitude == nil) != (longitude == nil) { throw AgendaOperationError.invalid("Servono entrambe le coordinate.") }
        if let latitude, let longitude, (!latitude.isFinite || !longitude.isFinite || !(-90...90).contains(latitude) || !(-180...180).contains(longitude)) {
            throw AgendaOperationError.invalid("Coordinate non valide.")
        }
        if let priority, !(0...3).contains(priority) { throw AgendaOperationError.invalid("Priorità: 0 nessuna, 1 bassa, 2 media, 3 alta.") }
    }
}

extension AgendaStore {
    func requireEvent(_ id: UUID) throws -> AgendaEvent {
        guard let event = events.first(where: { $0.id == id }) else { throw AgendaOperationError.invalid("Quell'impegno non esiste più.") }
        return event
    }
    func validate(_ event: AgendaEvent, against others: [AgendaEvent]) throws {
        guard cacheHealthy else { throw AgendaOperationError.invalid("Apri l'app e ripristina la cache prima di modificare l'agenda.") }
        guard !event.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...96).contains(event.durationSlots), (-32..<64).contains(event.startSlot),
              event.startSlot + event.durationSlots <= 64 else { throw AgendaOperationError.invalid("Nome o durata non validi, oppure l'impegno supera la mezzanotte.") }
        _ = try AgendaTime.date(key: event.dateKey, slot: event.startSlot)
        _ = try AgendaTime.date(key: event.dateKey, slot: event.startSlot + event.durationSlots)
        try AgendaTime.metadata(reminder: event.reminderMinutes, latitude: event.latitude, longitude: event.longitude, priority: event.priority)
        guard !others.contains(where: { $0.id != event.id && $0.dateKey == event.dateKey && event.startSlot < $0.startSlot + $0.durationSlots && event.startSlot + event.durationSlots > $0.startSlot }) else {
            throw AgendaOperationError.invalid("C'è già un impegno in quell'orario. Nessuna modifica effettuata.")
        }
    }
    func commitEvent(_ event: AgendaEvent) throws {
        try validate(event, against: events)
        if let error = updateEvent(event) { throw AgendaOperationError.invalid(error) }
    }
    // Validate the entire batch first: a conflicting recurrence never leaves partial copies.
    func insertEvents(_ additions: [AgendaEvent]) throws {
        guard !additions.isEmpty, additions.count <= 104 else { throw AgendaOperationError.invalid("Indica da 1 a 104 copie.") }
        var staged = events
        for event in additions {
            guard !staged.contains(where: { $0.id == event.id }) else { throw AgendaOperationError.invalid("Identificatore duplicato.") }
            try validate(event, against: staged)
            staged.append(event)
        }
        events = staged
        for event in additions { scheduleNotification(for: event) }
    }
    func removeEvents(_ selected: [AgendaEvent]) throws {
        guard cacheHealthy else { throw AgendaOperationError.invalid("La cache locale richiede un ripristino nell'app.") }
        let ids = Set(selected.map(\.id))
        for event in selected { cancelNotification(id: event.id) }
        events.removeAll { ids.contains($0.id) }
    }
    func shifted(_ event: AgendaEvent, minutes: Int) throws -> AgendaEvent {
        let delta = try AgendaTime.slots(minutes, signed: true)
        let absoluteSlot = event.startSlot + 32 + delta
        let days = Int(floor(Double(absoluteSlot) / 96.0))
        let slot = absoluteSlot - days * 96 - 32
        let oldDay = try AgendaTime.day(event.dateKey)
        guard let newDay = Calendar.current.date(byAdding: .day, value: days, to: oldDay) else { throw AgendaOperationError.invalid("Data fuori intervallo.") }
        var result = event
        result.dateKey = AgendaTime.key(newDay)
        result.startSlot = slot
        return result
    }
    func copies(of event: AgendaEvent, firstStart: Date, count: Int, intervalDays: Int) throws -> [AgendaEvent] {
        guard (1...104).contains(count), (1...366).contains(intervalDays) else { throw AgendaOperationError.invalid("Da 1 a 104 copie, ogni 1–366 giorni.") }
        let startSlot = try AgendaTime.slot(firstStart)
        let firstDay = Calendar.current.startOfDay(for: firstStart)
        let series = count > 1 ? UUID() : nil
        return try (0..<count).map { index in
            guard let day = Calendar.current.date(byAdding: .day, value: index * intervalDays, to: firstDay) else { throw AgendaOperationError.invalid("Data fuori intervallo.") }
            var copy = event
            copy.id = UUID()
            copy.dateKey = AgendaTime.key(day)
            copy.startSlot = startSlot
            copy.seriesID = series
            copy.repeatWeeks = count > 1 && intervalDays == 7 ? count : nil
            return copy
        }
    }
    func nextFreeStart(after: Date, durationSlots: Int, fromHour: Int, toHour: Int, days: Int, excluding: UUID? = nil) throws -> Date {
        guard (1...96).contains(durationSlots), (0...23).contains(fromHour), (1...24).contains(toHour),
              fromHour < toHour, (1...366).contains(days) else { throw AgendaOperationError.invalid("Intervallo di ricerca non valido (1–366 giorni).") }
        let low = fromHour * 4 - 32, high = toHour * 4 - 32 - durationSlots
        guard high >= low else { throw AgendaOperationError.invalid("La durata supera la fascia oraria scelta.") }
        for offset in 0..<days {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: after)) else { continue }
            let key = AgendaTime.key(day)
            for slot in low...high {
                guard let candidate = try? AgendaTime.date(key: key, slot: slot), candidate >= after,
                      (try? AgendaTime.date(key: key, slot: slot + durationSlots)) != nil else { continue }
                if !events.contains(where: { $0.id != excluding && $0.dateKey == key && slot < $0.startSlot + $0.durationSlots && slot + durationSlots > $0.startSlot }) { return candidate }
            }
        }
        throw AgendaOperationError.invalid("Nessuno spazio libero nella fascia e nei giorni indicati.")
    }
}

// Small, deterministic Italian command grammar. No cloud parser or external dependencies.
enum AgendaVoiceCommand {
    case shift(String, Int)
    case resize(String, Int)
    case create(name: String, day: String, hour: Int, minute: Int, duration: Int, reminder: Int?, location: String?)

    static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
    static func minutes(_ input: String) throws -> Int {
        let text = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "un'ora", "un ora", "un’ora", "un'ora intera": return 60
        case "mezz'ora", "mezz ora", "mezz’ora", "mezzora": return 30
        case "un quarto d'ora", "un quarto d’ora", "un quarto dora": return 15
        default:
            if let groups = captures(#"^(\d+)\s*(minuti|minuto|ore|ora)?$"#, text), let n = Int(groups[0]), (0...525600).contains(n) {
                return groups[1].hasPrefix("or") ? n * 60 : n
            }
            throw AgendaOperationError.invalid("Indica i minuti in cifre, oppure un'ora, mezz'ora o un quarto d'ora.")
        }
    }
    static func parse(_ input: String) throws -> AgendaVoiceCommand {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "’", with: "'")
        for suffix in [" in Agenda a Blocchi", " con Agenda a Blocchi", " su Agenda a Blocchi"] {
            if text.lowercased().hasSuffix(suffix.lowercased()) { text = String(text.dropLast(suffix.count)) }
        }
        if let g = captures(#"^sposta\s+(.+?)\s+(avanti|indietro)\s+di\s+(.+)$"#, text) {
            let amount = try minutes(g[2]); _ = try AgendaTime.slots(amount, signed: true)
            guard amount > 0 else { throw AgendaOperationError.invalid("Indica uno spostamento positivo.") }
            return .shift(g[0], g[1].lowercased() == "indietro" ? -amount : amount)
        }
        if let g = captures(#"^(anticipa|posticipa|allunga|accorcia)\s+(.+?)\s+di\s+(.+)$"#, text) {
            let amount = try minutes(g[2]); _ = try AgendaTime.slots(amount, signed: true)
            guard amount > 0 else { throw AgendaOperationError.invalid("Indica un numero positivo di minuti.") }
            switch g[0].lowercased() {
            case "anticipa": return .shift(g[1], -amount)
            case "posticipa": return .shift(g[1], amount)
            case "accorcia": return .resize(g[1], -amount)
            default: return .resize(g[1], amount)
            }
        }
        if let g = captures(#"^(?:metti|aggiungi|pianifica)\s+(.+?)\s+(oggi|domani|dopodomani|\d{4}-\d{2}-\d{2})\s+alle\s+(\d{1,2})(?:[:.](\d{2}))?\s+per\s+(.+?)(?:\s+con promemoria\s+(\d+)\s+minuti prima)?(?:\s+(?:e|con) luogo\s+(.+))?$"#, text),
           let hour = Int(g[2]), let minute = Int(g[3].isEmpty ? "0" : g[3]), (0...23).contains(hour), (0...59).contains(minute) {
            let duration = try minutes(g[4]); _ = try AgendaTime.slots(duration)
            return .create(name: g[0], day: g[1].lowercased(), hour: hour, minute: minute, duration: duration, reminder: g[5].isEmpty ? nil : Int(g[5]), location: g[6].isEmpty ? nil : g[6])
        }
        throw AgendaOperationError.invalid("Prova: sposta Palestra avanti di 15 minuti; anticipa Studio di mezz'ora; allunga Lezione di 30 minuti; oppure metti Palestra domani alle 18 per un'ora con promemoria 15 minuti prima e luogo Eden Bibbiano. Per altre opzioni usa le azioni dedicate.")
    }
}
