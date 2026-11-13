import AppKit
import Foundation

struct IslandModel: Codable, Equatable {
    var path: String
    var x: Float
    var y: Float
    var w: Float
    var h: Float
}

struct Ripple {
    var p: V2
    var t0: Float
    var strength: Float
}

struct Detach {
    var p: V2
    var r: Float
    var t0: Float
}

final class Island {
    let id: Int
    var path: String
    var rect: CGRect
    let color: V3
    var appear: Float = 0
    var appearV: Float = 0
    var glow: Float = 0
    var hover: Float = 0
    var ripples: [Ripple] = []
    var detaching: [Detach] = []
    var popT0: Float?
    var pop: Float = 0

    init(id: Int, path: String, rect: CGRect) {
        self.id = id
        self.path = path
        self.rect = rect
        color = Island.color(for: path)
    }

    var name: String { (path as NSString).lastPathComponent }

    static let headerHeight: CGFloat = 30

    func contains(_ p: V2) -> Bool {
        rect.contains(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)))
    }

    func inHeader(_ p: V2) -> Bool {
        contains(p) && CGFloat(p.y) < rect.minY + Island.headerHeight
    }

    func inCorner(_ p: V2) -> Bool {
        let dx = CGFloat(p.x) - rect.maxX, dy = CGFloat(p.y) - rect.maxY
        return dx > -22 && dx < 6 && dy > -22 && dy < 6
    }

    var model: IslandModel {
        IslandModel(path: path, x: Float(rect.minX), y: Float(rect.minY), w: Float(rect.width), h: Float(rect.height))
    }

    private static let palette: [V3] = [
        V3(0.35, 0.80, 0.95), V3(0.55, 0.90, 0.60), V3(0.95, 0.75, 0.40), V3(0.85, 0.55, 0.95),
        V3(0.95, 0.55, 0.60), V3(0.60, 0.70, 1.00), V3(0.40, 0.95, 0.80),
    ]

    static func color(for path: String) -> V3 {
        var h: UInt64 = 1469598103934665603
        for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return palette[Int(h % UInt64(palette.count))]
    }
}

enum DirectoryCandidates {
    private static var ghqCache: [String]?
    private static let lock = NSLock()

    static func ghq() -> [String] {
        lock.lock()
        if let c = ghqCache { lock.unlock(); return c }
        lock.unlock()
        let env = ShellEnvironment.load()
        guard let exe = ShellEnvironment.resolve("ghq", env: env) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["list", "-p"]
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let list = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).sorted {
            ($0 as NSString).lastPathComponent.lowercased() < ($1 as NSString).lastPathComponent.lowercased()
        }
        lock.lock()
        ghqCache = list
        lock.unlock()
        return list
    }

    static func prefetch() {
        DispatchQueue.global(qos: .utility).async { _ = ghq() }
    }
}
