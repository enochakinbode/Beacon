import Foundation

/// Which slice of traffic a surface shows. `.internet` is the default: it's
/// what metered / hotspot users actually pay for. `.all` adds loopback, LAN,
/// AirDrop / peer-to-peer and multicast traffic back in.
enum TrafficScope: String, CaseIterable, Identifiable {
    case internet
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .internet: return "Internet"
        case .all:      return "All Traffic"
        }
    }
}

/// Pure classifier: does one nettop flow stay on this machine / local network,
/// or does it cross the internet? Kept free of state so it can be unit-tested
/// exhaustively, like `NettopLineParser`.
///
/// Signals, in order:
///   1. **Interface.** `lo*` is loopback; `awdl*` / `llw*` are AirDrop /
///      Continuity peer-to-peer links; `bridge*` / `anpi*` / `vmenet*` are
///      VM / host-only bridges. Traffic on these never reaches the internet.
///   2. **Remote address.** Loopback, RFC 1918 private, link-local, CGNAT /
///      Tailscale (100.64/10), multicast, broadcast, IPv6 ULA / link-local /
///      multicast are all local.
///   3. **Wildcard remote** (unconnected UDP, listeners): local when the local
///      side is a local address or a well-known LAN-discovery port (mDNS, SSDP,
///      NetBIOS, LLMNR); otherwise counted as internet.
///
/// Anything we can't positively identify as local counts as internet. Erring
/// that way means the "Internet" number may slightly over-report but never
/// hides real metered traffic.
enum TrafficClassifier {
    static func isLocal(interface: String, localIP: String, localPort: UInt16, remoteIP: String) -> Bool {
        if isLocalInterface(interface) { return true }
        if remoteIP == "*" || remoteIP.isEmpty {
            if lanDiscoveryPorts.contains(localPort) { return true }
            return localIP != "*" && isLocalAddress(localIP)
        }
        return isLocalAddress(remoteIP)
    }

    /// Interfaces whose traffic can't be internet traffic. `en*` / `utun*` /
    /// `pdp_ip*` are deliberately absent — they carry both kinds, so the
    /// remote address decides.
    static func isLocalInterface(_ name: String) -> Bool {
        let prefixes = ["lo", "awdl", "llw", "bridge", "anpi", "vmenet"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    /// mDNS / Bonjour, SSDP / UPnP, NetBIOS, LLMNR.
    private static let lanDiscoveryPorts: Set<UInt16> = [5353, 1900, 137, 138, 5355]

    /// True for any address that isn't routable on the public internet.
    static func isLocalAddress(_ raw: String) -> Bool {
        // nettop scopes link-local v6 addresses with the interface: "fe80::1%lo0".
        let ip = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
        if ip.contains(":") { return isLocalIPv6(ip) }
        return isLocalIPv4(ip)
    }

    private static func isLocalIPv4(_ ip: String) -> Bool {
        var addr = in_addr()
        guard inet_pton(AF_INET, ip, &addr) == 1 else { return false }
        let a = UInt32(bigEndian: addr.s_addr)
        let o1 = a >> 24, o2 = (a >> 16) & 0xFF
        switch o1 {
        case 0, 10, 127: return true                     // "this network", private, loopback
        case 100 where (64...127).contains(o2): return true  // CGNAT / Tailscale
        case 169 where o2 == 254: return true            // link-local
        case 172 where (16...31).contains(o2): return true   // private
        case 192 where o2 == 168: return true            // private
        case 224...255: return true                      // multicast, reserved, broadcast
        default: return false
        }
    }

    private static func isLocalIPv6(_ ip: String) -> Bool {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, ip, &addr) == 1 else { return false }
        let b = withUnsafeBytes(of: addr) { Array($0) }
        // ::ffff:a.b.c.d — IPv4-mapped; classify the embedded v4 address.
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
            return isLocalIPv4("\(b[12]).\(b[13]).\(b[14]).\(b[15])")
        }
        if b[0..<15].allSatisfy({ $0 == 0 }) && (b[15] == 1 || b[15] == 0) { return true } // ::1, ::
        if b[0] == 0xFF { return true }                    // ff00::/8 multicast
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true } // fe80::/10 link-local
        if (b[0] & 0xFE) == 0xFC { return true }           // fc00::/7 unique-local
        return false
    }
}
