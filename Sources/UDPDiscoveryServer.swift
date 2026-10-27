import Foundation

public class UDPDiscoveryServer {
    public static let shared = UDPDiscoveryServer()
    private var socketFd: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.vdx.cliptomac.udp", qos: .utility)
    
    public func start(port: Int = 5679) {
        guard !isRunning else { return }
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            self.socketFd = socket(AF_INET, SOCK_DGRAM, 0)
            guard self.socketFd >= 0 else {
                print("Failed to create UDP socket")
                return
            }
            
            var opt: Int32 = 1
            setsockopt(self.socketFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(self.socketFd, SOL_SOCKET, SO_BROADCAST, &opt, socklen_t(MemoryLayout<Int32>.size))
            
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY
            
            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(self.socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            
            guard bindRes == 0 else {
                print("Failed to bind UDP socket on port \(port): errno \(errno)")
                close(self.socketFd)
                return
            }
            
            self.isRunning = true
            print("UDP Discovery Server listening on port \(port)")
            
            var buffer = [UInt8](repeating: 0, count: 2048)
            while self.isRunning {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                
                let bytesRead = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(self.socketFd, &buffer, buffer.count - 1, 0, $0, &clientLen)
                    }
                }
                
                guard bytesRead > 0 else { continue }
                let message = String(decoding: buffer[0..<bytesRead], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                
                if message == "DISCOVER_CLIP_TO_MAC" {
                    self.sendDiscoveryResponse(clientAddr: clientAddr, clientLen: clientLen)
                }
            }
        }
    }
    
    public func stop() {
        isRunning = false
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
    }
    
    private func sendDiscoveryResponse(clientAddr: sockaddr_in, clientLen: socklen_t) {
        let hostName = Host.current().localizedName ?? "MacBook"
        
        Task { @MainActor in
            let store = ClipStore.shared
            let isPaired = store.hasPairedDevice
            
            let metadata: [String: Any] = ["service": "ClipToMac", "device": hostName, "port": store.port, "macIp": store.localIP, "isPaired": isPaired]
            if let data = try? JSONSerialization.data(withJSONObject: metadata) {
                var addrCopy = clientAddr
                withUnsafePointer(to: &addrCopy) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        data.withUnsafeBytes { dataBytes in
                            _ = sendto(self.socketFd, dataBytes.baseAddress, data.count, 0, sockPtr, clientLen)
                        }
                    }
                }
            }
        }
    }
}
