import Foundation
import SwiftUI
import Security

struct AgendaPayload: Codable, Equatable {
    var schemaVersion = 1
    var templates: [BlockTemplate]
    var events: [AgendaEvent]

    func validated() throws -> Self {
        guard schemaVersion == 1,
              Set(templates.map(\.id)).count == templates.count,
              Set(events.map(\.id)).count == events.count else {
            throw SyncFailure.message("Formato agenda non supportato. I dati locali sono conservati.")
        }
        return self
    }
}

struct AgendaBackup: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var reason: String
    var payload: AgendaPayload
}

struct AgendaCache: Codable {
    var payload: AgendaPayload
    var revision: Date
    var ownerID: UUID?
    var migrated: Bool
    var hasLegacyData: Bool
    var dirty: Bool
    var backups: [AgendaBackup]
}

struct AgendaSession: Codable {
    struct User: Codable { var id: UUID; var email: String? }
    var access_token: String
    var refresh_token: String
    var expires_at: Double?
    var expires_in: Double?
    var user: User
}

struct AgendaRow: Codable {
    var user_id: UUID
    var payload: AgendaPayload
    var updated_at: String
}

enum SyncFailure: Error, LocalizedError {
    case message(String)
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .http(400): return "Richiesta non valida o credenziali errate. Verifica email e password."
        case .http(401): return "Sessione scaduta. Accedi nuovamente; i dati locali sono conservati."
        case .http(403): return "Accesso negato. Verifica account e regole RLS su agenda_state."
        case .http(429): return "Troppe richieste. Riprova tra poco."
        case .http(let code): return "Servizio non disponibile (\(code)). I dati restano sul dispositivo."
        }
    }
}

enum AgendaKeychain {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "it.agendaablocchi.supabase.session",
         kSecAttrAccount as String: "current"]
    }
    static func read() throws -> AgendaSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SyncFailure.message("Portachiavi non disponibile. Sblocca il dispositivo e riprova.")
        }
        return try JSONDecoder().decode(AgendaSession.self, from: data)
    }
    static func write(_ session: AgendaSession) throws {
        let data = try JSONEncoder().encode(session)
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            values.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else {
                throw SyncFailure.message("Impossibile salvare la sessione nel Portachiavi.")
            }
        } else if status != errSecSuccess {
            throw SyncFailure.message("Impossibile aggiornare la sessione nel Portachiavi.")
        }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SyncFailure.message("Impossibile rimuovere la sessione dal Portachiavi.")
        }
    }
}

@MainActor
enum AgendaAPI {
    // Injectable transport lets the CI exercise the actual sync engine without an account.
    static var transport: @MainActor (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }
    static let baseURL = "https://byuhxiyqvplxgwtrsgwz.supabase.co"
    static let publishableKey = "sb_publishable_ZVVDImhVukoLymc154OEIg_vPs_7Tqt"

    static func request(_ path: String, method: String = "GET", token: String? = nil,
                        query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var components = URLComponents(string: baseURL + path)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if path.hasPrefix("/rest/") {
            request.setValue("public", forHTTPHeaderField: "Accept-Profile")
            request.setValue("public", forHTTPHeaderField: "Content-Profile")
            request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        }
        request.httpBody = body
        let (data, response) = try await transport(request)
        guard let http = response as? HTTPURLResponse else { throw SyncFailure.http(503) }
        guard (200..<300).contains(http.statusCode) else { throw SyncFailure.http(http.statusCode) }
        return data
    }

    static func authenticate(grant: String, values: [String: String]) async throws -> AgendaSession {
        let data = try await request("/auth/v1/token", method: "POST",
            query: [URLQueryItem(name: "grant_type", value: grant)],
            body: JSONEncoder().encode(values))
        var session = try JSONDecoder().decode(AgendaSession.self, from: data)
        if session.expires_at == nil {
            session.expires_at = Date().timeIntervalSince1970 + (session.expires_in ?? 3600)
        }
        return session
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value) else {
            throw SyncFailure.message("Data di sincronizzazione non valida. Nessun dato locale sostituito.")
        }
        return date
    }
}

extension AgendaStore {
    var snapshot: AgendaPayload { AgendaPayload(templates: templates, events: events) }

