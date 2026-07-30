#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

public enum NetworkScan {
    /// Interfaces that always carry addresses but never carry useful traffic:
    /// AirDrop, low-latency WLAN, Apple's internal NIC, and the iPhone-tethering AP.
    private static let noisyInterfacePrefixes = ["awdl", "llw", "anpi", "ap1"]

    /// Every usable address currently bound to the machine.
    ///
    /// Loopback, IPv4 link-local (169.254/16), IPv6 link-local (fe80::/10) and the noisy
    /// Apple-internal interfaces are dropped. VPN tunnels (`utun*`) are kept, since on a
    /// corporate network they are often the address that actually matters.
    public static func interfaceAddresses(includeNoisy: Bool = false) -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return [] }
        defer { freeifaddrs(head) }

        var results: [InterfaceAddress] = []
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let flags = Int32(bitPattern: entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }

            guard let socketAddress = entry.pointee.ifa_addr else { continue }
            let family = socketAddress.pointee.sa_family
            guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }

            let interface = String(cString: entry.pointee.ifa_name)
            if !includeNoisy, noisyInterfacePrefixes.contains(where: { interface.hasPrefix($0) }) { continue }

            guard let address = numericHost(socketAddress, length: addressLength(socketAddress)) else {
                continue
            }
            if address.hasPrefix("169.254.") { continue }
            if address.lowercased().hasPrefix("fe80") { continue }

            results.append(
                InterfaceAddress(
                    interface: interface,
                    address: address,
                    family: family == sa_family_t(AF_INET) ? .ipv4 : .ipv6
                )
            )
        }

        // Deterministic order: IPv4 before IPv6, then by interface name.
        return results.sorted { lhs, rhs in
            if lhs.family != rhs.family { return lhs.family == .ipv4 }
            if lhs.interface != rhs.interface { return lhs.interface < rhs.interface }
            return lhs.address < rhs.address
        }
    }

    /// The source address the kernel would pick to reach `host:port`.
    ///
    /// Connects a UDP socket, which performs a route lookup without putting a single packet
    /// on the wire, then reads back the bound local address. This is the number you want:
    /// it is chosen by the routing table rather than guessed from an interface list, so it
    /// stays correct across multihomed machines and split-tunnel VPNs.
    public static func sourceAddress(reaching host: String, port: UInt16) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = datagramSocketType
        hints.ai_protocol = Int32(IPPROTO_UDP)

        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }

        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let candidate = cursor {
            defer { cursor = candidate.pointee.ai_next }

            let descriptor = socket(candidate.pointee.ai_family, candidate.pointee.ai_socktype, candidate.pointee.ai_protocol)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }

            guard connect(descriptor, candidate.pointee.ai_addr, candidate.pointee.ai_addrlen) == 0 else { continue }

            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let bound = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    getsockname(descriptor, address, &length) == 0
                }
            }
            guard bound else { continue }

            let resolved = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    numericHost(address, length: length)
                }
            }
            if let resolved, !resolved.isEmpty { return resolved }
        }
        return nil
    }

    /// Presentation form of a socket address, with any IPv6 zone identifier stripped and
    /// IPv4-mapped IPv6 normalised back to plain IPv4.
    public static func numericHost(_ address: UnsafeMutablePointer<sockaddr>, length: socklen_t) -> String? {
        var host = [CChar](repeating: 0, count: 1025)
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        var text = stringFromCBuffer(host)
        if let zone = text.firstIndex(of: "%") {
            text = String(text[text.startIndex..<zone])
        }
        for prefix in ["::ffff:", "::FFFF:"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        return text.isEmpty ? nil : text
    }

    /// `sockaddr` carries its own length on BSD; on Linux it must be derived from the family.
    public static func addressLength(_ address: UnsafeMutablePointer<sockaddr>) -> socklen_t {
        #if canImport(Darwin)
        return socklen_t(address.pointee.sa_len)
        #else
        switch address.pointee.sa_family {
        case sa_family_t(AF_INET): return socklen_t(MemoryLayout<sockaddr_in>.size)
        case sa_family_t(AF_INET6): return socklen_t(MemoryLayout<sockaddr_in6>.size)
        default: return socklen_t(MemoryLayout<sockaddr_storage>.size)
        }
        #endif
    }

    /// Loopback and wildcard addresses are never worth publishing. This matters when the
    /// reporter runs on the collector's own machine: the route lookup correctly returns
    /// 127.0.0.1, which is useless to anyone reading the dashboard.
    public static func isUnroutable(_ address: String) -> Bool {
        if address.hasPrefix("127.") { return true }
        if address == "::1" || address == "0.0.0.0" || address == "::" { return true }
        return false
    }
}
