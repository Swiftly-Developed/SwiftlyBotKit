import Foundation
import Vapor

/// Records AI agent visits and AI-assistant referrals.
///
/// Installed by `BotKit.configureRoutes(for:config:)`. Register it after
/// `FileMiddleware` (that is, call `configureRoutes` after adding
/// `FileMiddleware`): static assets are filtered out anyway, and running late
/// means the status code is the one the reader actually got, including
/// redirects and 404s. A crawler hammering URLs that 404 is worth seeing, so
/// an error thrown further in (`RouteNotFound`, an `Abort`) is recorded with
/// the status it turns into (500 for anything that is not an `AbortError`)
/// and then rethrown unchanged.
///
/// The response is never delayed. The middleware does one synchronous catalog
/// lookup, and only if that matches does it hand a plain value off to a
/// detached task to be verified and written. At most
/// ``BotKitConfiguration/Recording/maximumPendingWrites`` such tasks run at
/// once; beyond that a visit is dropped rather than queued, so a slow
/// database under a crawler burst cannot grow memory without bound.
struct AIBotTrackingMiddleware: AsyncMiddleware {
    let recorder: BotTrafficRecorder
    /// Which site a request belongs to, so a row is filed under the same site
    /// the page was rendered for.
    let siteKey: @Sendable (Request) -> String
    let clientIP: ClientIPStrategy
    /// Caps the detached writes in flight.
    var pendingWrites = PendingWriteLimiter(maximum: BotKitConfiguration.Recording.default.maximumPendingWrites)
    var logger = Logger(label: "SwiftlyBotKit")

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let response: Response
        do {
            response = try await next.respond(to: request)
        } catch {
            // An unrouted path (`RouteNotFound`) or an `Abort` arrives here as
            // a thrown error, which `ErrorMiddleware` further out turns into
            // the response. Record it with the status that error will become,
            // then rethrow it untouched so the response is exactly the same.
            record(request, status: (error as? any AbortError)?.status ?? .internalServerError)
            throw error
        }
        record(request, status: response.status)
        return response
    }

    private func record(_ request: Request, status: HTTPResponseStatus) {
        let path = request.url.path
        let userAgent = request.headers.first(name: .userAgent)
        let referer = request.headers.first(name: .referer)
        guard recorder.classifier.isWorthRecording(path: path, userAgent: userAgent, referer: referer) else {
            return
        }

        let key = siteKey(request)
        if key == BotKitConfiguration.reservedAllSitesKey, pendingWrites.shouldReportReservedSiteKey() {
            logger.warning(
                "The BotKit siteKey closure returned \"all\", the key reserved for the dashboard's all-sites view. Such rows are stored as \"all\" and cannot be filtered to on their own. This is logged once."
            )
        }
        guard pendingWrites.acquire() else {
            let dropped = pendingWrites.recordDrop()
            if dropped == 1 || dropped % 1000 == 0 {
                logger.warning(
                    "Dropped an AI bot visit: \(pendingWrites.maximum) recording writes are already in flight (\(dropped) dropped so far). The database is slower than the bot traffic; raise recording.maximumPendingWrites or check the database."
                )
            }
            return
        }

        let candidate = BotVisitCandidate(
            siteKey: key,
            path: BotTrafficRecorder.storable(path),
            method: request.method.rawValue,
            statusCode: Int(status.code),
            userAgent: userAgent,
            referer: referer,
            clientIP: clientIP.clientIP(for: request)
        )
        let recorder = self.recorder
        let pendingWrites = self.pendingWrites
        Task.detached {
            await recorder.record(candidate)
            pendingWrites.release()
        }
    }
}

/// Counts the recording writes in flight and refuses new ones beyond a cap.
final class PendingWriteLimiter: @unchecked Sendable {
    let maximum: Int
    // Guarded by `lock`.
    private let lock = NSLock()
    private var inFlightCount = 0
    private var dropped = 0
    private var reservedKeyReported = false

    init(maximum: Int) {
        self.maximum = max(1, maximum)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Takes a slot, or returns `false` when every slot is taken.
    func acquire() -> Bool {
        locked {
            guard inFlightCount < maximum else { return false }
            inFlightCount += 1
            return true
        }
    }

    func release() {
        locked { inFlightCount = max(0, inFlightCount - 1) }
    }

    /// Counts a dropped visit and returns the running total.
    func recordDrop() -> Int {
        locked {
            dropped += 1
            return dropped
        }
    }

    var inFlight: Int { locked { inFlightCount } }

    /// `true` the first time only.
    func shouldReportReservedSiteKey() -> Bool {
        locked {
            defer { reservedKeyReported = true }
            return !reservedKeyReported
        }
    }
}
