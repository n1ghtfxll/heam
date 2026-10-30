import CHeam
import Foundation

/// Typed wrapper over the raw AppleSMC calls.
enum SMC {
    static func read(_ key: String) -> (bytes: [UInt8], type: String)? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var type = [CChar](repeating: 0, count: 5)
        guard heam_smc_read(key, &bytes, &size, &type) == 0 else { return nil }
        return (Array(bytes.prefix(Int(size))), String(cString: type))
    }

    static func number(_ key: String) -> Double? {
        guard let (b, type) = read(key) else { return nil }
        switch type {
        case "flt " where b.count >= 4:
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case "fpe2" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4
        case "ui8 " where b.count >= 1:
            return Double(b[0])
        case "ui16" where b.count >= 2:
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4:
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        default:
            return nil
        }
    }

    /// Writes `value` encoded in whatever type the key declares. Needs root.
    @discardableResult
    static func write(_ key: String, _ value: Double) -> Bool {
        guard let (_, type) = read(key) else { return false }
        let bytes: [UInt8]
        switch type {
        case "flt ":
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24)]
        case "fpe2":
            let raw = UInt16(max(0, min(value * 4, 65535)))
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8 ":
            bytes = [UInt8(max(0, min(value, 255)))]
        default:
            return false
        }
        return heam_smc_write(key, bytes, UInt32(bytes.count)) == 0
    }

    static func exists(_ key: String) -> Bool { read(key) != nil }
}
