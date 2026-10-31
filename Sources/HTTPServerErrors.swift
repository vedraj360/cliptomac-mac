import Foundation

/// Client-visible protocol failures are centralized here so routes stay declarative.
enum HTTPServerErrors {
  static let tlsServerStartFailed =
    "Secure server could not start. Unlock your Keychain and restart ClipToMac."
  static let tlsListenerFailed =
    "Secure server could not listen on this port. Restart ClipToMac after closing other copies."
  static let invalidRequest = "Invalid or incomplete request"
  static let browserRequestsForbidden = "Browser requests are not allowed"
  static let securePairingRequired = "Secure pairing required or device revoked"
  static let deviceNotPairedOrTokenInvalid = "Device not paired or invalid token"
  static let invalidJSON = "Invalid JSON"
  static let invalidPairingDetails = "Invalid pairing details"
  static let freshPairingQRRequired = "Open a fresh pairing QR on your Mac and scan it again."
  static let pairingRateLimited = "Too many pairing requests. Try again shortly."
  static let credentialGenerationFailed = "Could not generate credentials"
  static let pairingPersistenceFailed = "Could not securely save pairing"
  static let pairingDeclined = "Pairing declined by user"
  static let invalidNotificationPayload = "Invalid notification payload"
  static let notificationRateLimited = "Notification relay rate limit reached"
  static let notificationReplyWaitersLimited = "Too many notification reply waiters"
  static let deviceIdentityUpdateFailed = "Device identity could not be updated"
  static let unpairPersistenceFailed = "Could not save unpairing"
  static let invalidTransfer = "Invalid transfer"
  static let inboxWaitersLimited = "Too many waiting requests"
  static let deviceNoLongerPaired = "Device no longer paired"
  static let inboxUnavailable = "Inbox unavailable"
  static let transferUnavailable = "Transfer unavailable"
  static let invalidAcknowledgement = "Invalid acknowledgement"
  static let invalidPayload = "Invalid payload"
  static let notFound = "Not Found"
  static let invalidTransferIdentifier = TransferErrors.invalidTransferIdentifier
  static let invalidManifest = "Invalid manifest"
  static let invalidBucketIndex = TransferErrors.invalidBucketIndex
  static let bucketTransferUnavailable = "Bucket transfer unavailable"
}
