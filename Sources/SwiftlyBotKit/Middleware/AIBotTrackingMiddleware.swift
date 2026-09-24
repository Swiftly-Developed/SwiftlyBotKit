import Foundation
import Vapor

/// Records AI agent visits and AI-assistant referrals.
///
/// Installed by `BotKit.configureRoutes(for:config:)`. Register it after
/// `FileMiddleware` (that is, call `configureRoutes` after adding
/// `FileMiddleware`): static assets are filtered out anyway, and running late
/// means the status code is the one the reader actually got, including
/// redirects and 404s. A crawler hammering URLs that 404 is worth seeing.
///
/// The response is never delayed. The middleware does one synchronous catalog
/// lookup, and only if that matches does it hand a plain value off to a
/// detached task to be verified and written.
struct AIBotTrackingMiddleware: AsyncMiddleware {
    let recorder: BotTrafficRecorder
    /// Which site a request belongs to, so a row is filed under the same site
    /// the page was rendered for.
    let siteKey: @Sendable (Request) -> String
    let clientIP: ClientIPStrategy

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)

        let path = request.url.path
        let userAgent = request.headers.first(name: .userAgent)
        let referer = request.headers.first(name: .referer)
        guard recorder.classifier.isWorthRecording(path: path, userAgent: userAgent, referer: referer) else {
            return response
        }

        let candidate = BotVisitCandidate(
            siteKey: siteKey(request),
            path: String(path.prefix(512)),
            method: request.method.rawValue,
            statusCode: Int(response.status.code),
            userAgent: userAgent,
            referer: referer,
            clientIP: clientIP.clientIP(for: request)
        )
        let recorder = self.recorder
        Task.detached { await recorder.record(candidate) }

        return response
    }
}
