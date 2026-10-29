import Foundation
import Testing
@testable import QuotaCore

@Suite(.serialized)
struct ClaudeProviderTests {
    @Test func expiredCredentialsRefreshAndPreserveFileMetadata() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        let provider = fixture.provider()
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try ClaudeFixture.body(request)
                #expect(body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
                #expect(body["grant_type"] as? String == "refresh_token")
                #expect(body["refresh_token"] as? String == "old-refresh")
                #expect(body["scope"] as? String == "user:profile user:inference")
                return .token()
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
            return .usage
        }
        let quota = try await provider.fetchQuota()
        #expect(quota.primary.usedPercent == 21)
        #expect(fixture.state.paths == ["/v1/oauth/token", "/api/oauth/usage"])
        let json = try fixture.fileJSON()
        let oauth = try #require(json["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new-access")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["expiresAt"] as? Double == fixture.state.date.timeIntervalSince1970 * 1000 + 3_600_000)
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect(json["unrelated"] as? [String: Int] == ["keep": 17])
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func nearExpiryRefreshesAndRetainsUnrotatedRefreshToken() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        try fixture.write(expiresAt: fixture.state.date.addingTimeInterval(30))
        fixture.respond { request in
            request.url?.path == "/v1/oauth/token" ? .token(refresh: nil) : .usage
        }
        _ = try await fixture.provider().fetchQuota()
        let oauth = try #require(try fixture.fileJSON()["claudeAiOauth"] as? [String: Any])
        #expect(oauth["refreshToken"] as? String == "old-refresh")
        #expect(fixture.state.paths.first == "/v1/oauth/token")
    }

    @Test func usage401RefreshesOnlyOnceAndThenRequiresLogin() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        fixture.respond { request in request.url?.path == "/v1/oauth/token" ? .token() : .init(status: 401, body: "private server detail") }
        await expectLoginError { _ = try await fixture.provider().fetchQuota() }
        #expect(fixture.state.paths == ["/api/oauth/usage", "/v1/oauth/token", "/api/oauth/usage"])
    }

    @Test func usage401RefreshesAndReturnsQuota() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" { return .token() }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" ? .init(status: 401) : .usage
        }
        _ = try await fixture.provider().fetchQuota()
        #expect(fixture.state.paths == ["/api/oauth/usage", "/v1/oauth/token", "/api/oauth/usage"])
    }

    @Test func refresh401DoesNotRetryOrExposeResponse() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        let original = try Data(contentsOf: fixture.file)
        fixture.respond { _ in .init(status: 401, body: "private server detail") }
        await expectLoginError { _ = try await fixture.provider().fetchQuota() }
        #expect(fixture.state.paths == ["/v1/oauth/token"])
        #expect(try Data(contentsOf: fixture.file) == original)
    }

    @Test func proactiveRefreshStillBoundsUsage401Retries() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        fixture.respond { request in request.url?.path == "/v1/oauth/token" ? .token() : .init(status: 401) }
        await expectLoginError { _ = try await fixture.provider().fetchQuota() }
        #expect(fixture.state.paths == ["/v1/oauth/token", "/api/oauth/usage"])
    }

    @Test func usage429HonorsSecondsAcrossProviderInstances() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        let coordinator = ClaudeRequestCoordinator()
        let first = fixture.provider(coordinator: coordinator)
        let second = fixture.provider(coordinator: coordinator)
        let deadline = fixture.state.date.addingTimeInterval(90)
        fixture.respond { _ in .init(status: 429, headers: ["Retry-After": "90"]) }
        await expect429(retryAt: deadline) { _ = try await first.fetchQuota() }
        await expect429(retryAt: deadline) { _ = try await second.fetchQuota() }
        fixture.state.advance(89)
        await expect429(retryAt: deadline) { _ = try await first.fetchQuota() }
        #expect(fixture.state.paths.count == 1)
        fixture.state.advance(1)
        fixture.respond { _ in .usage }
        _ = try await second.fetchQuota()
        #expect(fixture.state.paths.count == 2)
    }

    @Test func token429HonorsHTTPDateAndDoesNotSendUsage() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let deadline = fixture.state.date.addingTimeInterval(120)
        let retry = formatter.string(from: deadline)
        fixture.respond { _ in .init(status: 429, headers: ["Retry-After": retry]) }
        let provider = fixture.provider()
        await expect429(retryAt: deadline) { _ = try await provider.fetchQuota() }
        fixture.state.advance(119)
        await expect429(retryAt: deadline) { _ = try await provider.fetchQuota() }
        #expect(fixture.state.paths == ["/v1/oauth/token"])
        fixture.state.advance(1)
        fixture.respond { request in request.url?.path == "/v1/oauth/token" ? .token() : .usage }
        _ = try await provider.fetchQuota()
        #expect(fixture.state.paths == ["/v1/oauth/token", "/v1/oauth/token", "/api/oauth/usage"])
    }

    @Test func missingOrInvalidRetryAfterUsesBoundedBackoff() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        let provider = fixture.provider()
        var deadline = fixture.state.date.addingTimeInterval(30)
        fixture.respond { _ in .init(status: 429) }
        await expect429(retryAt: deadline) { _ = try await provider.fetchQuota() }
        fixture.state.advance(29)
        await expect429(retryAt: deadline) { _ = try await provider.fetchQuota() }
        #expect(fixture.state.paths.count == 1)
        fixture.state.advance(1)
        deadline = fixture.state.date.addingTimeInterval(60)
        fixture.respond { _ in .init(status: 429, headers: ["Retry-After": "invalid"]) }
        await expect429(retryAt: deadline) { _ = try await provider.fetchQuota() }
        fixture.state.advance(59)
        await expect429(retryAt: deadline) { _ = try await provider.fetchQuota() }
        #expect(fixture.state.paths.count == 2)
        fixture.state.advance(1)
        fixture.respond { _ in .usage }
        _ = try await provider.fetchQuota()
        #expect(fixture.state.paths.count == 3)
    }

    @Test(arguments: ["0", "Tue, 01 Jan 2019 00:00:00 GMT"])
    func zeroOrPastRetryAfterWaitsAtLeastOneSecond(header: String) async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        let provider = fixture.provider()
        let deadline = fixture.state.date.addingTimeInterval(1)
        fixture.respond { _ in .init(status: 429, headers: ["Retry-After": header]) }
        await expect429(retryAt: deadline) { _ = try await provider.fetchQuota() }
        fixture.state.advance(0.5)
        await expect429(retryAt: deadline) { _ = try await provider.fetchQuota() }
        #expect(fixture.state.paths.count == 1)
        fixture.state.advance(0.5)
        fixture.respond { _ in .usage }
        _ = try await provider.fetchQuota()
        #expect(fixture.state.paths.count == 2)
    }

    @Test(arguments: [0o600, 0o640])
    func atomicFileRefreshPreservesExistingPermissions(mode: Int) async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fixture.file.path)
        fixture.respond { request in request.url?.path == "/v1/oauth/token" ? .token() : .usage }
        _ = try await fixture.provider().fetchQuota()
        let savedMode = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.posixPermissions] as? Int
        #expect(savedMode == mode)
        let oauth = try #require(try fixture.fileJSON()["claudeAiOauth"] as? [String: Any])
        #expect(oauth["refreshToken"] as? String == "new-refresh")
    }

    @Test func concurrentCallsShareOneRefresh() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" {
                Thread.sleep(forTimeInterval: 0.03)
                return .token()
            }
            return .usage
        }
        let coordinator = ClaudeRequestCoordinator()
        let first = fixture.provider(coordinator: coordinator)
        let second = fixture.provider(coordinator: coordinator)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask { _ = try await (index.isMultiple(of: 2) ? first : second).fetchQuota() }
            }
            try await group.waitForAll()
        }
        #expect(fixture.state.paths.filter { $0 == "/v1/oauth/token" }.count == 1)
    }

    @Test func accountChangedDuringUsage401UsesNewCredentialsWithoutRefresh() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        fixture.respond { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access" {
                try fixture.write(access: "cli-access", refresh: "cli-refresh")
                return .init(status: 401)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cli-access")
            return .usage
        }
        _ = try await fixture.provider().fetchQuota()
        #expect(fixture.state.paths == ["/api/oauth/usage", "/api/oauth/usage"])
    }

    @Test func newlyCreatedKeychainCredentialsWinOverFileRefresh() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        let originalFile = try Data(contentsOf: fixture.file)
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" {
                fixture.state.keychain = .init(data: try fixture.credentials(access: "cli-access", refresh: "cli-refresh"), persistentReference: Data("new-item".utf8))
                return .token()
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cli-access")
            return .usage
        }
        _ = try await fixture.provider().fetchQuota()
        #expect(fixture.state.writes == 0)
        #expect(try Data(contentsOf: fixture.file) == originalFile)
    }

    @Test func changedFileCredentialsWinOverRefreshResponse() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" {
                try fixture.write(access: "cli-access", refresh: "cli-refresh")
                return .token()
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cli-access")
            return .usage
        }
        _ = try await fixture.provider().fetchQuota()
        let oauth = try #require(try fixture.fileJSON()["claudeAiOauth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "cli-access")
        #expect(oauth["refreshToken"] as? String == "cli-refresh")
    }

    @Test func changedCredentialsWinEvenWhenOldRefreshFails() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" {
                try fixture.write(access: "cli-access", refresh: "cli-refresh")
                return .init(status: 401)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cli-access")
            return .usage
        }
        _ = try await fixture.provider().fetchQuota()
        #expect(fixture.state.paths.count == 2)
    }

    @Test func keychainRefreshUpdatesOriginalItemAndKeepsFileUntouched() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        let fileBefore = try Data(contentsOf: fixture.file)
        fixture.state.keychain = .init(data: try fixture.credentials(expired: true), persistentReference: Data("original-item".utf8))
        fixture.respond { request in request.url?.path == "/v1/oauth/token" ? .token() : .usage }
        _ = try await fixture.provider().fetchQuota()
        #expect(fixture.state.writes == 1)
        #expect(fixture.state.keychain?.persistentReference == Data("original-item".utf8))
        let data = try #require(fixture.state.keychain?.data)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(json["claudeAiOauth"] as? [String: Any])
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["subscriptionType"] as? String == "max")
        #expect(json["unrelated"] as? [String: Int] == ["keep": 17])
        #expect(try Data(contentsOf: fixture.file) == fileBefore)
    }

    @Test func replacedKeychainItemIsNotOverwritten() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        fixture.state.keychain = .init(data: try fixture.credentials(expired: true), persistentReference: Data("original-item".utf8))
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" {
                fixture.state.keychain = .init(data: try fixture.credentials(access: "cli-access", refresh: "cli-refresh"), persistentReference: Data("replacement-item".utf8))
                return .token()
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cli-access")
            return .usage
        }
        _ = try await fixture.provider().fetchQuota()
        #expect(fixture.state.writes == 0)
        #expect(fixture.state.keychain?.persistentReference == Data("replacement-item".utf8))
    }

    @Test func metadataChangedDuringRefreshIsPreserved() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" {
                var json = try fixture.fileJSON()
                json["addedByCLI"] = "preserve"
                try JSONSerialization.data(withJSONObject: json).write(to: fixture.file, options: .atomic)
                return .token()
            }
            return .usage
        }
        _ = try await fixture.provider().fetchQuota()
        #expect(try fixture.fileJSON()["addedByCLI"] as? String == "preserve")
    }

    @Test func metadataChangedAtKeychainUpdateIsMergedWithoutAnotherRefresh() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        fixture.state.keychain = .init(data: try fixture.credentials(expired: true), persistentReference: Data("original-item".utf8))
        fixture.respond { request in request.url?.path == "/v1/oauth/token" ? .token() : .usage }
        let provider = fixture.provider(updateKeychain: { expected, data in
            let item = try #require(fixture.state.keychain)
            var json = try #require(JSONSerialization.jsonObject(with: item.data) as? [String: Any])
            if json["lateMetadata"] == nil {
                json["lateMetadata"] = "keep"
                fixture.state.keychain = .init(data: try JSONSerialization.data(withJSONObject: json), persistentReference: item.persistentReference)
            }
            return fixture.state.update(expected, data)
        })
        _ = try await provider.fetchQuota()
        let data = try #require(fixture.state.keychain?.data)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(json["claudeAiOauth"] as? [String: Any])
        #expect(json["lateMetadata"] as? String == "keep")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(fixture.state.writes == 1)
        #expect(fixture.state.paths == ["/v1/oauth/token", "/api/oauth/usage"])
    }

    @Test func accountChangedAtKeychainUpdateUsesNewCredentials() async throws {
        let fixture = try ClaudeFixture()
        defer { fixture.cleanUp() }
        fixture.state.keychain = .init(data: try fixture.credentials(expired: true), persistentReference: Data("original-item".utf8))
        fixture.respond { request in
            if request.url?.path == "/v1/oauth/token" { return .token() }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cli-access")
            return .usage
        }
        let provider = fixture.provider(updateKeychain: { expected, data in
            fixture.state.keychain = .init(data: try fixture.credentials(access: "cli-access", refresh: "cli-refresh"), persistentReference: expected.persistentReference)
            return fixture.state.update(expected, data)
        })
        _ = try await provider.fetchQuota()
        #expect(fixture.state.writes == 0)
    }

    @Test func missingRefreshTokenRequiresLoginWithoutNetwork() async throws {
        let fixture = try ClaudeFixture(expired: true)
        defer { fixture.cleanUp() }
        var json = try fixture.fileJSON()
        var oauth = try #require(json["claudeAiOauth"] as? [String: Any])
        oauth.removeValue(forKey: "refreshToken")
        json["claudeAiOauth"] = oauth
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.file, options: .atomic)
        fixture.respond { _ in Issue.record("No request expected"); return .usage }
        await expectLoginError { _ = try await fixture.provider().fetchQuota() }
        #expect(fixture.state.paths.isEmpty)
    }
}

