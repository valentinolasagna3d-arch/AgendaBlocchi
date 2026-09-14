import Foundation
import AppIntents

// Calendar App Schema integration for the iOS/iPadOS 27 Siri stack.
// The normal build keeps its iOS 17 deployment target. The dedicated Xcode 27
// workflow always enables CALENDAR_SCHEMA_BETA and builds the Calendar schema.
#if CALENDAR_SCHEMA_BETA

@available(iOS 27.0, *)
@AppEnum(schema: .calendar.eventStatus)
enum AgendaCalendarEventStatus: String {
    case confirmed
    case tentative
    case cancelled

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .confirmed: "Confermato",
        .tentative: "Provvisorio",
        .cancelled: "Annullato"
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .calendar.eventSpan)
enum AgendaCalendarEventSpan: String {
    case this
    case future
    case all

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .this: "Solo questo",
        .future: "Questo e i successivi",
        .all: "Tutti"
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .calendar.attendeeStatus)
enum AgendaCalendarAttendeeStatus: String {
    case accepted
    case declined
    case tentative

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .accepted: "Accettato",
        .declined: "Rifiutato",
        .tentative: "Forse"
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .calendar.attendeeType)
enum AgendaCalendarAttendeeType: String {
    case person

    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .person: "Persona"
    ]
}

// The Calendar schema accepts union values for locations and alarms. Keeping
// these app-owned unions small lets Agenda a Blocchi map its current text-only
// location/reminder model without changing persisted data.
@available(iOS 27.0, *)
@UnionValue
enum AgendaCalendarEventLocation {
    case text(String)

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Luogo evento" }
    static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = [
        .text: "Luogo"
    ]
}

@available(iOS 27.0, *)
@UnionValue
enum AgendaCalendarEventAlarm {
    case duration(Duration)
    case date(Date)

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Promemoria evento" }
    static let caseDisplayRepresentations: [Cases: DisplayRepresentation] = [
        .duration: "Prima dell'evento",
        .date: "Data e ora"
    ]
}

@available(iOS 27.0, *)
@AppEntity(schema: .calendar.calendar)
struct AgendaCalendarEntity {
    static let defaultQuery = AgendaCalendarEntityQuery()

    let id: UUID
    var title: String

    // As in Apple's CometCal sample, assign through the schema-generated
    // properties in an explicit initializer, not the wrapper memberwise init.
    init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", image: .init(systemName: "calendar"))
    }
}

@available(iOS 27.0, *)
struct AgendaCalendarEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    typealias Entity = AgendaCalendarEntity

    private static let agendaID = UUID(uuidString: "61A6DAD7-26AD-4A7F-B10C-AB10C0000001")!

    func entities(for identifiers: [AgendaCalendarEntity.ID]) async throws -> [AgendaCalendarEntity] {
        identifiers.contains(Self.agendaID)
            ? [AgendaCalendarEntity(id: Self.agendaID, title: "Agenda a Blocchi")]
            : []
    }

    func entities(matching string: String) async throws -> [AgendaCalendarEntity] {
        let value = string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        if value.isEmpty || "agenda a blocchi".contains(value) || value.contains("agenda") {
            return [AgendaCalendarEntity(id: Self.agendaID, title: "Agenda a Blocchi")]
        }
        return []
    }

    func allEntities() async throws -> [AgendaCalendarEntity] {
        [AgendaCalendarEntity(id: Self.agendaID, title: "Agenda a Blocchi")]
    }

    func suggestedEntities() async throws -> [AgendaCalendarEntity] {
        try await allEntities()
    }

    static var defaultEntity: AgendaCalendarEntity {
        AgendaCalendarEntity(id: agendaID, title: "Agenda a Blocchi")
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .calendar.attendee)
struct AgendaCalendarAttendeeEntity: TransientAppEntity {
    // Attendees are values carried by an event, not independently stored records.
    // Match Apple's CometCal model so schema intents can resolve these parameters.
    var person: IntentPerson
    var status: AgendaCalendarAttendeeStatus?
    var isAttendanceOptional: Bool
    var type: AgendaCalendarAttendeeType?

    init(person: IntentPerson, status: AgendaCalendarAttendeeStatus?,
         isAttendanceOptional: Bool, type: AgendaCalendarAttendeeType?) {
        self.person = person
        self.status = status
        self.isAttendanceOptional = isAttendanceOptional
        self.type = type
    }

    init() {}

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Partecipante")
    }
}

@available(iOS 27.0, *)
@AppEntity(schema: .calendar.event)
struct AgendaCalendarEventEntity {
    static let defaultQuery = AgendaCalendarEventQuery()