    func restoreSyncCache() {
        hasLegacyData = defaults.data(forKey: "agenda.templates.v1") != nil ||
            defaults.data(forKey: "agenda.events.v1") != nil
        if let data = defaults.data(forKey: cacheKey) {
            do {
                let cache = try JSONDecoder().decode(AgendaCache.self, from: data)
                _ = try cache.payload.validated()
                applySnapshot(cache.payload)
                localRevision = cache.revision
                ownerID = cache.ownerID
                migrated = cache.migrated
                hasLegacyData = cache.hasLegacyData
                dirty = cache.dirty
                backups = cache.backups
            } catch {
                // Never replace a damaged cache with a possibly stale legacy snapshot.
                cacheHealthy = false
                syncError = "Cache sync illeggibile: sincronizzazione sospesa. Esporta i dati locali prima di reinstallare."
                syncStatus = "Cache da verificare"
            }
        }
        do {
            session = try loadSession()
            signedInEmail = session?.user.email
        } catch { syncError = error.localizedDescription }
    }

    func persistSyncCache() {
        guard cacheHealthy else { return }
        let cache = AgendaCache(payload: snapshot, revision: localRevision, ownerID: ownerID,
            migrated: migrated, hasLegacyData: hasLegacyData, dirty: dirty, backups: backups)
        do {
            defaults.set(try JSONEncoder().encode(cache), forKey: cacheKey)
        } catch {
            syncError = "Salvataggio locale non riuscito. Mantieni aperta l’app e riprova."
        }
    }

    func archiveSnapshot(_ payload: AgendaPayload, reason: String) {
        // Keep every displaced version; the user can export or restore it from the sync sheet.
        if backups.last?.payload != payload {
            backups.append(AgendaBackup(reason: reason, payload: payload))
        }
    }

    func recordLocalChange() {
        guard cacheHealthy else { return }
        // Millisecond precision matches the wire representation. Monotonic on this device.
        localRevision = Date(timeIntervalSince1970:
            max(floor(Date().timeIntervalSince1970 * 1000),
                (localRevision.timeIntervalSince1970 * 1000).rounded() + 1) / 1000)
        hasLegacyData = true
        dirty = true
        persistSyncCache()
        syncStatus = session == nil ? "Salvato sul dispositivo" : "Modifiche da sincronizzare"
        Task { await synchronize() }
    }

    func signIn(email: String, password: String) async {
        guard !syncBusy, cacheHealthy else { return }
        syncBusy = true
        syncError = nil
        defer { syncBusy = false }
        do {
            let newSession = try await AgendaAPI.authenticate(grant: "password",
                values: ["email": email.trimmingCharacters(in: .whitespacesAndNewlines), "password": password])
            // Prevent accidental upload of one account's private cache to another account.
            if let ownerID, ownerID != newSession.user.id {
                throw SyncFailure.message("Questa agenda locale appartiene a un altro account. Accedi con l’account originale.")
            }
            try saveSession(newSession)
            session = newSession
            needsReauthentication = false
            signedInEmail = newSession.user.email ?? email
            ownerID = newSession.user.id
            persistSyncCache()
            syncStatus = "Accesso effettuato"
            Task { await synchronize() }
        } catch { syncError = error.localizedDescription }
    }

    func signOut() {
        guard !syncBusy else { return }
        do {
            try deleteSession()
            session = nil
            needsReauthentication = false
            signedInEmail = nil
            needsMigrationChoice = false
            syncError = nil
            syncStatus = "Disconnesso · dati conservati sul dispositivo"
        } catch { syncError = error.localizedDescription }
    }

    func validSession() async throws -> AgendaSession {
        // Retry a temporarily locked Keychain on foreground/retry.
        if session == nil { session = try loadSession() }
        guard var current = session else { throw SyncFailure.http(401) }
        guard ownerID == nil || ownerID == current.user.id else {
            throw SyncFailure.message("Account diverso da quello dell’agenda locale.")
        }
        if (current.expires_at ?? 0) < Date().timeIntervalSince1970 + 90 {
            do {
                current = try await AgendaAPI.authenticate(grant: "refresh_token",
                    values: ["refresh_token": current.refresh_token])
            } catch {
                if case SyncFailure.http(let code) = error, code == 400 || code == 401 || code == 403 {
                    needsReauthentication = true
                    throw SyncFailure.message("Sessione non più valida. Accedi di nuovo qui sotto; i dati locali sono conservati.")
                }
                throw error
            }
            // Retain the rotated token in memory even if Keychain is temporarily unavailable.
            session = current
        }
        // Also retries persistence after a previous temporary Keychain failure.
        try saveSession(current)
        signedInEmail = current.user.email
        return current
    }

