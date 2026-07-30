import Darwin
import Foundation
import IOKit

/// Hardware and OS facts, read straight from sysctl and the IORegistry so the reporter
/// never has to shell out to `ioreg`, `scutil`, or `sw_vers`.
public enum SystemInfo {
    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = stringFromCBuffer(buffer)
        return value.isEmpty ? nil : value
    }

    /// The system hostname as `gethostname(2)` reports it.
    public static var hostname: String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else {
            return ProcessInfo.processInfo.hostName
        }
        let name = stringFromCBuffer(buffer)
        return name.isEmpty ? ProcessInfo.processInfo.hostName : name
    }

    /// Usually the Bonjour-style `something.local`, which is worth recording separately
    /// because it is what colleagues tend to type.
    public static var localHostname: String {
        ProcessInfo.processInfo.hostName
    }

    public static var model: String? {
        sysctlString("hw.model")
    }

    public static var osVersion: String {
        if let product = sysctlString("kern.osproductversion") { return product }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    public static var bootTime: Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        let seconds = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    public static var platformUUID: String? {
        platformExpertProperty(kIOPlatformUUIDKey)
    }

    public static var serialNumber: String? {
        platformExpertProperty(kIOPlatformSerialNumberKey)
    }

    /// Stable primary key for a machine. Prefers the hardware UUID, falls back through
    /// the serial to the hostname so a report is never dropped for lack of an identity.
    public static var machineID: String {
        platformUUID ?? serialNumber ?? hostname
    }

    private static func platformExpertProperty(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }
        let value = property.takeRetainedValue() as? String
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
