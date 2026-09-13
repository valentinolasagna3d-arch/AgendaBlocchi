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
                seriesID: series
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
    }

    private func cancelNotification(id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id.uuidString])
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
