import Foundation
import Network
import Security
import Darwin

/// TLS is terminated by Network.framework. Plain HTTP exists only in an AF_UNIX socketpair,
/// letting the bounded transfer parser remain shared with its isolated protocol tests.
final class TLSSocketBridge: @unchecked Sendable {
    private let connection: NWConnection
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.vdx.cliptomac.tls.bridge")
    private let lock = NSLock()
    private var stopped = false
    private let finished: () -> Void
    init(connection: NWConnection, fd: Int32, finished: @escaping () -> Void) {
        self.connection = connection; self.fd = fd; self.finished = finished
        var timeout = timeval(tv_sec: 70, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout.tv_sec = 20
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var enabled: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
    deinit { close(fd) }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state { case .ready: self.receive(); self.sendResponses()
            case .failed, .cancelled: self.stop()
            default: break }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }; if self.connection.state != .ready { self.stop() }
        }
    }
    func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; lock.unlock()
        shutdown(fd, SHUT_RDWR); connection.cancel(); finished()
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private func receive() {
        guard !isStopped else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            guard !self.isStopped else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                if let data, !data.isEmpty {
                    let ok = data.withUnsafeBytes { bytes -> Bool in
                        var offset = 0
                        while offset < bytes.count {
                            let count = Darwin.send(self.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                            if count < 0 && errno == EINTR { continue }; if count <= 0 { return false }; offset += count
                        }; return true
                    }
                    if !ok { self.stop(); return }
                }
                if error != nil { self.stop() }
                else if complete { shutdown(self.fd, SHUT_WR) }
                else { self.receive() }
            }
        }
    }
    private func sendResponses() {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.stop() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !self.isStopped {
                let count = recv(self.fd, &buffer, buffer.count, 0)
                if count < 0 && errno == EINTR { continue }; guard count > 0 else { break }
                let sent = DispatchSemaphore(value: 0)
                self.connection.send(content: Data(buffer.prefix(count)), completion: .contentProcessed { error in
                    if error != nil { self.stop() }; sent.signal()
                })
                guard sent.wait(timeout: .now() + 20) == .success else { break }
            }
        }
    }
}
