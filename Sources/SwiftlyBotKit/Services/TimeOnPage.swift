import Foundation
import Vapor

/// A duration band of `page_view_durations`. The raw values are stored, so
/// they are frozen once released.
enum TimeOnPageBand: Int, CaseIterable, Sendable {
    case under10s = 0
    case under30s = 1
    case under1m = 2
    case under3m = 3
    case under10m = 4
    case over10m = 5

    /// The longest reading kept. A tab left open on a visible page for an
    /// afternoon is not an afternoon of reading.
    static let maximumSeconds = 1_800

    init(seconds: Int) {
        switch seconds {
        case ..<10: self = .under10s
        case ..<30: self = .under30s
        case ..<60: self = .under1m
        case ..<180: self = .under3m
        case ..<600: self = .under10m
        default: self = .over10m
        }
    }

    var label: String {
        switch self {
        case .under10s: return "Under 10 s"
        case .under30s: return "10 to 30 s"
        case .under1m: return "30 s to 1 min"
        case .under3m: return "1 to 3 min"
        case .under10m: return "3 to 10 min"
        case .over10m: return "10 min or more"
        }
    }
}

/// A time on page counter's key: site, local day, page and band.
struct TimeOnPageKey: Hashable, Sendable {
    let siteKey: String
    let day: PageViewDay
    let path: String
    let band: TimeOnPageBand
}

/// Readings gathered since the last write: per key, how many and their
/// summed seconds. The same lock-and-dictionary shape as ``CountTally``, with
/// two sums instead of one.
final class TimeOnPageTally: @unchecked Sendable {
    struct Sums: Sendable, Equatable {
        var readings: Int
        var seconds: Int
    }

    let maximumKeys: Int
    // Guarded by `lock`.
    private let lock = NSLock()
    private var sums: [TimeOnPageKey: Sums] = [:]
    private var dropped = 0

    init(maximumKeys: Int) {
        self.maximumKeys = max(1, maximumKeys)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Adds one reading. Returns `nil` when kept, or the running total of
    /// dropped readings when the tally is full and `key` is new.
    func add(_ key: TimeOnPageKey, seconds: Int) -> Int? {
        locked {
            if var current = sums[key] {
                current.readings += 1
                current.seconds += seconds
                sums[key] = current
                return nil
            }
            guard sums.count < maximumKeys else {
                dropped += 1
                return dropped
            }
            sums[key] = Sums(readings: 1, seconds: seconds)
            return nil
        }
    }

    func drain() -> [TimeOnPageKey: Sums] {
        locked {
            defer { sums = [:] }
            return sums
        }
    }

    /// Puts sums from a failed write back, as far as there is room. Returns
    /// how many readings did not fit.
    func restore(_ restored: [TimeOnPageKey: Sums]) -> Int {
        locked {
            var lost = 0
            for (key, value) in restored {
                if var current = sums[key] {
                    current.readings += value.readings
                    current.seconds += value.seconds
                    sums[key] = current
                } else if sums.count < maximumKeys {
                    sums[key] = value
                } else {
                    lost += value.readings
                }
            }
            return lost
        }
    }

    var pendingKeys: Int { locked { sums.count } }
}

/// The pages this process counted a view of, today and yesterday, per site.
///
/// A time on page beacon is only kept for one of these, so the beacon, which
/// anyone can post, cannot add paths that no reader ever opened. Yesterday is
/// kept for readers who opened a page just before midnight.
final class KnownPagePaths: @unchecked Sendable {
    private struct Entry: Hashable {
        let siteKey: String
        let path: String
    }

    let maximumPerDay: Int
    // Guarded by `lock`.
    private let lock = NSLock()
    private var day: PageViewDay?
    private var today: Set<Entry> = []
    private var yesterday: Set<Entry> = []

    init(maximumPerDay: Int) {
        self.maximumPerDay = max(1, maximumPerDay)
    }

    func insert(siteKey: String, path: String, day: PageViewDay) {
        lock.lock()
        defer { lock.unlock() }
        roll(to: day)
        guard today.count < maximumPerDay else { return }
        today.insert(Entry(siteKey: siteKey, path: path))
    }

    func contains(siteKey: String, path: String, day: PageViewDay) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        roll(to: day)
        let entry = Entry(siteKey: siteKey, path: path)
        return today.contains(entry) || yesterday.contains(entry)
    }

    // Called with `lock` held.
    private func roll(to newDay: PageViewDay) {
        guard let current = day else {
            day = newDay
            return
        }
        guard newDay > current else { return }
        yesterday = newDay.daysSince1970 == current.daysSince1970 + 1 ? today : []
        today = []
        day = newDay
    }
}

