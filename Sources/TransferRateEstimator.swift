import Foundation

/// Monotonic time and smoothed rates; independent of network and disk storage.
struct TransferRateEstimator {
    private var samples: [String: (time: TimeInterval, bytes: Int64, rate: Double)] = [:]
    mutating func reset(_ id: String) { samples.removeValue(forKey: id) }
    mutating func sample(_ id: String, bytes: Int64, total: Int64) -> (Double, Double?) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let previous = samples[id], bytes >= previous.bytes else { samples[id] = (now, bytes, 0); return (0, nil) }
        let elapsed = now - previous.time
        guard elapsed >= 0.3 else { return (previous.rate, previous.rate > 0 ? Double(max(0, total - bytes)) / previous.rate : nil) }
        let current = Double(bytes - previous.bytes) / elapsed
        let rate = previous.rate == 0 ? current : previous.rate * 0.6 + current * 0.4
        samples[id] = (now, bytes, rate)
        return (rate, rate > 0 ? Double(max(0, total - bytes)) / rate : nil)
    }
}
