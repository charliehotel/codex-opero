import Foundation
import SQLite3
import Testing
@testable import QuotaCore

@Suite(.serialized)
struct AntigravityCloudTests {
    private let summary = #"{"groups":[{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","displayName":"Weekly","remainingFraction":0.6}]},{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","displayName":"Weekly","remainingFraction":0.8}]}]}"#

    @Test
    func queriesProjectScopedQuotaWithIDEUnavailable() async throws {
        let fixture = AgyCloudFixture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            fixture.record(request)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "antigravity/2.28.0")
            if request.url!.path.hasSuffix(":loadCodeAssist") {
                return response(request, json: #"{"cloudaicompanionProject":{"id":"test-project"}}"#)
            }
            let body = try JSONSerialization.jsonObject(with: bodyData(request)) as? [String: String]
            #expect(body?["project"] == "test-project")
            return response(request, json: summary)
        }
        let client = makeClient(fixture, session)
        let quota = try await AntigravityProvider(cloudClient: client).fetchQuota()
        #expect(quota.primary.remainingPercent == 80)
        #expect(quota.secondary.remainingPercent == 60)
        #expect(quota.primary.name == "7d")
        #expect(fixture.requests.count == 2)
        #expect(fixture.requests.allSatisfy { $0.url?.host == "daily-cloudcode-pa.googleapis.com" })
    }

    @Test
    func refusesProjectlessQuota() async throws {
        let fixture = AgyCloudFixture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            fixture.record(request)
            return response(request, json: #"{"currentTier":{}}"#)
        }
        await #expect(throws: ProviderError.self) { try await makeClient(fixture, session).fetchSummary() }
        #expect(fixture.requests.count == 1)
    }

    @Test
    func refreshesExpiredTokenAndPersistsRotationBeforeQuerying() async throws {
        let fixture = AgyCloudFixture(expired: true)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            fixture.record(request)
            if request.url?.host == "oauth2.googleapis.com" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
                let query = URLComponents(string: "?" + String(decoding: bodyData(request), as: UTF8.self))
                #expect(query?.queryItems?.first(where: { $0.name == "refresh_token" })?.value == "refresh+token/=&")
                return response(request, json: #"{"access_token":"renewed","refresh_token":"rotated","expires_in":3600}"#)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
            if request.url!.path.hasSuffix(":loadCodeAssist") {
                return response(request, json: #"{"cloudaicompanionProject":"test-project"}"#)
            }
            return response(request, json: summary)
        }
        let client = makeClient(fixture, session)
        _ = try await client.fetchSummary()
        _ = try await client.fetchSummary()
        #expect(fixture.saved.count == 1)
        #expect(fixture.saved.first?.token.refreshToken == "rotated")
        #expect(fixture.saved.first?.sourceFingerprint == fixture.credentials.sourceFingerprint)
        #expect(fixture.requests.filter { $0.url?.host == "oauth2.googleapis.com" }.count == 1)
        #expect(fixture.requests.count == 4)
    }

    @Test
    func refreshesAfter401OnlyOnce() async throws {
        let fixture = AgyCloudFixture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            fixture.record(request)
            if request.url?.host == "oauth2.googleapis.com" {
                return response(request, json: #"{"access_token":"renewed","expires_in":3600}"#)
            }
            return response(request, status: 401)
        }
        await #expect(throws: ProviderError.self) { try await makeClient(fixture, session).fetchSummary() }
        #expect(fixture.requests.count == 3)
        #expect(fixture.saved.first?.token.refreshToken == "refresh+token/=&")
    }

    @Test
    func honorsServerCooldownWithoutRepeatingRequests() async throws {
        let fixture = AgyCloudFixture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            fixture.record(request)
            if fixture.requests.count == 1 {
                return response(request, status: 429, headers: ["Retry-After": "3320"])
            }
            if request.url!.path.hasSuffix(":loadCodeAssist") {
                return response(request, json: #"{"cloudaicompanionProject":"test-project"}"#)
            }
            return response(request, json: summary)
        }
        let client = makeClient(fixture, session)
        await #expect(throws: ProviderError.self) { try await client.fetchSummary() }
        await #expect(throws: ProviderError.self) { try await client.fetchSummary() }
        #expect(fixture.requests.count == 1)
        fixture.advance(3321)
        _ = try await client.fetchSummary()
        #expect(fixture.requests.count == 3)
    }

    @Test
    func coalescesConcurrentTokenRefreshes() async throws {
        let fixture = AgyCloudFixture(expired: true)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            fixture.record(request)
            Thread.sleep(forTimeInterval: 0.02)
            if request.url?.host == "oauth2.googleapis.com" {
                return response(request, json: #"{"access_token":"renewed","expires_in":3600}"#)
            }
            if request.url!.path.hasSuffix(":loadCodeAssist") {
                return response(request, json: #"{"cloudaicompanionProject":"test-project"}"#)
            }
            return response(request, json: summary)
        }
        let client = makeClient(fixture, session)
        try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try await client.fetchSummary() } }
            for try await _ in group {}
        }
        #expect(fixture.requests.count == 3)
        #expect(fixture.saved.count == 1)
    }

    @Test
    func doesNotSaveAcrossAccountChanges() async throws {
        let fixture = AgyCloudFixture(expired: true)
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            fixture.record(request)
            fixture.switchAccount()
            return response(request, json: #"{"access_token":"renewed","expires_in":3600}"#)
        }
        await #expect(throws: ProviderError.self) { try await makeClient(fixture, session).fetchSummary() }
        #expect(fixture.saved.isEmpty)
        #expect(fixture.requests.count == 1)
    }

    @Test
    func rejectsQuotaFromAnAccountChangedDuringTheRequest() async throws {
        let fixture = AgyCloudFixture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            fixture.record(request)
            if request.url!.path.hasSuffix(":loadCodeAssist") {
                return response(request, json: #"{"cloudaicompanionProject":"test-project"}"#)
            }
            fixture.switchAccount()
            return response(request, json: summary)
        }
        await #expect(throws: ProviderError.self) { try await makeClient(fixture, session).fetchSummary() }
        #expect(fixture.requests.count == 2)
    }

    @Test
    func rejectsUnknownQuotaInsteadOfReportingFull() async throws {
        let fixture = AgyCloudFixture()
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        AgyCloudURLProtocol.handler = { request in
            if request.url!.path.hasSuffix(":loadCodeAssist") {
                return response(request, json: #"{"cloudaicompanionProject":"test-project"}"#)
            }
            return response(request, json: summary.replacingOccurrences(of: "0.8", with: "1.8"))
        }
        let provider = AntigravityProvider(cloudClient: makeClient(fixture, session))
        await #expect(throws: ProviderError.unsupportedPayload) { try await provider.fetchQuota() }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgyCloudURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient(_ fixture: AgyCloudFixture, _ session: URLSession) -> AgyCloudClient {
        AgyCloudClient(session: session, loadCredentials: { fixture.credentials },
                       saveCredentials: { fixture.save($0) }, now: { fixture.date },
                       oauthClients: { [AgyOAuthClient(clientID: "fixture-client", clientSecret: "fixture-secret")] })
    }
}