private func expectLoginError(_ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected a login error")
    } catch {
        #expect(error.localizedDescription.contains("다시 로그인"))
        #expect(!error.localizedDescription.contains("private server detail"))
        #expect(!error.localizedDescription.contains("old-refresh"))
    }
}

private func expect429(retryAt: Date, _ operation: () async throws -> Void) async {
    do { try await operation(); Issue.record("Expected rate limit") }
    catch {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        let expected = "Claude rate limited; retry after \(formatter.string(from: retryAt))"
        #expect(error as? ProviderError == .other(expected))
        #expect(error.localizedDescription == expected)
        #expect(!error.localizedDescription.contains("login"))
    }
}

private struct ClaudeReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = "{}"
    static let usage = ClaudeReply(body: #"{"five_hour":{"utilization":21,"resets_at":"2030-01-02T00:00:00Z"},"seven_day":{"utilization":45}}"#)
    static func token(refresh: String? = "new-refresh") -> ClaudeReply {
        var json: [String: Any] = ["access_token": "new-access", "expires_in": 3600]
        json["refresh_token"] = refresh
        return ClaudeReply(body: String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!)
    }
}

private final class ClaudeTestState: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_893_456_000)
    private var requests: [String] = []
    private var item: KeychainReader.Password?
    private var writeCount = 0
    var date: Date { lock.withLock { instant } }
    var paths: [String] { lock.withLock { requests } }
    var writes: Int { lock.withLock { writeCount } }
    var keychain: KeychainReader.Password? {
        get { lock.withLock { item } }
        set { lock.withLock { item = newValue } }
    }
    func advance(_ seconds: TimeInterval) { lock.withLock { instant.addTimeInterval(seconds) } }
    func record(_ request: URLRequest) { lock.withLock { requests.append(request.url!.path) } }
    func update(_ expected: KeychainReader.Password, _ data: Data) -> Bool {
        lock.withLock {
            guard item?.persistentReference == expected.persistentReference, item?.data == expected.data else { return false }
            item = .init(data: data, persistentReference: expected.persistentReference)
            writeCount += 1
            return true
        }
    }
}

