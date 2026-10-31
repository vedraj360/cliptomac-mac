import Foundation

/// Wire values shared by the Mac pairing and HTTP transfer implementation.
enum ClipToMacProtocol {
    static let serviceName = "ClipToMac"
    static let transferVersion = 2
    static let securePairingVersion = 3
    static let maxTransferIdentifierLength = 128
    static let sha256HexLength = 64

    static func isValidTransferIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maxTransferIdentifierLength else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) || byte == 45 || byte == 95
        }
    }

    static func isPairingCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 6 && bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == sha256HexLength else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    enum HTTP {
        static let maximumBodyBytes = 25 * 1024 * 1024
        static let pairingRequestBodyLimit = 4 * 1024
        static let notificationRelayBodyLimit = 64 * 1024
        static let maximumHeaderBytes = 32 * 1024
        static let requestDeadlineSeconds: TimeInterval = 30
        static let clientSocketTimeoutSeconds: Int = 15
        static let maximumConcurrentConnections = 6
        static let testListenerBacklog: Int32 = 15

        enum Method {
            static let get = "GET"
            static let post = "POST"
            static let put = "PUT"
            static let delete = "DELETE"
            static let options = "OPTIONS"
        }

        enum Header {
            static let contentLength = "content-length"
            static let transferEncoding = "transfer-encoding"
            static let origin = "origin"
            static let fetchSite = "sec-fetch-site"
            static let authenticationToken = "x-cliptomac-token"
            static let transferMetadata = "x-cliptomac-metadata"
            static let bucketChecksum = "x-bucket-sha256"
        }

        enum Path {
            static let root = "/"
            static let ping = "/ping"
            static let pairRequest = "/pair/request"
            static let pairIdentity = "/pair/identity"
            static let pairUnpair = "/pair/unpair"
            static let notificationRelay = "/notifications/relay"
            static let notificationReplyWait = "/notifications/reply/wait"
            static let transfer = "/transfer"
            static let inbox = "/inbox"
            static let inboxWait = "/inbox/wait"
            static let inboxAck = "/inbox/ack"
            static let clip = "/clip"
            static let clipBatch = "/clip/batch"
            static let downloadPrefix = "/download/"
            static let bucketsPrefix = "/buckets/"
            static let bucketStart = "/buckets/start"
            static let bucketDownloadSegment = "download"
            static let bucketControlSegment = "control"
            static let bucketCompleteSegment = "complete"
            static let bucketManifestSegment = "manifest"
        }

        static func bodyLimit(for path: String) -> Int {
            switch path {
            case Path.pairRequest:
                return pairingRequestBodyLimit
            case Path.notificationRelay:
                return notificationRelayBodyLimit
            default:
                return path.hasPrefix(Path.bucketsPrefix) ? TransferManifest.bucketBytes : maximumBodyBytes
            }
        }
    }
}
