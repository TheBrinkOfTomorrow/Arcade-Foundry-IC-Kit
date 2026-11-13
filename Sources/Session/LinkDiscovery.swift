import Foundation
import Network

/// Link play's cabinets on the local network, so the next cabinet is
/// picked by name instead of typed as host:port. Every running Arcade
/// Foundry: Insert Coin advertises itself over Bonjour (_arcadefoundry._tcp) with its cabinet
/// ID, name and each linkable game's port, and browses for the others.
/// The advertising listener only exists to be found: it takes no
/// connections (the cores link over their own sockets).
final class LinkDiscovery: ObservableObject {
    static let shared = LinkDiscovery()
    static let type = "_arcadefoundry._tcp"

    struct Peer: Identifiable, Hashable {
        let id: String // the cabinet ID
        let name: String
        let ports: [String: Int] // romset: link port
        let endpoint: NWEndpoint
    }

    @Published private(set) var peers: [Peer] = []
    private var listener: NWListener?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        advertise()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.type, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.peers = results.compactMap(Self.peer).sorted { $0.name < $1.name }
        }
        b.start(queue: .main)
        browser = b
    }

    /// Advertises this cabinet again (its name or a link port changed).
    func advertise() {
        listener?.cancel()
        var ports: [String] = []
        for game in GameInfo.all where game.link {
            ports.append("\(game.id):\(LinkSettings(romset: game.id).port)")
        }
        let txt = NWTXTRecord(["id": Cabinet.id, "name": Cabinet.name, "ports": ports.joined(separator: ",")])
        guard let l = try? NWListener(using: .tcp) else { return }
        l.service = NWListener.Service(name: Cabinet.name, type: Self.type, txtRecord: txt.data)
        l.newConnectionHandler = { $0.cancel() }
        l.start(queue: .main)
        listener = l
    }

    private static func peer(_ result: NWBrowser.Result) -> Peer? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        let d = txt.dictionary
        guard let id = d["id"], id != Cabinet.id else { return nil }
        var ports: [String: Int] = [:]
        for pair in (d["ports"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: ":")
            if kv.count == 2, let p = Int(kv[1]) { ports[String(kv[0])] = p }
        }
        return Peer(id: id, name: d["name"] ?? "Cabinet", ports: ports, endpoint: result.endpoint)
    }

    /// The peer's address for `romset`'s link, as host:port (IPv4), or nil
    /// when it cannot be reached within a few seconds.
    func address(of peer: Peer, romset: String) async -> String? {
        guard let port = peer.ports[romset] else { return nil }
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let c = NWConnection(to: peer.endpoint, using: params)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = Once()
            let finish: @Sendable (String?) -> Void = { s in
                guard once.claim() else { return }
                c.cancel()
                cont.resume(returning: s)
            }
            c.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _)? = c.currentPath?.remoteEndpoint, let h = Self.text(host) {
                        finish("\(h):\(port)")
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            c.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }

    /// The first claim wins (every caller runs on the main queue).
    private final class Once: @unchecked Sendable {
        private var done = false
        func claim() -> Bool {
            defer { done = true }
            return !done
        }
    }

    private static func text(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case .ipv4(let a): return "\(a)".split(separator: "%").first.map(String.init) // drop an interface suffix
        case .name(let n, _): return n
        default: return nil
        }
    }
}
