//
//  CapturesView.swift — Galerie der Aufnahmen in der App, samt Ablage.
//
//  Die Ablage (Documents/Captures) ist die Wahrheit der App: dort landet jede
//  Aufnahme zuerst, unabhängig davon, ob der Export in die Fotomediathek
//  klappt. Die Galerie zeigt genau diese Dateien — ansehen, teilen, löschen.
//

import AVFoundation
import AVKit
import SwiftUI
import UIKit

// MARK: - Ablage

enum CaptureStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    private static func freeURL(prefix: String, ext: String) -> URL {
        var url = directory.appendingPathComponent("\(prefix) \(stamp()).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(prefix) \(stamp()) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// Übernimmt eine fertige tmp-Videodatei in die Ablage (verschieben).
    static func adopt(_ url: URL) -> URL? {
        let dest = freeURL(prefix: "Clip", ext: "mov")
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    static func savePhoto(_ data: Data) -> URL? {
        let dest = freeURL(prefix: "Foto", ext: "jpg")
        do {
            try data.write(to: dest)
            return dest
        } catch {
            return nil
        }
    }

    static func items() -> [CaptureItem] {
        let keys: Set<URLResourceKey> = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return urls.compactMap { url -> CaptureItem? in
            let ext = url.pathExtension.lowercased()
            guard ext == "mov" || ext == "jpg" else { return nil }
            let values = try? url.resourceValues(forKeys: keys)
            return CaptureItem(url: url,
                               date: values?.creationDate ?? .distantPast,
                               bytes: values?.fileSize ?? 0,
                               isVideo: ext == "mov")
        }
        .sorted { $0.date > $1.date }
    }

    static func delete(_ item: CaptureItem) {
        try? FileManager.default.removeItem(at: item.url)
    }
}

struct CaptureItem: Identifiable, Equatable {
    let url: URL
    let date: Date
    let bytes: Int
    let isVideo: Bool
    var id: URL { url }
}

// MARK: - Galerie

struct CapturesView: View {
    @State private var items: [CaptureItem] = []
    @State private var selected: CaptureItem?

    private var totalBytes: Int { items.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView("Noch keine Aufnahmen",
                                       systemImage: "camera",
                                       description: Text("Clips und Fotos aus dem Sucher landen hier — zusätzlich zur Fotomediathek."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 2)],
                              spacing: 2) {
                        ForEach(items) { item in
                            Button {
                                Haptics.light()
                                selected = item
                            } label: {
                                CaptureThumb(item: item)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                ShareLink(item: item.url) { Label("Teilen", systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { delete(item) } label: {
                                    Label("Löschen", systemImage: "trash")
                                }
                            }
                            .accessibilityLabel(item.isVideo ? "Video vom \(item.date.formatted())" : "Foto vom \(item.date.formatted())")
                        }
                    }
                }
            }
        }
        .navigationTitle("Aufnahmen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(ByteCountFormatter.string(fromByteCount: Int64(totalBytes), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Speicherbedarf der Aufnahmen")
            }
        }
        .sheet(item: $selected) { item in
            CaptureDetailSheet(item: item) {
                delete(item)
                selected = nil
            } onChanged: {
                items = CaptureStore.items()
            }
        }
        .onAppear { items = CaptureStore.items() }
    }

    private func delete(_ item: CaptureItem) {
        CaptureStore.delete(item)
        items.removeAll { $0 == item }
        Haptics.warning()
    }
}

// MARK: - Kachel

private struct CaptureThumb: View {
    let item: CaptureItem
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle()
                .fill(.black.opacity(0.4))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ProgressView()
                    }
                }
                .clipped()
            if item.isVideo {
                Image(systemName: "play.fill")
                    .font(.caption)
                    .padding(5)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
        }
        .task { await loadThumb() }
    }

    private func loadThumb() async {
        guard image == nil else { return }
        if item.isVideo {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)
            if let cg = try? await generator.image(at: .zero).image {
                image = UIImage(cgImage: cg)
            }
        } else {
            let url = item.url
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                UIImage(contentsOfFile: url.path)?
                    .preparingThumbnail(of: CGSize(width: 400, height: 400))
            }.value
        }
    }
}

// MARK: - Detail

private struct CaptureDetailSheet: View {
    let item: CaptureItem
    let onDelete: () -> Void
    /// Ablage hat sich geändert (z. B. getrimmte Kopie) — Galerie neu laden.
    var onChanged: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var showTrimmer = false
    @State private var trimMessage: String?

    private var canTrim: Bool {
        item.isVideo && UIVideoEditorController.canEditVideo(atPath: item.url.path)
    }

    var body: some View {
        NavigationStack {
            Group {
                if item.isVideo {
                    VideoPlayer(player: AVPlayer(url: item.url))
                } else if let img = UIImage(contentsOfFile: item.url.path) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .navigationTitle(item.date.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fertig") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canTrim {
                        Button {
                            showTrimmer = true
                        } label: {
                            Image(systemName: "scissors")
                        }
                        .accessibilityLabel("Clip trimmen")
                    }
                    ShareLink(item: item.url)
                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Aufnahme löschen")
                }
            }
            .fullScreenCover(isPresented: $showTrimmer) {
                VideoTrimmer(url: item.url) { edited in
                    // Getrimmte Fassung als NEUE Aufnahme übernehmen — das
                    // Original bleibt, bis man es selbst löscht.
                    if CaptureStore.adopt(edited) != nil {
                        trimMessage = "Getrimmte Kopie gesichert — das Original bleibt erhalten."
                        onChanged()
                        Haptics.success()
                    } else {
                        trimMessage = "Getrimmte Fassung konnte nicht gesichert werden."
                        Haptics.error()
                    }
                }
                .ignoresSafeArea()
            }
            .alert("Trimmen", isPresented: Binding(get: { trimMessage != nil },
                                                   set: { if !$0 { trimMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(trimMessage ?? "")
            }
        }
    }
}

// MARK: - Trimmen

/// Der System-Videoeditor (UIVideoEditorController): Anfang/Ende zuschneiden,
/// gespeichert wird in eine tmp-Datei, die der Aufrufer übernimmt.
private struct VideoTrimmer: UIViewControllerRepresentable {
    let url: URL
    let onSaved: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIVideoEditorController {
        let vc = UIVideoEditorController()
        vc.videoPath = url.path
        vc.videoQuality = .typeHigh
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIVideoEditorController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSaved: onSaved, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIVideoEditorControllerDelegate,
                             UINavigationControllerDelegate {
        let onSaved: (URL) -> Void
        let dismiss: () -> Void

        init(onSaved: @escaping (URL) -> Void, dismiss: @escaping () -> Void) {
            self.onSaved = onSaved
            self.dismiss = dismiss
        }

        func videoEditorController(_ editor: UIVideoEditorController,
                                   didSaveEditedVideoToPath editedVideoPath: String) {
            onSaved(URL(fileURLWithPath: editedVideoPath))
            dismiss()
        }

        func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) {
            dismiss()
        }

        func videoEditorController(_ editor: UIVideoEditorController,
                                   didFailWithError error: Error) {
            dismiss()
        }
    }
}

#Preview {
    NavigationStack { CapturesView() }
}