@Test
func antigravityDecodesGoKeyringCredentials() throws {
    let payload = Data(#"{"token":{"access_token":"access","refresh_token":"refresh","expiry":"2030-01-01T00:00:00.790527Z"},"auth_method":"consumer","id_token_email":"fixture@example.invalid"}"#.utf8)
    let wrapped = Data(("go-keyring-base64:" + payload.base64EncodedString()).utf8)
    let token = try AgyCredentialStore.decodeKeychain(wrapped)
    #expect(token.accessToken == "access")
    #expect(token.refreshToken == "refresh")
    #expect(token.expiresAt != nil)
    #expect(throws: ProviderError.self) { try AgyCredentialStore.decodeKeychain(Data("go-keyring-base64:broken".utf8)) }
}

@Test
func antigravityPreservesRotatedRefreshTokenWithNewerSourceAccess() {
    var source = AgyCloudCredentials(token: AgyOAuthToken(accessToken: "old", refreshToken: "original", expiresAt: .distantPast))
    var cached = source
    cached.token = AgyOAuthToken(accessToken: "refreshed", refreshToken: "rotated", expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
    source.token.accessToken = "newer-from-source"
    source.token.expiresAt = .distantFuture
    let merged = source.mergingRefreshed(cached)
    #expect(merged.token.accessToken == "newer-from-source")
    #expect(merged.token.refreshToken == "rotated")
    let other = AgyCloudCredentials(token: AgyOAuthToken(accessToken: "other", refreshToken: "other", expiresAt: .distantFuture))
    #expect(other.mergingRefreshed(cached).token == other.token)
}

@Test
func antigravityReadsUnifiedAndLegacyDatabaseWithoutChangingIt() throws {
    let token = protoBytes(1, Data("access".utf8)) + protoBytes(3, Data("refresh".utf8))
        + protoBytes(4, protoInteger(1, 1_900_000_000))
    let entry = protoBytes(1, Data("oauthTokenInfoSentinelKey".utf8))
        + protoBytes(2, protoBytes(1, Data(token.base64EncodedString().utf8)))
    let unified = protoBytes(1, entry).base64EncodedString()
    let legacy = protoBytes(6, token).base64EncodedString()
    #expect(try AgyCredentialStore.decodeDatabaseValue(unified, unified: true).refreshToken == "refresh")
    #expect(try AgyCredentialStore.decodeDatabaseValue(legacy, unified: false).accessToken == "access")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-test-\(UUID()).vscdb")
    defer { try? FileManager.default.removeItem(at: url) }
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    let sql = "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('antigravityUnifiedStateSync.oauthToken', '\(unified)')"
    #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(database)
    let before = try Data(contentsOf: url)
    #expect(try AgyCredentialStore.readDatabase(url).expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
    #expect(try Data(contentsOf: url) == before)
    for malformed in [Data([0x0a, 0x7f, 0x01]), Data(repeating: 0xff, count: 12), Data([0])] {
        #expect(throws: ProviderError.self) {
            try AgyCredentialStore.decodeDatabaseValue(malformed.base64EncodedString(), unified: true)
        }
    }
}

private final class AgyCloudFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var source: AgyCloudCredentials
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private var requestValues: [URLRequest] = []
    private var savedValues: [AgyCloudCredentials] = []

    init(expired: Bool = false) {
        source = AgyCloudCredentials(token: AgyOAuthToken(accessToken: "access", refreshToken: "refresh+token/=&",
            expiresAt: Date(timeIntervalSince1970: expired ? 1_700_000_000 : 2_000_000_000)))
    }
    var credentials: AgyCloudCredentials { lock.withLock { source } }
    var date: Date { lock.withLock { clock } }
    var requests: [URLRequest] { lock.withLock { requestValues } }
    var saved: [AgyCloudCredentials] { lock.withLock { savedValues } }
    func record(_ request: URLRequest) { lock.withLock { requestValues.append(request) } }
    func save(_ value: AgyCloudCredentials) { lock.withLock { savedValues.append(value) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { clock.addTimeInterval(seconds) } }
    func switchAccount() {
        lock.withLock { source = AgyCloudCredentials(token: AgyOAuthToken(accessToken: "other", refreshToken: "other-refresh", expiresAt: .distantFuture)) }
    }
}

private func response(_ request: URLRequest, status: Int = 200, headers: [String: String]? = nil, json: String = "{}") -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, Data(json.utf8))
}

