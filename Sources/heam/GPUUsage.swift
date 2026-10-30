import Foundation
import IOKit

/// Per-process GPU time, read from the Metal clients each app opens on the GPU.
/// Every client lists its accumulated GPU time; no special rights are needed.
enum GPUUsage {
    /// Total GPU nanoseconds per pid since each client opened.
    static func timeByPID() -> [pid_t: UInt64] {
        var result: [pid_t: UInt64] = [:]
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &accelerators) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(accelerators) }

        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            var clients: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS {
                var client = IOIteratorNext(clients)
                while client != 0 {
                    if let pid = creatorPID(client) {
                        result[pid, default: 0] &+= accumulatedTime(client)
                    }
                    IOObjectRelease(client)
                    client = IOIteratorNext(clients)
                }
                IOObjectRelease(clients)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        return result
    }

    /// "IOUserClientCreator" reads like "pid 414, WindowServer".
    private static func creatorPID(_ entry: io_registry_entry_t) -> pid_t? {
        guard let value = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              value.hasPrefix("pid ") else { return nil }
        return pid_t(value.dropFirst(4).prefix { $0.isNumber })
    }

    private static func accumulatedTime(_ entry: io_registry_entry_t) -> UInt64 {
        guard let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]]
        else { return 0 }
        return usage.reduce(0) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
    }
}
