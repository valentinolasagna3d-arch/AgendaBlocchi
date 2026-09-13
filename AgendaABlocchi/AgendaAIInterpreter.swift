import Foundation

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
@Generable(description: "Una singola azione da eseguire nell'app italiana Agenda a Blocchi")
enum AgendaAIAction {
    case createReusableBlock
    case scheduleReusableBlock
    case createEvent
    case shiftEvent
    case resizeEvent
    case moveEvent
    case setReminder
    case removeReminder
    case setLocation
    case removeLocation
    case dayAgenda
    case nextEvent
    case listBlocks
    case sync
    case unknown
}

@available(iOS 26.0, *)
@Generable(description: "Piano strutturato ricavato da una richiesta naturale dell'utente")
struct AgendaAIPlan {
    @Guide(description: "L'azione principale richiesta")
    var action: AgendaAIAction

    @Guide(description: "Nome del blocco o dell'impegno interessato, senza parole come evento, blocco o appuntamento")
    var subject: String?

    @Guide(description: "Data locale nel formato YYYY-MM-DD. Risolvi parole come oggi, domani, martedì usando la data corrente fornita nel prompt")
    var dateISO: String?

    @Guide(description: "Ora di inizio da 0 a 23, se presente")
    var startHour: Int?

    @Guide(description: "Minuti dell'ora di inizio: 0, 15, 30 o 45 quando possibile")
    var startMinute: Int?

    @Guide(description: "Ora di fine da 0 a 23, se presente")
    var endHour: Int?

    @Guide(description: "Minuti dell'ora di fine")
    var endMinute: Int?

    @Guide(description: "Durata richiesta in minuti, se esplicitata")
    var durationMinutes: Int?

    @Guide(description: "Spostamento temporale in minuti. Negativo per anticipare, positivo per posticipare")
    var shiftMinutes: Int?

    @Guide(description: "Variazione della durata in minuti. Negativo per accorciare, positivo per allungare")
    var resizeMinutes: Int?

    @Guide(description: "Minuti prima dell'evento per il promemoria")
    var reminderMinutes: Int?

    @Guide(description: "Luogo richiesto")
    var location: String?

    @Guide(description: "Nome semplice del colore, per esempio verde, azzurro, rosa, giallo, lilla, arancio, grigio o turchese")
    var color: String?

    @Guide(description: "Numero totale di settimane per una ripetizione settimanale")
    var repeatWeeks: Int?
}
#endif

@MainActor
enum AgendaAIInterpreter {
    static func execute(_ request: String, store: AgendaStore) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard model.isAvailable else { return nil }

            let blocks = store.templates
                .map { "\($0.name) (\(AgendaIntentBridge.durationText(slots: $0.durationSlots)))" }
                .joined(separator: ", ")

            let futureEvents = store.events
                .sorted(by: AgendaIntentBridge.eventSort)
                .prefix(40)
                .map { event in
                    "\(event.name) | \(event.dateKey) | \(AgendaIntentBridge.timeText(slot: event.startSlot))-\(AgendaIntentBridge.timeText(slot: event.startSlot + event.durationSlots))"
                }
                .joined(separator: "; ")

            let session = LanguageModelSession(instructions: """
                Sei il motore di comprensione di Agenda a Blocchi. Devi capire italiano naturale, sinonimi, frasi colloquiali e formulazioni non identiche agli esempi. Non inventare dati essenziali mancanti. Distingui sempre un BLOCCO RIUTILIZZABILE da un IMPEGNO PROGRAMMATO: creare un blocco non richiede una data o un'ora; programmare un blocco o creare un evento sì. Se l'utente dice 'spostalo', 'anticipalo', 'allungalo' ma non esiste un soggetto identificabile nel testo, usa unknown invece di inventare. Per richieste informative scegli dayAgenda, nextEvent o listBlocks. Non usare il Calendario Apple.
                """)