private func bodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

private func protoVarint(_ value: UInt64) -> Data {
    var value = value
    var result = Data()
    repeat {
        result.append(UInt8(value & 0x7f) | (value > 0x7f ? 0x80 : 0))
        value >>= 7
    } while value != 0
    return result
}

private func protoBytes(_ number: UInt64, _ bytes: Data) -> Data {
    protoVarint(number << 3 | 2) + protoVarint(UInt64(bytes.count)) + bytes
}

private func protoInteger(_ number: UInt64, _ value: UInt64) -> Data {
    protoVarint(number << 3) + protoVarint(value)
}

private final class AgyCloudURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw ProviderError.badResponse }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Test
func antigravityDiscoversInstalledClientConfigurationFromFixture() throws {
    let clientID = String(repeating: "1", count: 12) + "-" + String(repeating: "a", count: 32) + ".apps.googleusercontent.com"
    let secret = "GOCSPX-" + String(repeating: "b", count: 28)
    let values = try AgyOAuthClient.candidates(in: Data((clientID + "\0" + secret + "\0" + clientID).utf8))
    #expect(values.count == 1)
    #expect(values.first?.clientID == clientID)
    #expect(values.first?.clientSecret == secret)
    #expect(throws: ProviderError.self) { try AgyOAuthClient.candidates(in: Data("no client configuration".utf8)) }
}
