import CHeam
import Foundation

struct Sensor: Identifiable, Hashable {
    let name: String
    let celsius: Double
    var id: String { name }
}

enum Sensors {
    private static let maxSensors = 256

    /// All temperature sensors with a plausible reading, sorted hottest first.
    static func read() -> [Sensor] {
        var values = [Double](repeating: 0, count: maxSensors)
        var names = [CChar](repeating: 0, count: maxSensors * Int(HEAM_NAME_LEN))
        let count = Int(heam_read_temps(&values, &names, Int32(maxSensors)))

        var seen = Set<String>()
        var result: [Sensor] = []
        for i in 0..<count {
            let v = values[i]
            guard v > 5, v < 130 else { continue } // drop disconnected/garbage sensors
            let start = i * Int(HEAM_NAME_LEN)
            var name = names[start..<start + Int(HEAM_NAME_LEN)].withUnsafeBufferPointer {
                String(cString: $0.baseAddress!)
            }
            if name.isEmpty { name = "Sensor \(i)" }
            // Several sensors can share a product name; keep them distinct.
            var unique = name, n = 2
            while seen.contains(unique) { unique = "\(name) #\(n)"; n += 1 }
            seen.insert(unique)
            result.append(Sensor(name: unique, celsius: v))
        }
        return result.sorted { $0.celsius > $1.celsius }
    }
}
