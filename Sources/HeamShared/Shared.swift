import Foundation

/// Files the app writes and the (sandboxed) widget reads.
public enum SharedFiles {
    /// The real home folder; inside the widget's sandbox `homeDirectoryForCurrentUser` points at its container.
    public static let home: URL = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    public static let directory: URL = {
        let dir = home.appendingPathComponent("Library/Application Support/heam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    public static let history = directory.appendingPathComponent("history.json")
    public static let snapshot = directory.appendingPathComponent("snapshot.json")
}

/// Latest reading, written by the app for the widget.
public struct Snapshot: Codable {
    public var date: Date
    public var temp: Double
    public var chip: Double?
    public var watts: Double?
    public var fahrenheit: Bool
    public var topApps: [TopApp]
    public var history: [Double]

    public struct TopApp: Codable {
        public var name: String
        public var bundlePath: String?
        public var degrees: Double

        public init(name: String, bundlePath: String?, degrees: Double) {
            self.name = name
            self.bundlePath = bundlePath
            self.degrees = degrees
        }
    }

    public init(date: Date, temp: Double, chip: Double?, watts: Double?, fahrenheit: Bool,
                topApps: [TopApp], history: [Double]) {
        self.date = date
        self.temp = temp
        self.chip = chip
        self.watts = watts
        self.fahrenheit = fahrenheit
        self.topApps = topApps
        self.history = history
    }

    public static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: SharedFiles.snapshot) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) { try? data.write(to: SharedFiles.snapshot, options: .atomic) }
    }

    public func format(_ celsius: Double?) -> String {
        guard let c = celsius else { return "--°" }
        return String(format: "%.0f°", fahrenheit ? c * 9 / 5 + 32 : c)
    }
}
