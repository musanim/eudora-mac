import AppKit
import EudoraStore
import UniformTypeIdentifiers

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

/// Actions on an attachment Eudora detached to disk.
///
/// Same stance as `AttachmentActions`, and the same prohibition: **nothing here
/// opens the file with its default application.** That the bytes are already
/// sitting in the Attachments folder doesn't change the calculus — a message
/// that can cause Word to open a document it names is exactly the
/// message-triggered behaviour design-decisions §1–§3 rules out. `Reveal in
/// Finder` selects the file without opening it; the user decides from there.
@MainActor
enum DetachedAttachmentActions {

    /// Show the file in the Finder, selected but not opened.
    static func reveal(_ item: LocatedAttachment) {
        guard let url = item.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copy the file somewhere the user picks.
    ///
    /// Reads and writes explicitly rather than `FileManager.copyItem`, so the
    /// copy lands as a plain new file: no source permissions, ownership, or
    /// quarantine/extended attributes carried across from a decades-old tree.
    static func saveCopy(_ item: LocatedAttachment) {
        guard let url = item.url else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.filename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                // Memory-mapped: an old Attachments folder can hold very large
                // files, and this shouldn't pull one wholly into RAM to copy it.
                try Data(contentsOf: url, options: .mappedIfSafe).write(to: dest)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// Whether the existing native image viewer can show this file. There is no
    /// Content-Type to consult — the MIME part is long gone — so the extension is
    /// all we have.
    static func isImage(_ item: LocatedAttachment) -> Bool {
        let ext = (item.filename as NSString).pathExtension.lowercased()
        return MessageAttachment.imageExtensions.contains(ext)
    }

    /// View an image in the native viewer — no web engine, no network, same
    /// window used for embedded images.
    static func viewImage(_ item: LocatedAttachment) {
        guard let url = item.url, let data = try? Data(contentsOf: url) else { return }
        let ext = (item.filename as NSString).pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        ImageViewerController.shared.show(
            EmbeddedImage(id: "eu-detached-\(item.filename)",
                          data: data,
                          mimeType: mime,
                          suggestedName: item.filename))
    }
}
