import SwiftUI

struct AttachmentDeleteSheet: View {
    let count: Int
    let hasAttachments: Bool
    @Binding var deleteFiles: Bool
    let onDelete: () -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Delete \(count == 1 ? "clip" : "\(count) clips")?").font(.system(size: 21, weight: .semibold))
            Text("This removes history on this Mac only. Your phone keeps its copy.").font(.system(size: 12)).foregroundStyle(.secondary)
            if hasAttachments {
                Toggle("Also delete stored attachment files", isOn: $deleteFiles).toggleStyle(.switch)
                Text("Only copies in ClipToMac’s attachment folder are removed, after Undo expires. Original files are kept.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Cancel", action: onCancel); Button("Delete", role: .destructive, action: onDelete) }.buttonStyle(.bordered)
        }.padding(22).frame(width: 380).background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