    let id: UUID
    var calendar: AgendaCalendarEntity
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var recurrence: Calendar.RecurrenceRule?
    var note: AttributedString?
    var travelTime: Duration?
    var location: AgendaCalendarEventLocation?
    var virtualLocation: URL?
    var status: AgendaCalendarEventStatus?
    var alarms: [AgendaCalendarEventAlarm]
    var organizers: [IntentPerson]
    var attendees: [AgendaCalendarAttendeeEntity]

    init(
        id: UUID,
        calendar: AgendaCalendarEntity,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        recurrence: Calendar.RecurrenceRule?,
        note: AttributedString?,
        travelTime: Duration?,
        location: AgendaCalendarEventLocation?,
        virtualLocation: URL?,
        status: AgendaCalendarEventStatus?,
        alarms: [AgendaCalendarEventAlarm],
        organizers: [IntentPerson],
        attendees: [AgendaCalendarAttendeeEntity]
    ) {
        self.id = id
        self.calendar = calendar
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.recurrence = recurrence
        self.note = note
        self.travelTime = travelTime
        self.location = location
        self.virtualLocation = virtualLocation
        self.status = status
        self.alarms = alarms
        self.organizers = organizers
        self.attendees = attendees
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(startDate.formatted(date: .abbreviated, time: .shortened))",
            image: .init(systemName: "calendar.badge.clock")
        )
    }
}

@available(iOS 27.0, *)
@MainActor
struct AgendaCalendarEventQuery: EntityStringQuery, EnumerableEntityQuery {
    typealias Entity = AgendaCalendarEventEntity

    // EntityQuery.init() and AppEntity.defaultQuery are nonisolated.
    // Construction is stateless; only the query methods access the main-actor store.
    nonisolated init() {}

    func entities(for identifiers: [AgendaCalendarEventEntity.ID]) async throws -> [AgendaCalendarEventEntity] {
        let ids = Set(identifiers)
        return AgendaStore().events
            .filter { ids.contains($0.id) }
            .compactMap(AgendaCalendarSchemaBridge.entity)
    }

    func entities(matching string: String) async throws -> [AgendaCalendarEventEntity] {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgendaStore().events
            .filter { value.isEmpty || $0.name.localizedCaseInsensitiveContains(value) }
            .sorted(by: AgendaIntentBridge.eventSort)
            .prefix(100)
            .compactMap(AgendaCalendarSchemaBridge.entity)
    }

    func suggestedEntities() async throws -> [AgendaCalendarEventEntity] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? .distantPast
        return AgendaStore().events
            .filter { (AgendaIntentBridge.eventDate($0) ?? .distantPast) >= cutoff }
            .sorted(by: AgendaIntentBridge.eventSort)
            .prefix(100)
            .compactMap(AgendaCalendarSchemaBridge.entity)
    }

    func allEntities() async throws -> [AgendaCalendarEventEntity] {
        AgendaStore().events
            .sorted(by: AgendaIntentBridge.eventSort)
            .compactMap(AgendaCalendarSchemaBridge.entity)
    }
}

