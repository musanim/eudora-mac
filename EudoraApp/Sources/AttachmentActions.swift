import AppKit
import EudoraStore

/// Deliberate, user-initiated actions on a message attachment. Consistent with
/// the "dumb client" stance (design-decisions §1–§3): we **never** hand a file
/// to its default app (which could launch/execute it). The only actions are
/// writing the bytes where the user chooses, and — for images — showing them in
/// the existing safe native viewer (no web engine, no network).
@MainActor
enum AttachmentActions {

    /// Save As… — write the bytes to a location the user picks.
    static func saveAs(_ attachment: MessageAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try attachment.data.write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// View an image attachment in the native image viewer (same window used for
    /// embedded images). Only meaningful when `attachment.isImage`.
    static func viewImage(_ attachment: MessageAttachment) {
        let resource = EmbeddedImage(id: attachment.id,
                                     data: attachment.data,
                                     mimeType: attachment.mimeType,
                                     suggestedName: attachment.filename)
        ImageViewerController.shared.show(resource)
    }
}