private final class ClaudeFixture: Sendable {
    let directory: URL
    let file: URL
    let session: URLSession
    let state = ClaudeTestState()
    init(expired: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        file = directory.appendingPathComponent("credentials.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeURLProtocolStub.self]
        session = URLSession(configuration: configuration)
        try credentials(expired: expired).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func credentials(access: String = "old-access", refresh: String = "old-refresh", expired: Bool = false, expiresAt: Date? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": access, "refreshToken": refresh,
                              "expiresAt": (expiresAt ?? state.date.addingTimeInterval(expired ? -1 : 3600)).timeIntervalSince1970 * 1000,
                              "scopes": ["user:profile", "user:inference"], "subscriptionType": "max"],
            "unrelated": ["keep": 17],
        ])
    }
    func write(access: String = "old-access", refresh: String = "old-refresh", expiresAt: Date? = nil) throws {
        try credentials(access: access, refresh: refresh, expiresAt: expiresAt).write(to: file, options: .atomic)
    }
    func fileJSON() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    func provider(
        coordinator: ClaudeRequestCoordinator = ClaudeRequestCoordinator(),
        updateKeychain: (@Sendable (KeychainReader.Password, Data) throws -> Bool)? = nil
    ) -> ClaudeProvider {
        ClaudeProvider(session: session, credentialsFileURL: file,
                       readKeychain: { [state] in
                           guard let item = state.keychain else { throw ProviderError.credentialsMissing }
                           return item
                       }, updateKeychain: updateKeychain ?? { [state] in state.update($0, $1) },
                       now: { [state] in state.date }, coordinator: coordinator)
    }
    func respond(_ handler: @escaping @Sendable (URLRequest) throws -> ClaudeReply) {
        ClaudeURLProtocolStub.handler = { [state] request in
            state.record(request)
            return try handler(request)
        }
    }
    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func cleanUp() {
        session.invalidateAndCancel()
        ClaudeURLProtocolStub.handler = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class ClaudeURLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> ClaudeReply)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let reply = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
