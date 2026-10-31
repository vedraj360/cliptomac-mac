import Foundation

/// User-safe transfer failures shared by storage, validation, and HTTP responses.
enum TransferErrors {
  static let invalidTransferIdentifier = "Invalid transfer ID"
  static let transferIdentifierConflict = "Transfer ID already belongs to different content"
  static let insufficientStorage = "Not enough storage on Mac"
  static let bucketChecksumMismatch = "Bucket checksum mismatch"
  static let invalidBucketLength = "Incorrect bucket length"
  static let conflictingBucketRetry = "Conflicting bucket retry"
  static let transferAlreadyFinalized = "Transfer already finalized"
  static let completedFileUnavailable = "Completed file is no longer available"
  static let missingBuckets = "Missing buckets"
  static let completeFileChecksumMismatch = "Complete file checksum mismatch; retry transfer"
  static let invalidManifest = "Invalid transfer manifest"
  static let invalidBucketIndex = "Invalid bucket index"
  static let sourceFileUnavailable = "Source file changed or is unavailable"
  static let sourceChangedWhilePreparing = "Source changed while preparing transfer"
  static let pairedDeviceUnavailable = "Paired device is no longer available"
  static let invalidTransferSize = "Invalid transfer size"
  static let transferPaused = "Paused on Mac"
  static let transferCancelled = "Cancelled on Mac"
}
