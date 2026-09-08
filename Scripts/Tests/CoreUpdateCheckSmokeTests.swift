// Production check methods use URLProtocol-backed HTTPS fixtures, never network.
import Foundation
import OSLog

extension Logger {
    static let download = Logger(subsystem: "org.openemu.tests.CoreUpdateChecks", category: "fixture")
}

final class CoreDownload: NSObject {
    var bundleIdentifier = ""
    var name = ""
    var version = ""
    var systemIdentifiers: [String] = []
    var systemNames: [String] = []
    var requiresRestart = false
    var hasActiveInstallation = false
    var hasUpdate = false
    var canBeInstalled = false
    var appcastItem: CoreAppcastItem?
    weak var delegate: CoreUpdater?
    var starts = 0
    func start() { starts += 1; hasActiveInstallation = true }
}

final class CoreUpdater: NSObject {
    static var coreListURL: URL? { OECoreUpdateSecurity.catalogURL() }
    var coreDownload: CoreDownload?
    var coresDict: [String: CoreDownload] = [:]
    var coreList: [CoreDownload] = []
    var autoInstall = false
    var lastCoreListURLTask: URLSessionDataTask?
    var pendingCoreListCompletionHandlers: [(Error?) -> Void] = []
    var coreListCheckID: UUID?
    func updateCoreList() { coreList = Array(coresDict.values) }
}

extension URLSession {
    static let oeShared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        return URLSession(configuration: configuration)
    }()
}

final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [FixtureProtocol] = []
    static private(set) var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(self)
        Self.count += 1
        Self.lock.unlock()
    }
    override func stopLoading() { }

    static func pending(_ component: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.request.url!.lastPathComponent == component }.count
    }

    static func reply(_ component: String, body: Data = Data(), status: Int = 200, finalURL: URL? = nil) {
        lock.lock()
        guard let index = requests.firstIndex(where: { $0.request.url!.lastPathComponent == component }) else {
            lock.unlock()
            preconditionFailure("No pending fixture request: \(component)")
        }
        let task = requests.remove(at: index)
        lock.unlock()
        let response = HTTPURLResponse(url: finalURL ?? task.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        task.client?.urlProtocol(task, didReceive: response, cacheStoragePolicy: .notAllowed)
        task.client?.urlProtocol(task, didLoad: body)
        task.client?.urlProtocolDidFinishLoading(task)
    }
}

@main
enum CoreUpdateCheckSmokeTests {
    static let architecture = OECoreUpdateSecurity.runningArchitecture
    static var directory: String { "https://updates.example.test/\(architecture)/" }
    static func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func wait(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(4)
        while !condition() && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        require(condition(), "Fixture callback timed out")
    }

    static func catalog(_ identifiers: [String]) -> Data {
        let nodes = identifiers.map {
            "<core id=\"\($0)\" name=\"\($0)\" appcastURL=\"\(directory)\($0).xml\"><systems><system id=\"openemu.system.test\">Test</system></systems></core>"
        }.joined()
        return Data("<cores architecture=\"\(architecture)\">\(nodes)</cores>".utf8)
    }

    static func feed(_ versions: [String]) -> Data {
        let signature = Data(repeating: 0, count: 64).base64EncodedString()
        let nodes = versions.map {
            "<item><sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion><sparkle:hardwareRequirements>\(architecture)</sparkle:hardwareRequirements><enclosure url=\"https://downloads.example.test/core.zip\" sparkle:version=\"\($0)\" sparkle:edSignature=\"\(signature)\" length=\"4096\"/></item>"
        }.joined()
        return Data("<rss xmlns:sparkle=\"\(OECoreUpdateSecurity.sparkleNamespace)\"><channel>\(nodes)</channel></rss>".utf8)
    }

    static func newCore(_ id: String, version: String = "1.0") -> CoreDownload {
        let core = CoreDownload()
        core.bundleIdentifier = id
        core.name = id
        core.version = version
        return core
    }

