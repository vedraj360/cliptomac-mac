import Foundation
import AppKit

@main struct LibraryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipToMac-library-test-" + UUID().uuidString)
        let suite = "ClipToMac-library-test-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "autoCopy"); prefs.set(false, forKey: "showNotifications"); prefs.set(false, forKey: "playSound")
        defer { try? FileManager.default.removeItem(at: root); prefs.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldID = UUID()
        let legacy: [[String: Any]] = [["id":oldID.uuidString,"text":"old text","appName":"Brave","packageName":"com.brave.browser","timestamp":0]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: root.appendingPathComponent("history.json"))
        let store = ClipStore(storageDirectory: root, preferences: prefs, systemIntegration: false)
        precondition(store.clips.count == 1 && store.clips[0].kind == .text && store.clips[0].id == oldID, "legacy migration lost a clip")
        precondition(store.clips[0].sourceApp == .brave, "source app resolution failed")
        func receive(_ id: String, _ text: String) -> Bool { store.addTransferredItem(id:id,text:text,appName:"X",packageName:"com.twitter.android",timestamp:Date(),kind:"text",sourceDeviceId:"phone") }
        precondition(receive("attempt-1", " preserve spaces "))
        precondition(receive("attempt-1", " preserve spaces "))
        precondition(store.clips.count == 2 && store.clips[0].repeatCount == 1 && store.clips[0].text == " preserve spaces ", "retry duplicated or modified text")
        precondition(receive("attempt-2", " preserve spaces "))
        precondition(store.clips.count == 2 && store.clips[0].repeatCount == 2, "explicit repeat did not group")
        let id = store.clips[0].id
        store.togglePinned(ids:[id]); store.setCollection("Reading", ids:[id])
        store.removeClips(ids:[id]); precondition(store.seenTransferAttempt("attempt-2")); store.undoDelete()
        precondition(store.clips.first(where:{$0.id == id})?.isPinned == true)
        let media = root.appendingPathComponent("source.bin"); let payload=Data([0,1,2,255]); try payload.write(to:media)
        precondition(store.addTransferredItem(id:"file-1",text:"",appName:"Files",packageName:"files",timestamp:Date(),kind:"file",attachmentName:"file.bin",attachmentPath:media.path,sourceDeviceId:"phone"))
        let backup=root.appendingPathComponent("backup.json"); try store.exportBackup(to:backup)
        let restored=ClipStore(storageDirectory:root.appendingPathComponent("restored"),preferences:prefs,systemIntegration:false)
        try restored.importBackup(from:backup)
        precondition(restored.clips.count == 3)
        let attachment=restored.clips.first(where:{$0.kind == .file})!
        let restoredBytes = try Data(contentsOf:URL(fileURLWithPath:attachment.attachmentPath!)); precondition(restoredBytes == payload)
        precondition(restored.clips.first(where:{$0.id == id})?.collection == "Reading")
        let filesBeforeReimport = try FileManager.default.contentsOfDirectory(atPath: restored.attachmentDirectory.path).count
        try restored.importBackup(from:backup); precondition(restored.clips.count == 3, "backup reimport duplicated rows")
        let filesAfterReimport = try FileManager.default.contentsOfDirectory(atPath: restored.attachmentDirectory.path).count
        precondition(filesBeforeReimport == filesAfterReimport, "backup reimport copied duplicate attachments")
        let reloaded=ClipStore(storageDirectory:root,preferences:prefs,systemIntegration:false)
        precondition(reloaded.seenTransferAttempt("attempt-1") && reloaded.clips.count == 3)
        let localCopy = URL(fileURLWithPath: attachment.attachmentPath!)
        restored.removeClips(ids: [attachment.id], deleteFiles: true)
        restored.undoDelete()
        try await Task.sleep(nanoseconds: 10_300_000_000)
        precondition(FileManager.default.fileExists(atPath: localCopy.path), "Undo lost stored file")
        restored.removeClips(ids: [attachment.id], deleteFiles: true)
        try await Task.sleep(nanoseconds: 10_300_000_000)
        precondition(!FileManager.default.fileExists(atPath: localCopy.path), "Deleted history left its private file behind")
        precondition(FileManager.default.fileExists(atPath: media.path), "Original source was deleted")
        restored.saveTrustedDevice(id: "legacy", name: "Same model", token: "identity-token")
        precondition(restored.migrateDeviceIdentity(token: "identity-token", id: "android-1234567890abcdef"))
        restored.saveTrustedDevice(id: "android-1234567890abcdef", name: "Same model", token: "new-token")
        precondition(restored.pairedDevices.count == 1, "Re-pairing stable ID duplicated device")
        restored.saveTrustedDevice(id: "android-fedcba0987654321", name: "Same model", token: "second-phone")
        precondition(restored.pairedDevices.count == 2, "Different phones with same name were merged")
        print("PASS stored-file deletion: Undo protection, private-file removal, original kept; stable pairing identity and same-name isolation")
        print("PASS library store: legacy migration, exact text, retry/repeat handling, pins, collections, Undo, attachment backup and reload")
    }
}
