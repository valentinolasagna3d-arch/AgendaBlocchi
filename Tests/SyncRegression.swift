// Run on macOS with the command in .github/workflows. No real account or network is used.
import Foundation

@MainActor
final class MockAgendaServer {
    var row: AgendaRow?
    var offline = false
    var failRefresh = false
    var authCalls = 0
    var writes = 0
    var afterRead: (() -> Void)?
    var beforeWrite: (() -> Void)?
    let account: UUID
    init(account: UUID) { self.account = account }

    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        if offline { throw URLError(.notConnectedToInternet) }
        precondition(request.value(forHTTPHeaderField: "apikey") == AgendaAPI.publishableKey)
        func response(_ data: Data, status: Int = 200) -> (Data, URLResponse) {
            (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        if request.url!.path == "/auth/v1/token" {
            authCalls += 1
            if failRefresh { return response(Data(), status: 400) }
            let session = AgendaSession(access_token: "new-access", refresh_token: "rotated-refresh",
                expires_at: Date().timeIntervalSince1970 + 3600, user: .init(id: account, email: "test@example.invalid"))
            return response(try JSONEncoder().encode(session))
        }
        precondition(request.url!.path == "/rest/v1/agenda_state")
        precondition(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        if request.httpMethod == "GET" {
            precondition(query.contains { $0.name == "user_id" && $0.value == "eq." + account.uuidString })
            let data = try JSONEncoder().encode(row.map { [$0] } ?? [])
            let action = afterRead; afterRead = nil; action?()
            return response(data)
        }
        let incoming = try JSONDecoder().decode(AgendaRow.self, from: request.httpBody!)
        precondition(incoming.user_id == account)
        let action = beforeWrite; beforeWrite = nil; action?()
        if request.httpMethod == "POST", row != nil { return response(Data(), status: 409) }
        if request.httpMethod == "PATCH" {
            let expected = query.first { $0.name == "updated_at" }?.value
            guard let row, expected == "eq." + row.updated_at else { return response(Data("[]".utf8)) }
        }
        writes += 1
        row = incoming
        return response(try JSONEncoder().encode([incoming]))
    }
}

@main
struct SyncRegression {
    @MainActor
    static func main() async throws {
        let account = UUID()
        var suites: [String] = []
        func payload(_ name: String) -> AgendaPayload {
            AgendaPayload(templates: [BlockTemplate(id: UUID(), name: name, durationSlots: 4,
                colorHex: "#B8DFF5")], events: [])
        }
        func makeStore(legacy: AgendaPayload? = nil) throws -> AgendaStore {
            let suite = "AgendaSyncRegression." + UUID().uuidString
            suites.append(suite)
            let defaults = UserDefaults(suiteName: suite)!
            if let legacy {
                defaults.set(try JSONEncoder().encode(legacy.templates), forKey: "agenda.templates.v1")
                defaults.set(try JSONEncoder().encode(legacy.events), forKey: "agenda.events.v1")
            }
            let store = AgendaStore(defaults: defaults, loadSession: { nil })
            store.session = AgendaSession(access_token: "test-access", refresh_token: "test-refresh",
                expires_at: Date().timeIntervalSince1970 + 3600,
                user: .init(id: account, email: "test@example.invalid"))
            store.loadSession = { nil }
            store.saveSession = { _ in }
            store.deleteSession = { }
            return store
        }
        func row(_ payload: AgendaPayload, _ date: Double) -> AgendaRow {
            AgendaRow(user_id: account, payload: payload, updated_at: AgendaAPI.timestamp(Date(timeIntervalSince1970: date)))
        }
        func setLocal(_ store: AgendaStore, _ payload: AgendaPayload, _ date: Double) {
            store.applySnapshot(payload)
            store.localRevision = Date(timeIntervalSince1970: date)
            store.migrated = true
            store.dirty = true
            store.persistSyncCache()
        }
        func connect(_ server: MockAgendaServer) {
            AgendaAPI.transport = { request in try server.respond(request) }
        }
        defer {
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }


        // Authentication contract and diagnostic regression fixtures.
        AgendaAPI.transport = { request in
            precondition(request.url!.absoluteString == AgendaAPI.baseURL + "/auth/v1/token?grant_type=password")
            precondition(request.httpMethod == "POST")
            precondition(request.value(forHTTPHeaderField: "apikey") == AgendaAPI.publishableKey)
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            let values = try JSONDecoder().decode([String: String].self, from: request.httpBody!)
            precondition(values == ["email": "test@example.invalid", "password": "  p\"à\\ss  "])
            let body = """
            {"access_token":"access","refresh_token":"refresh","expires_in":3600,"user":{"id":"\(account.uuidString)","email":"test@example.invalid"}}
            """
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let auth = try await AgendaAPI.authenticate(grant: "password",
            values: ["email": "test@example.invalid", "password": "  p\"à\\ss  "])
        precondition(auth.user.id == account && auth.expires_at! > Date().timeIntervalSince1970)
        print("PASS: password grant, headers, JSON escaping and expires_in response")

        let offsetTimestamp = "2026-09-12T15:32:25.980+00:00"
        let safeFilterTimestamp = try AgendaAPI.filterTimestamp(offsetTimestamp)
        precondition(safeFilterTimestamp.hasSuffix("Z"))
        precondition(!safeFilterTimestamp.contains("+"))
        precondition(!safeFilterTimestamp.contains(" "))
        print("PASS: PostgREST timestamp filter normalizes +00:00 to RFC3339 Z")

        let fixtures: [(Int, String, String)] = [
            (400, #"{"error_code":"invalid_credentials","msg":"Invalid login credentials"}"#, "Invalid login credentials"),
            (400, #"{"error":"invalid_grant","error_description":"Email not confirmed"}"#, "Email not confirmed"),
            (401, #"{"message":"Invalid API key"}"#, "Invalid API key"),
            (400, #"{"code":"42703","message":"column missing","details":"payload","hint":"Check schema"}"#, "Check schema"),
            (429, "", "HTTP 429"),
            (503, "<html>Unavailable</html>", "JSON leggibile")
        ]
        for (status, body, expected) in fixtures {
            AgendaAPI.transport = { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do {
                _ = try await AgendaAPI.request("/rest/v1/agenda_state")
                preconditionFailure("An HTTP error must throw")
            } catch {
                precondition((error as? SyncFailure)?.statusCode == status)
                precondition(error.localizedDescription.contains(expected))
                precondition(error.localizedDescription.contains("agenda_state"))
            }
        }
        AgendaAPI.transport = { request in
            (Data(#"{"access_token":"private-token"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do {
            _ = try await AgendaAPI.authenticate(grant: "password", values: [:])
            preconditionFailure("Malformed session must throw")
        } catch {
            precondition(error.localizedDescription.contains("formato della sessione"))
            precondition(!error.localizedDescription.contains("private-token"))
        }
        let failedLogin = try makeStore(legacy: payload("Keep on login failure"))
        let beforeLogin = failedLogin.snapshot
        AgendaAPI.transport = { request in
            (Data(#"{"error_code":"email_not_confirmed","msg":"Email not confirmed"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        await failedLogin.signIn(email: "test@example.invalid", password: "invalid")
        precondition(failedLogin.snapshot == beforeLogin)
        precondition(failedLogin.syncError?.contains("Email not confirmed") == true)
        print("PASS: server error variants, malformed session and local data on login failure")

        let legacy = payload("Legacy")
        let migration = try makeStore(legacy: legacy)
        let server1 = MockAgendaServer(account: account); connect(server1)
        await migration.synchronize()
        precondition(server1.row?.payload == legacy && migration.migrated && !migration.dirty)
        precondition(migration.backups.contains { $0.payload == legacy })
        print("PASS: UserDefaults v5.3 migration to an empty cloud")

        let cloud = payload("Cloud")
        let fresh = try makeStore()
        let server2 = MockAgendaServer(account: account); server2.row = row(cloud, 200); connect(server2)
        await fresh.synchronize()
        precondition(fresh.snapshot == cloud && server2.writes == 0)
        print("PASS: fresh install downloads existing cloud state")

        let choice = try makeStore(legacy: legacy)
        await choice.synchronize()
        precondition(choice.needsMigrationChoice && choice.snapshot == legacy && server2.writes == 0)
        await choice.resolveMigration(useLocal: false)
        precondition(choice.snapshot == cloud && choice.backups.contains { $0.payload == legacy })
        print("PASS: first-login conflict waits for a choice and preserves legacy data")

        let local = payload("New local")
        let push = try makeStore(); setLocal(push, local, 300)
        await push.synchronize()
        precondition(server2.row?.payload == local && !push.dirty)
        precondition(push.backups.contains { $0.payload == cloud })
        print("PASS: newer local state wins and archives displaced cloud state")

        let pull = try makeStore(); setLocal(pull, cloud, 100)
        await pull.synchronize()
        precondition(pull.snapshot == local && pull.backups.contains { $0.payload == cloud })
        print("PASS: newer cloud state wins and archives local state")

        let tie = try makeStore(); setLocal(tie, cloud, 300)
        await tie.synchronize()
        precondition(tie.snapshot == local)
        print("PASS: equal timestamps converge to the existing remote row")

        let offline = try makeStore(); setLocal(offline, legacy, 400)
        server2.offline = true
        await offline.synchronize()
        precondition(offline.dirty && offline.snapshot == legacy && offline.syncError != nil)
        let reloaded = AgendaStore(defaults: offline.defaults, loadSession: { nil })
        precondition(reloaded.snapshot == legacy && reloaded.dirty)
        server2.offline = false
        await offline.synchronize()
        precondition(!offline.dirty && server2.row?.payload == legacy)
        print("PASS: offline edits survive restart and retry")

        let race = try makeStore(); setLocal(race, local, 500)
        let newest = payload("Concurrent newer write")
        server2.afterRead = { server2.row = row(newest, 600) }
        await race.synchronize()
        precondition(race.snapshot == newest && server2.row?.payload == newest)
        print("PASS: conditional PATCH cannot overwrite a concurrent newer writer")

        let editing = try makeStore(); setLocal(editing, local, 700)
        let whileUploading = payload("Edited during upload")
        server2.beforeWrite = { setLocal(editing, whileUploading, 800) }
        await editing.synchronize()
        precondition(server2.row?.payload == whileUploading && !editing.dirty)
        print("PASS: edits during upload remain pending and are uploaded next")

        let refreshing = try makeStore(); setLocal(refreshing, whileUploading, 800)
        refreshing.session?.expires_at = 0
        var persistedRefresh = ""
        refreshing.saveSession = { persistedRefresh = $0.refresh_token }
        await refreshing.synchronize()
        precondition(server2.authCalls == 1 && persistedRefresh == "rotated-refresh")
        print("PASS: expired access token rotates and persists the refresh token")

        refreshing.session?.expires_at = 0
        server2.failRefresh = true
        await refreshing.synchronize()
        precondition(refreshing.needsReauthentication && refreshing.snapshot == whileUploading)
        print("PASS: revoked session requests login without clearing the agenda")

        let isolated = try makeStore(); setLocal(isolated, local, 900)
        isolated.ownerID = UUID()
        let previousWrites = server2.writes
        await isolated.synchronize()
        precondition(isolated.syncError != nil && server2.writes == previousWrites)
        print("PASS: an account mismatch cannot upload a different account's cache")
        print("All auth diagnostics and 12 sync regression scenarios passed.")
    }
}
