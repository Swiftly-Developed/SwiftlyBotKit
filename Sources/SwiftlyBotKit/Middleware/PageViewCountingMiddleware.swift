import Foundation
import Vapor

/// Counts page views by people, when ``BotKitConfiguration/PageViews`` is on.
///
/// Installed by `BotKit.configureRoutes(for:config:)` next to the AI agent
/// middleware, and like it after `FileMiddleware`, so static files never reach
/// it. The response is never altered or delayed: once it is ready, the filter
/// looks at its status and content type and the request's headers, and a
/// counted view is one increment of an in-memory counter. Errors pass
/// through uncounted, since a page that failed was not read.
///
/// Nothing from the request is kept beyond the site key and the path, query
/// string dropped, and with dimensions on, the coarse ``PageViewFacts``
/// derived from it.
struct PageViewCountingMiddleware: AsyncMiddleware {
    let filter: PageViewFilter
    let counter: PageViewCounter
    let siteKey: @Sendable (Request) -> String
    /// Whether to derive ``PageViewFacts`` for each counted view.
    var recordsDimensions = false
    var clientIP: ClientIPStrategy = .lastForwardedFor
    var countries: CountryLookup?

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        let path = request.url.path
        if filter.counts(
            method: request.method,
            path: path,
            requestHeaders: request.headers,
            status: response.status,
            responseHeaders: response.headers
        ) {
            let facts = recordsDimensions
                ? PageViewFacts.derive(
                    headers: request.headers,
                    query: request.url.query,
                    host: request.headers.first(name: .host),
                    clientIP: countries == nil ? nil : clientIP.clientIP(for: request),
                    countries: countries
                )
                : nil
            counter.record(
                siteKey: siteKey(request),
                path: BotRequestClassifier.collapsingRepeatedSlashes(path),
                facts: facts
            )
        }
        return response
    }
}