    func synchronize() async {
        guard cacheHealthy, !needsReauthentication else { return }
        if syncBusy { syncAgain = true; return }
        if needsMigrationChoice { return }
        if session == nil {
            do { session = try loadSession() }
            catch { syncError = error.localizedDescription; return }
        }
        guard session != nil else { return }
        syncBusy = true
        syncAgain = false
        syncError = nil
        syncStatus = "Sincronizzazione…"
        defer {
            syncBusy = false
            if syncAgain {
                syncAgain = false
                Task { await synchronize() }
            }
        }
        do {
            let current = try await validSession()
            ownerID = current.user.id
            let filter = [URLQueryItem(name: "user_id", value: "eq." + current.user.id.uuidString)]
            // Conditional PATCH is a compare-and-swap: a concurrent writer forces a fresh read.
            for _ in 0..<4 {
                try Task.checkCancellation()
                let data = try await AgendaAPI.request("/rest/v1/agenda_state", token: current.access_token,
                    query: filter + [URLQueryItem(name: "select", value: "user_id,payload,updated_at")])
                let rows = try JSONDecoder().decode([AgendaRow].self, from: data)
                guard rows.count <= 1 else { throw SyncFailure.message("Risposta agenda inattesa.") }
                let remote = rows.first
                if let remote {
                    guard remote.user_id == current.user.id else { throw SyncFailure.http(403) }
                    _ = try remote.payload.validated()
                    let remoteDate = try AgendaAPI.date(remote.updated_at)
                    if !migrated && hasLegacyData && snapshot != remote.payload {
                        needsMigrationChoice = true
                        syncStatus = "Scegli i dati da usare al primo accesso"
                        persistSyncCache()
                        return
                    }
                    if (!migrated && !hasLegacyData) || remoteDate > localRevision ||
                        (remoteDate == localRevision && snapshot != remote.payload) {
                        if snapshot != remote.payload {
                            archiveSnapshot(snapshot, reason: "Prima di scaricare una versione online")
                            applySnapshot(remote.payload)
                        }
                        localRevision = remoteDate
                        dirty = false
                        migrated = true
                        persistSyncCache()
                        syncStatus = "Sincronizzato"
                        return
                    }
                    if snapshot == remote.payload {
                        localRevision = max(localRevision, remoteDate)
                        dirty = false
                        migrated = true
                        persistSyncCache()
                        syncStatus = "Sincronizzato"
                        return
                    }
                    // Preserve the remote version before replacing it in an LWW conflict.
                    archiveSnapshot(remote.payload, reason: "Versione online precedente al caricamento")
                    persistSyncCache()
                }
                if !migrated {
                    archiveSnapshot(snapshot, reason: "Migrazione iniziale v5.3")
                    localRevision = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 * 1000) / 1000)
                    dirty = true
                    persistSyncCache()
                }
                let sentRevision = localRevision
                let sentPayload = snapshot
                let row = AgendaRow(user_id: current.user.id, payload: sentPayload,
                    updated_at: AgendaAPI.timestamp(sentRevision))
                var query = filter
                if let remote {
                    query.append(URLQueryItem(name: "updated_at", value: "eq." + remote.updated_at))
                }
                let result: Data
                do {
                    result = try await AgendaAPI.request("/rest/v1/agenda_state",
                        method: remote == nil ? "POST" : "PATCH", token: current.access_token,
                        query: remote == nil ? [] : query, body: JSONEncoder().encode(row))
                } catch SyncFailure.http(409) { continue }
                let written = try JSONDecoder().decode([AgendaRow].self, from: result)
                guard let accepted = written.first else { continue }
                guard accepted.user_id == current.user.id, accepted.payload == sentPayload else {
                    throw SyncFailure.message("Conferma del salvataggio inattesa. Riprova la sincronizzazione.")
                }
                migrated = true
                if localRevision == sentRevision && snapshot == sentPayload {
                    localRevision = try AgendaAPI.date(accepted.updated_at)
                    dirty = false
                    persistSyncCache()
                    syncStatus = "Sincronizzato"
                    return
                }
                persistSyncCache() // Edits made while awaiting the upload remain pending.
            }
            syncStatus = "Modifiche concorrenti · riprovo tra poco"
        } catch is CancellationError {
            syncStatus = "Salvato sul dispositivo"
        } catch {
            if case SyncFailure.http(401) = error {
                session?.expires_at = 0 // Try refresh on the next foreground/poll.
            }
            syncError = (error as? URLError) != nil
                ? "Connessione non disponibile. L’agenda resta utilizzabile; riprovo automaticamente."
                : error.localizedDescription
            syncStatus = "Salvato sul dispositivo · sync in attesa"
            // Avoid an immediate failure loop; the next poll or edit will retry.
            syncAgain = false
        }
    }

    func resolveMigration(useLocal: Bool) async {
        guard !syncBusy, needsMigrationChoice else { return }
        archiveSnapshot(snapshot, reason: "Dati v5.3 prima della scelta iniziale")
        if useLocal {
            migrated = true
            recordLocalChange()
        } else {
            // The next read chooses the latest remote row, not a stale sheet snapshot.
            hasLegacyData = false
        }
        needsMigrationChoice = false
        persistSyncCache()
        await synchronize()
    }

    func restoreBackup(_ backup: AgendaBackup) {
        guard !syncBusy, cacheHealthy else { return }
        archiveSnapshot(snapshot, reason: "Prima del ripristino di una copia")
        applySnapshot(backup.payload)
        recordLocalChange()
    }

    func exportData() throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let cache = AgendaCache(payload: snapshot, revision: localRevision, ownerID: ownerID,
            migrated: migrated, hasLegacyData: hasLegacyData, dirty: dirty, backups: backups)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgendaABlocchi-backup.json")
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try encoder.encode(cache).write(to: url, options: options)
        return url
    }
}