    static func main() throws {
        let updater = CoreUpdater()
        let idle = newCore("idle")
        let busy = newCore("busy")
        let restarting = newCore("restarting")
        let removed = newCore("removed")
        let oldOffer = try CoreAppcastItem.parse(feed(["9.0"]), publicKey: String(repeating: "A", count: 43) + "=").first!
        for core in [idle, busy, restarting, removed] {
            core.hasUpdate = true
            core.appcastItem = oldOffer
            updater.coresDict[core.bundleIdentifier] = core
        }
        busy.hasActiveInstallation = true
        restarting.requiresRestart = true
        var completions: [Error?] = []
        updater.checkForNewCores { completions.append($0) }
        updater.checkForNewCores { completions.append($0) }
        require(idle.appcastItem == nil && !idle.hasUpdate && removed.appcastItem == nil, "Stale offers survived a new check")
        require(busy.appcastItem?.version == "9.0" && restarting.appcastItem?.version == "9.0", "Active or restart-pending state was changed")
        wait { FixtureProtocol.pending("catalog.xml") == 1 }
        FixtureProtocol.reply("catalog.xml", body: catalog(["idle", "busy", "restarting", "new"]))
        wait { FixtureProtocol.pending("idle.xml") == 1 && FixtureProtocol.pending("new.xml") == 1 }
        require(FixtureProtocol.pending("busy.xml") == 0 && FixtureProtocol.pending("restarting.xml") == 0, "Busy core received another feed check")
        FixtureProtocol.reply("idle.xml", body: feed(["2.0", "10.0", "1.0"]))
        wait { idle.hasUpdate }
        require(completions.isEmpty, "Completion ran before every feed finished")
        require(idle.appcastItem?.version == "10.0", "Highest compatible version was not selected")
        FixtureProtocol.reply("new.xml", status: 503)
        wait { completions.count == 2 }
        require(completions.allSatisfy { $0 != nil }, "A failed feed was reported as success")
        require(updater.coreListCheckID == nil, "Completed check stayed active")
        print("PASS: concurrent checks coalesce, wait for all feeds, preserve busy cores and report failures")

        completions.removeAll()
        updater.checkForNewCores { completions.append($0) }
        require(!idle.hasUpdate && idle.appcastItem == nil, "Failed check retained an old offer")
        wait { FixtureProtocol.pending("catalog.xml") == 1 }
        FixtureProtocol.reply("catalog.xml", body: catalog(["idle"]))
        wait { FixtureProtocol.pending("idle.xml") == 1 }
        FixtureProtocol.reply("idle.xml", body: feed(["0.9", "1.0"]))
        wait { completions.count == 1 }
        require(!idle.hasUpdate && idle.appcastItem == nil && idle.starts == 0, "Old signed release remained installable")
        print("PASS: equal/older releases and withdrawn entries cannot become stale installation offers")

        completions.removeAll()
        updater.checkForNewCores { completions.append($0) }
        wait { FixtureProtocol.pending("catalog.xml") == 1 }
        FixtureProtocol.reply("catalog.xml", body: catalog(["idle"]))
        wait { FixtureProtocol.pending("idle.xml") == 1 }
        updater.cancelCheckForNewCores()
        require(completions.count == 1 && (completions[0] as? URLError)?.code == .cancelled, "Cancellation did not finish once")
        updater.checkForNewCores { completions.append($0) }
        wait { FixtureProtocol.pending("catalog.xml") == 1 }
        FixtureProtocol.reply("idle.xml", body: feed(["99.0"]))
        FixtureProtocol.reply("catalog.xml", body: catalog(["idle"]))
        wait { FixtureProtocol.pending("idle.xml") == 1 }
        FixtureProtocol.reply("idle.xml", body: feed(["2.0"]))
        wait { completions.count == 2 }
        require(idle.appcastItem?.version == "2.0", "Cancelled result overwrote a newer check")
        print("PASS: late cancelled callbacks cannot mutate the next check or call its handlers")

        for redirectCatalog in [true, false] {
            completions.removeAll()
            updater.checkForNewCores { completions.append($0) }
            wait { FixtureProtocol.pending("catalog.xml") == 1 }
            if redirectCatalog {
                FixtureProtocol.reply("catalog.xml", body: catalog(["idle"]), finalURL: URL(string: "https://evil.example.test/catalog.xml")!)
            } else {
                FixtureProtocol.reply("catalog.xml", body: catalog(["idle"]))
                wait { FixtureProtocol.pending("idle.xml") == 1 }
                FixtureProtocol.reply("idle.xml", body: feed(["999.0"]), finalURL: URL(string: "https://evil.example.test/idle.xml")!)
            }
            wait { completions.count == 1 }
            require(completions[0] != nil && !idle.hasUpdate && idle.appcastItem == nil, "Untrusted redirected response created an offer")
        }
        print("PASS: catalog and feed redirects outside the pinned family are rejected")

        updater.checkForNewCores()
        wait { FixtureProtocol.pending("catalog.xml") == 1 }
        FixtureProtocol.reply("catalog.xml", body: catalog(["idle", "unselected"]))
        wait { FixtureProtocol.pending("idle.xml") == 1 && FixtureProtocol.pending("unselected.xml") == 1 }
        FixtureProtocol.reply("idle.xml", body: feed(["2.0"]))
        FixtureProtocol.reply("unselected.xml", body: feed(["3.0"]))
        wait { updater.coreListCheckID == nil }
        let unselected = updater.coresDict["unselected"]!
        require(unselected.canBeInstalled && unselected.starts == 0 && !unselected.hasUpdate,
                "Discovering a missing core installed it without a user choice")

        updater.checkForUpdatesAndInstall()
        wait { FixtureProtocol.pending("catalog.xml") == 1 }
        FixtureProtocol.reply("catalog.xml", body: catalog(["idle", "unselected"]))
        wait { FixtureProtocol.pending("idle.xml") == 1 && FixtureProtocol.pending("unselected.xml") == 1 }
        FixtureProtocol.reply("idle.xml", body: feed(["3.0"]))
        FixtureProtocol.reply("unselected.xml", body: feed(["4.0"]))
        wait { updater.coreListCheckID == nil }
        require(idle.starts == 1 && idle.appcastItem?.version == "3.0", "Valid newer update did not start exactly once")
        require(unselected.starts == 0 && unselected.canBeInstalled && !unselected.hasUpdate && unselected.appcastItem?.version == "4.0",
                "Second automatic check installed a previously unselected missing core")
        require(FixtureProtocol.pending("catalog.xml") == 0, "Update completion started a duplicate check")
        print("PASS: automatic checks start a valid update once without a second catalog request")
        print("PASS: a second automatic check refreshes missing-core choices without silently installing them")
    }
}
