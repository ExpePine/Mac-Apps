import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Image helpers

enum ImageIO {
    static func png(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// An image on the clipboard, e.g. after ⌃⇧⌘4 (screenshot of a selection to the clipboard).
    static func pasteboardImage() -> NSImage? {
        let pb = NSPasteboard.general
        if let img = NSImage(pasteboard: pb) { return img }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }

    static func chooseImages() -> [NSImage] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose chart screenshots"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { NSImage(contentsOf: $0) }
    }
}

struct PendingImage: Identifiable {
    let id = UUID()
    let image: NSImage
}

// MARK: - Editor strip (used in the observation editor)

struct AttachmentEditorStrip: View {
    @EnvironmentObject private var store: Store
    @Binding var existing: [String]
    @Binding var pending: [PendingImage]
    @State private var dropTargeted = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Chart screenshots").font(.callout).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(existing, id: \.self) { name in
                        thumb(store.image(name)) { existing.removeAll { $0 == name } }
                    }
                    ForEach(pending) { p in
                        thumb(p.image) { pending.removeAll { $0.id == p.id } }
                    }
                    dropZone
                }
                .padding(.vertical, 2)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func thumb(_ image: NSImage?, remove: @escaping () -> Void) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 112, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.1)))

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.6))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("Remove")
        }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "photo.badge.plus").font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button("Paste") { paste() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Paste a screenshot from the clipboard (⇧⌘V). Tip: ⌃⇧⌘4 copies a screen area to the clipboard.")
                Button("Choose…") { pending += ImageIO.chooseImages().map { PendingImage(image: $0) } }
            }
            .controlSize(.small)
            Text("or drop images here").font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(width: 170, height: 72)
        .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5)))
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private func paste() {
        if let img = ImageIO.pasteboardImage() {
            pending.append(PendingImage(image: img))
            message = nil
        } else {
            message = "No image on the clipboard. Use ⌃⇧⌘4 to copy part of the screen, then Paste."
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil),
                          let img = NSImage(contentsOf: url) else { return }
                    DispatchQueue.main.async { pending.append(PendingImage(image: img)) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    DispatchQueue.main.async { pending.append(PendingImage(image: img)) }
                }
            }
        }
    }
}

// MARK: - Thumbnails on cards + full-size viewer

struct ImageRef: Identifiable { let id: String }

struct AttachmentThumbnails: View {
    @EnvironmentObject private var store: Store
    let names: [String]
    @State private var viewing: ImageRef?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    Button { viewing = ImageRef(id: name) } label: {
                        Group {
                            if let img = store.image(name) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "photo").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 150, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                    .help("View full size")
                }
            }
        }
        .sheet(item: $viewing) { ref in
            ImageViewer(name: ref.id).environmentObject(store)
        }
    }
}

struct ImageViewer: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let name: String

    var body: some View {
        VStack(spacing: 0) {
            if let img = store.image(name) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 1100)
                        .padding(12)
                }
            } else {
                EmptyStateView(systemImage: "photo", title: "Image not found",
                               message: "The file may have been removed from the Attachments folder.")
            }
            Divider()
            HStack {
                Button("Open in Preview") { NSWorkspace.shared.open(store.imageURL(name)) }
                Button("Show in Finder") { store.revealFolder(store.imageURL(name)) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 520, idealHeight: 680)
    }
}