#if !SYNC_TESTING
struct AgendaSyncView: View {
    @ObservedObject var store: AgendaStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var exportURL: URL?
    @State private var backupToRestore: AgendaBackup?
    @State private var confirmLogout = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Sincronizzazione") {
                    Label(store.syncStatus, systemImage: "icloud")
                    if store.syncBusy { ProgressView() }
                    if let error = store.syncError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    Text("Agenda a Blocchi 5.4 Sync · iPhone e iPad")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let account = store.signedInEmail {
                    Section("Account") {
                        Text(account)
                        Button("Sincronizza ora") { Task { await store.synchronize() } }
                            .disabled(store.syncBusy || store.needsMigrationChoice)
                        Button("Esci dall’account", role: .destructive) { confirmLogout = true }
                            .disabled(store.syncBusy)
                    }
                }
                if store.signedInEmail == nil || store.needsReauthentication {
                    Section("Accedi con lo stesso account sui due dispositivi") {
                        TextField("Email", text: $email)
                            .textContentType(.username).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password).textContentType(.password)
                        Button("Accedi") {
                            Task {
                                let submittedPassword = password
                                password = ""
                                await store.signIn(email: email, password: submittedPassword)
                            }
                        }.disabled(store.syncBusy || email.isEmpty || password.isEmpty)
                        Text("Puoi chiudere questa finestra e continuare a usare l’agenda offline. La password non viene salvata.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if store.needsMigrationChoice {
                    Section("Primo accesso: ci sono due agende diverse") {
                        Text("Scegli lo stato completo da usare. La versione sostituita viene conservata nelle copie recuperabili. Non vengono uniti i singoli eventi.")
                        Button("Usa l’agenda di questo dispositivo") {
                            Task { await store.resolveMigration(useLocal: true) }
                        }
                        Button("Usa l’agenda già online") {
                            Task { await store.resolveMigration(useLocal: false) }
                        }
                    }.disabled(store.syncBusy)
                }
                Section("Copie recuperabili") {
                    Button("Prepara esportazione dati e copie") {
                        do { exportURL = try store.exportData() }
                        catch { store.syncError = error.localizedDescription }
                    }
                    if let exportURL { ShareLink("Condividi backup JSON", item: exportURL) }
                    ForEach(store.backups.reversed()) { backup in
                        Button {
                            backupToRestore = backup
                        } label: {
                            VStack(alignment: .leading) {
                                Text(backup.reason)
                                Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("\(backup.payload.templates.count) blocchi · \(backup.payload.events.count) impegni")
                                    .font(.caption)
                            }
                        }.disabled(store.syncBusy)
                    }
                }
                Section {
                    Text("Dopo il primo accesso prevale la modifica più recente dell’intera agenda. Due modifiche offline non vengono unite: la versione sostituita resta nelle copie. Tieni data e ora automatiche su entrambi i dispositivi. L’app controlla gli aggiornamenti ogni 20 secondi mentre è aperta e quando torna in primo piano.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sync")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .confirmationDialog("Ripristinare questa copia? Diventerà una nuova modifica da sincronizzare.",
                isPresented: Binding(get: { backupToRestore != nil }, set: { if !$0 { backupToRestore = nil } })) {
                if let backup = backupToRestore {
                    Button("Ripristina copia") { store.restoreBackup(backup); backupToRestore = nil }
                }
                Button("Annulla", role: .cancel) { backupToRestore = nil }
            }
            .confirmationDialog("Uscire? I dati e le modifiche non sincronizzate restano su questo dispositivo. Per sincronizzarli dovrai accedere allo stesso account.",
                isPresented: $confirmLogout) {
                Button("Esci", role: .destructive) { store.signOut() }
                Button("Annulla", role: .cancel) { }
            }
        }
    }
}

#endif