/// The beacon's body: whole seconds in view, a newline, the page's path.
/// Plain text, so `navigator.sendBeacon` sends it without a CORS preflight.
struct TimeOnPageBeacon: Equatable, Sendable {
    let seconds: Int
    let path: String

    /// A body longer than this is not a beacon.
    static let maximumBodyBytes = 1_024

    /// The reading in `body`, or `nil` when it is not one: no newline, a
    /// count that is not a plain non-negative integer, or a path that does
    /// not start with `/`. The seconds are capped at
    /// ``TimeOnPageBand/maximumSeconds`` and the query string dropped.
    static func parse(_ body: String) -> TimeOnPageBeacon? {
        guard body.utf8.count <= maximumBodyBytes,
              let newline = body.firstIndex(of: "\n")
        else { return nil }
        let count = body[..<newline]
        guard !count.isEmpty, count.count <= 7, count.allSatisfy({ $0.isASCII && $0.isNumber }),
              let seconds = Int(count)
        else { return nil }
        var path = String(body[body.index(after: newline)...])
        if let end = path.firstIndex(where: { $0 == "?" || $0 == "#" || $0 == "\n" || $0 == "\r" }) {
            path = String(path[..<end])
        }
        guard path.hasPrefix("/") else { return nil }
        return TimeOnPageBeacon(seconds: min(seconds, TimeOnPageBand.maximumSeconds),
                                path: BotRequestClassifier.collapsingRepeatedSlashes(path))
    }
}

/// The script a site includes to report time on page.
enum TimeOnPageScript {
    /// Adds up the milliseconds the page is visible and, the first time it is
    /// hidden (the reader switched tabs, left or closed it), posts the whole
    /// seconds and `location.pathname` once. A page that was never visible
    /// sends nothing. No storage, no cookie, no identifier.
    static func source(beaconPath: String) -> String {
        // The path is validated to unreserved characters and slashes, so it
        // is safe inside a JavaScript string literal.
        """
        (function(){"use strict";
        if(!navigator.sendBeacon)return;
        var shown=0,since=null,seen=false,sent=false;
        function start(){if(since===null){since=Date.now();seen=true;}}
        function stop(){if(since!==null){shown+=Date.now()-since;since=null;}}
        function send(){stop();if(sent||!seen)return;sent=true;
        try{navigator.sendBeacon("\(beaconPath)",Math.round(shown/1000)+"\\n"+location.pathname);}catch(e){}}
        if(document.visibilityState==="visible")start();
        document.addEventListener("visibilitychange",function(){
        if(document.visibilityState==="hidden")send();else if(!sent)start();});
        window.addEventListener("pagehide",send);
        })();

        """
    }
}

/// Serves the script and takes its beacons.
///
/// - `GET  <path>.js`: the script, cacheable for an hour.
/// - `POST <path>`: a reading. Always `204`, kept or not, so the endpoint
///   says nothing about what it accepted.
///
/// A reading is kept when the request reads as a person's browser (the same
/// user agent test page views use), is not cross-site, parses, and names a
/// page ``KnownPagePaths`` has seen. Nothing from the request is kept beyond
/// the site key, the path and the band.
struct TimeOnPageController: RouteCollection {
    let configuration: BotKitConfiguration.PageViews.TimeOnPage
    let counter: PageViewCounter
    let agents: AIAgentMatcher
    let siteKey: @Sendable (Request) -> String

    func boot(routes: RoutesBuilder) throws {
        let components = configuration.pathComponents
        let parent = routes.grouped(components.dropLast().map { PathComponent.constant($0) })
        let last = components.last!
        let script = TimeOnPageScript.source(beaconPath: configuration.normalizedPath)
        parent.get(.constant(last + ".js")) { _ -> Response in
            let response = Response(status: .ok, body: .init(string: script))
            response.headers.replaceOrAdd(name: .contentType, value: "text/javascript; charset=utf-8")
            response.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=3600")
            response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
            return response
        }
        parent.on(.POST, .constant(last), body: .collect(maxSize: ByteCount(integerLiteral: TimeOnPageBeacon.maximumBodyBytes))) { req -> Response in
            record(req)
            let response = Response(status: .noContent)
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return response
        }
    }

    private func record(_ req: Request) {
        guard PageViewFilter.isBrowser(userAgent: req.headers.first(name: .userAgent), agents: agents),
              !BotDashboardController.isCrossSite(req.headers),
              let body = req.body.string,
              let beacon = TimeOnPageBeacon.parse(body)
        else { return }
        counter.recordTimeOnPage(siteKey: siteKey(req), path: beacon.path, seconds: beacon.seconds)
    }
}