@available(iOS 27.0, *)
@MainActor
enum AgendaCalendarSchemaBridge {
    static func locationText(_ location: AgendaCalendarEventLocation?) -> String? {
        guard let location else { return nil }
        switch location {
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func entity(_ event: AgendaEvent) -> AgendaCalendarEventEntity? {
        guard let start = AgendaIntentBridge.eventDate(event) else { return nil }
        let end = start.addingTimeInterval(TimeInterval(event.durationSlots * 15 * 60))
        return AgendaCalendarEventEntity(
            id: event.id,
            calendar: AgendaCalendarEntityQuery.defaultEntity,
            title: event.name,
            startDate: start,
            endDate: end,
            isAllDay: false,
            recurrence: nil,
            note: nil,
            travelTime: nil,
            location: event.location.map { AgendaCalendarEventLocation.text($0) },
            virtualLocation: nil,
            status: .confirmed,
            alarms: event.reminderMinutes.map { minutes in
                [AgendaCalendarEventAlarm.date(start.addingTimeInterval(-Double(minutes) * 60))]
            } ?? [],
            organizers: [],
            attendees: []
        )
    }

    static func event(id: UUID, in store: AgendaStore) throws -> AgendaEvent {
        guard let event = store.events.first(where: { $0.id == id }) else {
            throw AgendaIntentFailure.message("Non trovo più quell'impegno in Agenda a Blocchi.")
        }
        return event
    }

    static func durationSlots(start: Date, end: Date?) throws -> Int {
        guard let end else { return 4 }
        return try AgendaIntentBridge.slots(from: start, to: end)
    }

    static func create(
        in store: AgendaStore,
        title: String,
        startDate: Date,
        endDate: Date?,
        location: AgendaCalendarEventLocation?
    ) async throws -> AgendaCalendarEventEntity {
        let slots = try durationSlots(start: startDate, end: endDate)
        let event = try AgendaIntentBridge.addCustomEvent(
            to: store,
            name: title,
            start: startDate,
            durationSlots: slots,
            repeatWeeks: nil,
            reminderMinutes: nil,
            location: locationText(location)
        )
        await AgendaIntentBridge.finishMutation(store)
        guard let entity = entity(event) else {
            throw AgendaIntentFailure.message("Ho creato l'impegno, ma non riesco a restituirlo a Siri.")
        }
        return entity
    }

    static func update(
        in store: AgendaStore,
        originalID: UUID,
        title: String?,
        startDate: Date?,
        endDate: Date?,
        location: AgendaCalendarEventLocation?
    ) async throws -> AgendaCalendarEventEntity {
        var updated = try event(id: originalID, in: store)
        let oldStart = AgendaIntentBridge.eventDate(updated) ?? Date()
        let effectiveStart = startDate ?? oldStart

        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let startDate {
            updated.dateKey = AgendaIntentBridge.dateKey(startDate)
            updated.startSlot = try AgendaIntentBridge.slot(for: startDate)
        }
        if let endDate {
            updated.durationSlots = try AgendaIntentBridge.slots(from: effectiveStart, to: endDate)
        }
        if let location {
            updated.location = locationText(location)
        }

        if let error = store.updateEvent(updated) {
            throw AgendaIntentFailure.message(error)
        }
        await AgendaIntentBridge.finishMutation(store)
        guard let result = entity(updated) else {
            throw AgendaIntentFailure.message("Ho aggiornato l'impegno, ma non riesco a restituirlo a Siri.")
        }
        return result
    }

    static func delete(
        in store: AgendaStore,
        entity: AgendaCalendarEventEntity,
        span: AgendaCalendarEventSpan?
    ) async throws {
        let current = try event(id: entity.id, in: store)
        if let seriesID = current.seriesID, span == .all || span == .future {
            let currentDate = AgendaIntentBridge.eventDate(current) ?? .distantPast
            let targets = store.events.filter { candidate in
                guard candidate.seriesID == seriesID else { return false }
                if span == .all { return true }
                return (AgendaIntentBridge.eventDate(candidate) ?? .distantPast) >= currentDate
            }
            for event in targets { store.deleteEvent(event) }
        } else {
            store.deleteEvent(current)
        }
        await AgendaIntentBridge.finishMutation(store)
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .calendar.createEvent)
struct AgendaCalendarCreateEventIntent {
    var title: String
    var startDate: Date
    var endDate: Date?
    var location: AgendaCalendarEventLocation?
    var calendar: AgendaCalendarEntity
    var isAllDay: Bool
    var recurrence: Calendar.RecurrenceRule?
    var attendees: [AgendaCalendarAttendeeEntity]
    var note: AttributedString?

    @MainActor
    func perform() async throws -> some ReturnsValue<AgendaCalendarEventEntity> {
        let store = AgendaIntentBridge.makeStore()
        let result = try await AgendaCalendarSchemaBridge.create(
            in: store,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location
        )
        return .result(value: result)
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .calendar.updateEvent)
struct AgendaCalendarUpdateEventIntent {
    var event: AgendaCalendarEventEntity
    var title: String?
    var attendees: [AgendaCalendarAttendeeEntity]?
    var startDate: Date?
    var endDate: Date?
    var isAllDay: Bool?
    var calendar: AgendaCalendarEntity?
    var recurrence: Calendar.RecurrenceRule?
    var note: String?
    var location: AgendaCalendarEventLocation?
    var span: AgendaCalendarEventSpan?

    @MainActor
    func perform() async throws -> some ReturnsValue<AgendaCalendarEventEntity> {
        let store = AgendaIntentBridge.makeStore()
        let result = try await AgendaCalendarSchemaBridge.update(
            in: store,
            originalID: event.id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            location: location
        )
        return .result(value: result)
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .calendar.deleteEvent)
struct AgendaCalendarDeleteEventIntent {
    var entity: AgendaCalendarEventEntity
    var span: AgendaCalendarEventSpan?

    @MainActor
    func perform() async throws -> some IntentResult {
        let store = AgendaIntentBridge.makeStore()
        try await AgendaCalendarSchemaBridge.delete(in: store, entity: entity, span: span)
        return .result()
    }
}

#endif
