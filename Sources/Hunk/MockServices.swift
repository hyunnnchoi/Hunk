import Foundation

struct MockChangeProvider: ChangeProvider {
    func loadSnapshot() async throws -> ReviewSnapshot {
        ReviewSnapshot(repository: "acme / orbital", branch: "agent/reliable-cache", revision: "mock-v1", changes: Self.changes,
                       title: "Make caching reliable", scope: "demo", grouped: true)
    }

    static var changes: [SemanticChange] { [
        SemanticChange(
            title: "Keep fresh results in memory",
            summary: "Serve recent responses from the cache before making another network request.",
            rationale: "Repeated visits currently fetch the same data. A short-lived cache makes navigation feel immediate while preserving the refresh path.",
            risk: "Behavior change · Responses can be up to 60 seconds old.",
            validation: "Suggested: verify a cache hit, expiration, and an explicit refresh. These checks have not been run; this is mock code.",
            patches: [FilePatch(path: "Sources/Networking/APIClient.swift", symbol: "APIClient.fetch(_:)", lines: [
                .init(.context, 24, 24, "func fetch(_ endpoint: Endpoint) async throws -> Data {"),
                .init(.addition, nil, 25, "    if let cached = cache.value(for: endpoint.cacheKey) {"),
                .init(.addition, nil, 26, "        return cached"),
                .init(.addition, nil, 27, "    }"),
                .init(.context, 25, 28, "    let request = endpoint.makeRequest()"),
                .init(.context, 26, 29, "    let (data, _) = try await session.data(for: request)"),
                .init(.addition, nil, 30, "    cache.insert(data, for: endpoint.cacheKey, ttl: 60)"),
                .init(.context, 27, 31, "    return data"),
                .init(.context, 28, 32, "}")
            ])]),
        SemanticChange(
            title: "Give each request a stable cache key",
            summary: "Include the HTTP method and the full URL when identifying cached responses.",
            rationale: "A path alone collides when query parameters differ. The complete URL keeps pagination and search responses separate.",
            risk: "Review carefully · Authentication scope still needs a product decision.",
            validation: "Suggested: compare requests with different methods, queries, and accounts. Mock fixtures are illustrative, not a complete cache implementation.",
            patches: [FilePatch(path: "Sources/Networking/Endpoint.swift", symbol: "Endpoint.cacheKey", lines: [
                .init(.context, 12, 12, "var cacheKey: String {"),
                .init(.deletion, 13, nil, "    path"),
                .init(.addition, nil, 13, "    \"\\(method.rawValue):\\(url.absoluteString)\""),
                .init(.context, 14, 14, "}")
            ])]),
        SemanticChange(
            title: "Let refresh bypass the cache",
            summary: "Connect the refresh gesture to a forced fetch across the client and view model.",
            rationale: "A user-initiated refresh should always request current data. This semantic change groups both sides of that behavior together.",
            risk: "API change · Existing callers retain the default cache behavior.",
            validation: "Suggested: ensure pull-to-refresh makes a request while ordinary navigation uses the cache.",
            patches: [FilePatch(path: "Sources/Networking/APIClient.swift", symbol: "APIClient.fetch(_:forceRefresh:)", lines: [
                .init(.deletion, 24, nil, "func fetch(_ endpoint: Endpoint) async throws -> Data {"),
                .init(.addition, nil, 24, "func fetch(_ endpoint: Endpoint, forceRefresh: Bool = false) async throws -> Data {"),
                .init(.deletion, 25, nil, "    if let cached = cache.value(for: endpoint.cacheKey) {"),
                .init(.addition, nil, 25, "    if !forceRefresh, let cached = cache.value(for: endpoint.cacheKey) {"),
                .init(.context, 26, 26, "        return cached"),
                .init(.context, 27, 27, "    }")
            ]), FilePatch(path: "Sources/Features/FeedViewModel.swift", symbol: "FeedViewModel.refresh()", lines: [
                .init(.context, 41, 41, "func refresh() async throws {"),
                .init(.deletion, 42, nil, "    let data = try await client.fetch(.feed)"),
                .init(.addition, nil, 42, "    let data = try await client.fetch(.feed, forceRefresh: true)"),
                .init(.context, 43, 43, "    items = try decoder.decode([Item].self, from: data)"),
                .init(.context, 44, 44, "}")
            ])]),
        SemanticChange(
            title: "Remove expired entries on access",
            summary: "Evict stale values when they are read so an expired response is never returned.",
            rationale: "Keeping expiration next to lookup gives every caller the same freshness guarantee. Background eviction can be introduced separately.",
            risk: "Resource usage · Unread expired entries stay allocated until a later cleanup.",
            validation: "Suggested: inject a clock and test just before, at, and after the expiration boundary.",
            patches: [FilePatch(path: "Sources/Cache/ResponseCache.swift", symbol: "ResponseCache.value(for:)", lines: [
                .init(.context, 18, 18, "func value(for key: String) -> Data? {"),
                .init(.deletion, 19, nil, "    entries[key]?.data"),
                .init(.addition, nil, 19, "    guard let entry = entries[key] else { return nil }"),
                .init(.addition, nil, 20, "    guard entry.expiresAt > clock.now else {"),
                .init(.addition, nil, 21, "        entries.removeValue(forKey: key)"),
                .init(.addition, nil, 22, "        return nil"),
                .init(.addition, nil, 23, "    }"),
                .init(.addition, nil, 24, "    return entry.data"),
                .init(.context, 20, 25, "}")
            ])])
    ] }
}

struct MockAgentClient: AgentClient {
    var displayName: String { "Mock Agent" }
    func respond(to request: AgentRequest) async throws -> AgentReply {
        try await Task.sleep(for: .milliseconds(700))
        return AgentReply(text: "[Mock response] I received your request about “\(request.change.title)”: \n\n“\(request.message)”\n\nReview context: \(request.change.rationale)\n\nA connected agent would investigate or propose a new revision here. No code was changed. This change remains pending until you decide.")
    }
}
