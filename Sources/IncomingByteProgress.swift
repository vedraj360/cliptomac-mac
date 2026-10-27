import Foundation

/// Tracks socket bytes separately from durable bucket receipts. Never persists tokens or partial progress.
final class IncomingByteProgress: @unchecked Sendable {
    static let shared = IncomingByteProgress()
    private struct Entry {
        let owner: String
        let manifest: TransferManifest
        var confirmed: Set<Int>
        var partial: [Int: Int] = [:]
        var lastPublish = 0.0
        let publish: (Int64) -> Void
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func register(owner: String, token: String, manifest: TransferManifest, received: [Int], publish: @escaping (Int64) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if entries.count >= 32, let first = entries.keys.first { entries.removeValue(forKey: first) }
        entries[token + ":" + manifest.transferId] = Entry(owner: owner, manifest: manifest, confirmed: Set(received), publish: publish)
    }
    func reader(token: String, path: String, length: Int) -> ((Int) -> Void)? {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "buckets", let index = Int(parts[2]) else { return nil }
        let key = token + ":" + parts[1]
        lock.lock()
        let valid = entries[key].map { (try? $0.manifest.length(index)) == length } ?? false
        lock.unlock()
        guard valid else { return nil }
        return { count in
            self.lock.lock()
            guard var entry = self.entries[key] else { self.lock.unlock(); return }
            entry.partial[index] = max(entry.partial[index] ?? 0, min(length, count))
            let now = ProcessInfo.processInfo.systemUptime
            let emit = now - entry.lastPublish >= 0.2 || count == length
            if emit { entry.lastPublish = now }
            let indices = entry.confirmed.union(entry.partial.keys)
            let bytes = indices.reduce(Int64(0)) { sum, bucket in
                sum + Int64(entry.confirmed.contains(bucket) ? ((try? entry.manifest.length(bucket)) ?? 0) : (entry.partial[bucket] ?? 0))
            }
            self.entries[key] = entry
            self.lock.unlock()
            if emit { entry.publish(min(entry.manifest.size, bytes)) }
        }
    }
    func confirmed(token: String, id: String, index: Int) {
        lock.lock(); defer { lock.unlock() }
        let key = token + ":" + id
        entries[key]?.confirmed.insert(index)
        entries[key]?.partial.removeValue(forKey: index)
    }
    func finish(owner: String, id: String) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { !($0.value.owner == owner && $0.value.manifest.transferId == id) }
    }
}
