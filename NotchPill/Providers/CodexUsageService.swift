import Foundation

/// Keeps a current Codex quota, fetched from OpenAI and cached.
///
/// The scan loop runs every few seconds; the quota changes when you send a
/// message. Those are wildly different rates, so this refreshes on its own
/// schedule and hands back the last good answer in between — a card that is
/// sixty seconds old is fine, and one that costs an HTTPS round trip per scan
/// is not.
///
/// The last good answer is also kept across failures. Wi-Fi dropping should
/// blank the card no sooner than the number actually going unknown.
actor CodexUsageService {
    /// How often the provider is actually asked. Usage moves when you send a
    /// message, and no faster.
    static let refreshInterval: TimeInterval = 60
    /// How long a cached answer stays worth showing once fetching starts
    /// failing. Beyond this the number is old enough that showing it is worse
    /// than showing nothing.
    static let staleAfter: TimeInterval = 3600

    private var cached: CodexQuota?
    private var lastFetch = Date.distantPast
    private var credentials: CodexUsageFetcher.Credentials?

    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private let authFile: URL

    init(authFile: URL = CodexUsageFetcher.authFile(),
         transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         }) {
        self.authFile = authFile
        self.transport = transport
    }

    /// The current quota, refreshing at most once per `refreshInterval`.
    /// Returns nil only when there is nothing trustworthy to show.
    func quota(now: Date = Date()) async -> CodexQuota? {
        if now.timeIntervalSince(lastFetch) < Self.refreshInterval { return cached }
        lastFetch = now
        do {
            let fresh = try await fetch(now: now)
            cached = fresh
            return fresh
        } catch {
            LogStore.log("codex", "usage fetch failed: \(Self.describe(error))")
            // Serve the cache until it is genuinely too old to mean anything.
            if let cached, let updated = cached.updatedAt,
               now.timeIntervalSince(updated) < Self.staleAfter {
                return cached
            }
            cached = nil
            return nil
        }
    }

    /// Deliberately never interpolates the error's full description into a log
    /// line: a URLError carries the failing URL, and this one has a bearer
    /// token in its headers.
    private static func describe(_ error: Error) -> String {
        if let fetchError = error as? CodexUsageFetcher.FetchError {
            switch fetchError {
            case .noCredentials: return "not signed in to Codex"
            case .unauthorized: return "token rejected — sign in to Codex again"
            case .http(let code): return "HTTP \(code)"
            case .malformedResponse: return "unrecognised response"
            }
        }
        return "\((error as NSError).domain) \((error as NSError).code)"
    }

    private func fetch(now: Date) async throws -> CodexQuota {
        var creds = try loadCredentials()
        if creds.needsRefresh(now: now) {
            creds = (try? await refresh(creds, now: now)) ?? creds
        }

        var (data, response) = try await transport(CodexUsageFetcher.usageRequest(creds))
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // A rejected token is the one failure worth retrying: Codex may have
        // rotated it since we read the file, or our copy aged out early.
        if status == 401 {
            creds = try await refresh(creds, now: now)
            (data, response) = try await transport(CodexUsageFetcher.usageRequest(creds))
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }

        guard status != 401 else { throw CodexUsageFetcher.FetchError.unauthorized }
        guard (200..<300).contains(status) else {
            throw CodexUsageFetcher.FetchError.http(status)
        }
        guard let quota = CodexUsageFetcher.quota(in: data, now: now) else {
            throw CodexUsageFetcher.FetchError.malformedResponse
        }
        credentials = creds
        return quota
    }

    private func loadCredentials() throws -> CodexUsageFetcher.Credentials {
        if let credentials { return credentials }
        guard let data = try? Data(contentsOf: authFile),
              let parsed = CodexUsageFetcher.credentials(in: data) else {
            throw CodexUsageFetcher.FetchError.noCredentials
        }
        credentials = parsed
        return parsed
    }

    /// Refreshes in memory only. `auth.json` belongs to Codex, and two
    /// processes racing to rewrite it is a good way to log you out of both.
    private func refresh(_ creds: CodexUsageFetcher.Credentials,
                         now: Date) async throws -> CodexUsageFetcher.Credentials {
        let (data, response) = try await transport(CodexUsageFetcher.refreshRequest(creds))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let next = CodexUsageFetcher.refreshed(in: data, previous: creds, now: now) else {
            throw CodexUsageFetcher.FetchError.unauthorized
        }
        credentials = next
        return next
    }
}