            do {
                let now = Date()
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "it_IT")
                formatter.dateFormat = "yyyy-MM-dd EEEE HH:mm"
                let prompt = """
                    Data e ora locali: \(formatter.string(from: now)).
                    Blocchi riutilizzabili esistenti: \(blocks.isEmpty ? "nessuno" : blocks).
                    Impegni esistenti: \(futureEvents.isEmpty ? "nessuno" : futureEvents).
                    Richiesta dell'utente: \(request)
                    Restituisci il piano strutturato più fedele possibile.
                    """
                let response = try await session.respond(to: prompt, generating: AgendaAIPlan.self)
                return try await execute(plan: response.content, originalRequest: request, store: store)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private static func execute(plan: AgendaAIPlan, originalRequest: String, store: AgendaStore) async throws -> String? {
        switch plan.action {
        case .createReusableBlock:
            guard let name = cleaned(plan.subject), !name.isEmpty else {
                return "Dimmi come vuoi chiamare il nuovo blocco preimpostato."
            }
            if AgendaIntentBridge.matchingTemplate(named: name, in: store) != nil {
                return "Esiste già un blocco chiamato \(name)."
            }
            let duration = try AgendaIntentBridge.slots(minutes: max(15, plan.durationMinutes ?? 60))
            let color = colorChoice(plan.color)?.hex ?? "#B8DFF5"
            store.addTemplate(
                name: name,
                durationSlots: duration,
                colorHex: color,
                repeatWeeks: positive(plan.repeatWeeks),
                reminderMinutes: nonnegative(plan.reminderMinutes),
                location: cleaned(plan.location)
            )
            await AgendaIntentBridge.finishMutation(store)
            var text = "Fatto. Ho creato il blocco preimpostato \(name), durata \(AgendaIntentBridge.durationText(slots: duration))"
            if let location = cleaned(plan.location) { text += ", luogo \(location)" }
            if let reminder = nonnegative(plan.reminderMinutes) { text += ", promemoria \(reminder) minuti prima" }
            return text + ". Non l'ho inserito nel calendario."

        case .scheduleReusableBlock:
            guard let name = cleaned(plan.subject), let template = fuzzyTemplate(named: name, store: store) else {
                return "Non trovo quel blocco preimpostato. Dimmi il nome di uno dei tuoi blocchi."
            }
            guard let start = makeDate(dateISO: plan.dateISO, hour: plan.startHour, minute: plan.startMinute) else {
                return "Ho capito che vuoi programmare \(template.name), ma mi servono giorno e ora."
            }
            let slot = try AgendaIntentBridge.slot(for: start)
            if let error = store.addEvent(template: template, dateKey: AgendaIntentBridge.dateKey(start), startSlot: slot) { return error }
            await AgendaIntentBridge.finishMutation(store)
            return "Fatto. Ho programmato \(template.name) \(AgendaIntentBridge.spokenDateTime(start))."

        case .createEvent:
            guard let name = cleaned(plan.subject) else { return "Dimmi il nome dell'impegno." }
            guard let start = makeDate(dateISO: plan.dateISO, hour: plan.startHour, minute: plan.startMinute) else {
                return "Ho capito che vuoi creare \(name), ma mi servono giorno e ora di inizio."
            }
            let durationSlots: Int
            if let end = makeDate(dateISO: plan.dateISO, hour: plan.endHour, minute: plan.endMinute), end > start {
                durationSlots = try AgendaIntentBridge.slots(from: start, to: end)
            } else {
                durationSlots = try AgendaIntentBridge.slots(minutes: max(15, plan.durationMinutes ?? 60))
            }
            let created = try AgendaIntentBridge.addCustomEvent(
                to: store,
                name: name,
                start: start,
                durationSlots: durationSlots,
                repeatWeeks: positive(plan.repeatWeeks),
                reminderMinutes: nonnegative(plan.reminderMinutes),
                location: cleaned(plan.location)
            )
            await AgendaIntentBridge.finishMutation(store)
            return "Fatto. Ho aggiunto \(created.name) \(AgendaIntentBridge.spokenDateTime(start)), durata \(AgendaIntentBridge.durationText(slots: durationSlots))."

        case .shiftEvent:
            guard let event = fuzzyEvent(named: plan.subject, store: store) else { return "Non riesco a capire quale impegno vuoi spostare." }
            guard let minutes = plan.shiftMinutes, minutes != 0 else { return "Dimmi di quanto vuoi anticipare o posticipare l'impegno." }
            let shifted = try AgendaIntentBridge.dateByShifting(event, minutes: minutes)
            let slot = try AgendaIntentBridge.slot(for: shifted)
            if let error = store.moveEvent(id: event.id, toDateKey: AgendaIntentBridge.dateKey(shifted), startSlot: slot) { return error }
            await AgendaIntentBridge.finishMutation(store)
            let verb = minutes > 0 ? "posticipato" : "anticipato"
            return "Fatto. Ho \(verb) \(event.name) di \(abs(minutes)) minuti. Ora inizia alle \(AgendaIntentBridge.timeText(slot: slot))."

        case .resizeEvent:
            guard let event = fuzzyEvent(named: plan.subject, store: store) else { return "Non riesco a capire quale impegno vuoi modificare." }
            guard let delta = plan.resizeMinutes, delta != 0 else { return "Dimmi di quanto vuoi allungare o accorciare l'impegno." }
            var updated = event
            let deltaSlots = try AgendaIntentBridge.slots(minutes: abs(delta))
            updated.durationSlots += delta > 0 ? deltaSlots : -deltaSlots
            guard updated.durationSlots >= 1 else { return "La durata minima è 15 minuti." }
            if let error = store.updateEvent(updated) { return error }
            await AgendaIntentBridge.finishMutation(store)
            return "Fatto. \(updated.name) ora dura \(AgendaIntentBridge.durationText(slots: updated.durationSlots))."

        case .moveEvent:
            guard let event = fuzzyEvent(named: plan.subject, store: store) else { return "Non riesco a capire quale impegno vuoi spostare." }
            guard let newStart = makeDate(dateISO: plan.dateISO, hour: plan.startHour, minute: plan.startMinute) else {
                return "Dimmi il nuovo giorno e l'orario per \(event.name)."
            }
            let slot = try AgendaIntentBridge.slot(for: newStart)
            if let error = store.moveEvent(id: event.id, toDateKey: AgendaIntentBridge.dateKey(newStart), startSlot: slot) { return error }
            await AgendaIntentBridge.finishMutation(store)
            return "Fatto. Ho spostato \(event.name) a \(AgendaIntentBridge.spokenDateTime(newStart))."

        case .setReminder:
            guard let event = fuzzyEvent(named: plan.subject, store: store) else { return "Non riesco a capire a quale impegno vuoi aggiungere il promemoria." }
            guard let minutes = nonnegative(plan.reminderMinutes) else { return "Dimmi quanti minuti prima vuoi il promemoria." }
            var updated = event; updated.reminderMinutes = minutes
            if let error = store.updateEvent(updated) { return error }
            await AgendaIntentBridge.finishMutation(store)
            return "Fatto. Ti ricorderò \(event.name) \(minutes) minuti prima."

        case .removeReminder:
            guard let event = fuzzyEvent(named: plan.subject, store: store) else { return "Non riesco a capire da quale impegno vuoi togliere il promemoria." }
            var updated = event; updated.reminderMinutes = nil
            if let error = store.updateEvent(updated) { return error }
            await AgendaIntentBridge.finishMutation(store)
            return "Fatto. Ho rimosso il promemoria da \(event.name)."

        case .setLocation:
            guard let event = fuzzyEvent(named: plan.subject, store: store) else { return "Non riesco a capire quale impegno vuoi modificare." }
            guard let location = cleaned(plan.location) else { return "Dimmi il luogo da impostare." }
            var updated = event; updated.location = location
            if let error = store.updateEvent(updated) { return error }
            await AgendaIntentBridge.finishMutation(store)
            return "Fatto. Il luogo di \(event.name) è \(location)."

        case .removeLocation:
            guard let event = fuzzyEvent(named: plan.subject, store: store) else { return "Non riesco a capire quale impegno vuoi modificare." }
            var updated = event; updated.location = nil
            if let error = store.updateEvent(updated) { return error }
            await AgendaIntentBridge.finishMutation(store)
            return "Fatto. Ho rimosso il luogo da \(event.name)."

        case .dayAgenda:
            let date = dateFromISO(plan.dateISO) ?? Date()
            return AgendaIntentBridge.daySummary(store, date: date)

        case .nextEvent:
            let now = Date()
            let next = store.events.compactMap { event -> (AgendaEvent, Date)? in
                guard let date = AgendaIntentBridge.eventDate(event), date >= now else { return nil }
                return (event, date)
            }.min { $0.1 < $1.1 }
            return next.map { "Il prossimo impegno è \($0.0.name), \(AgendaIntentBridge.spokenDateTime($0.1))." } ?? "Non risultano impegni futuri."

        case .listBlocks:
            return store.templates.isEmpty
                ? "Non hai ancora blocchi preimpostati."
                : "I tuoi blocchi sono: " + store.templates.map { "\($0.name), \(AgendaIntentBridge.durationText(slots: $0.durationSlots))" }.joined(separator: "; ") + "."

        case .sync:
            await store.synchronize()
            AgendaIntentBridge.notifyMutation()
            return store.syncError.map { "Sincronizzazione non completata: \($0)" } ?? store.syncStatus

        case .unknown:
            return nil
        }
    }
    #endif

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func colorChoice(_ name: String?) -> AgendaColorChoice? {
        guard let name else { return nil }
        let n = AgendaIntentBridge.normalized(name)
        if n.contains("verde") { return .verde }
        if n.contains("rosa") { return .rosa }
        if n.contains("giall") { return .giallo }
        if n.contains("lilla") || n.contains("viola") { return .lilla }
        if n.contains("aranc") { return .arancio }
        if n.contains("grigi") { return .grigio }
        if n.contains("turch") { return .turchese }
        if n.contains("azzurr") || n.contains("blu") { return .azzurro }
        return nil
    }

    private static func fuzzyTemplate(named name: String, store: AgendaStore) -> BlockTemplate? {
        if let exact = AgendaIntentBridge.matchingTemplate(named: name, in: store) { return exact }
        let needle = AgendaIntentBridge.normalized(name)
        return store.templates.first {
            let candidate = AgendaIntentBridge.normalized($0.name)
            return candidate.contains(needle) || needle.contains(candidate)
        }
    }

    private static func fuzzyEvent(named name: String?, store: AgendaStore) -> AgendaEvent? {
        guard let name = cleaned(name) else { return nil }
        return AgendaIntentBridge.event(named: name, in: store)
    }

    private static func dateFromISO(_ value: String?) -> Date? {
        guard let value = cleaned(value) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func makeDate(dateISO: String?, hour: Int?, minute: Int?) -> Date? {
        guard let day = dateFromISO(dateISO), let hour, (0...23).contains(hour) else { return nil }
        let minute = min(59, max(0, minute ?? 0))
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
}
