import AppKit
import MTPKit
import SwiftUI

/// Space-bar preview, the way the Finder's Quick Look behaves.
///
/// The image has to be fetched off the phone first, so the sheet opens immediately with the grid
/// thumbnail already in hand and swaps in the full picture when it arrives — a blank window that
/// fills in a second later feels broken even when it is the same wait.
struct PreviewSheet: View {
    @ObservedObject var browser: PhoneBrowser
    @State var entry: MTPEntry
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var failure: String?

    @Environment(\.dismiss) private var dismiss

    /// Only photos take part: stepping onto a 700 MB video would stall the sheet.
    private var neighbours: [MTPEntry] { browser.visibleEntries.filter(\.isPhoto) }
    private var position: Int? { neighbours.firstIndex(of: entry) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.03)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else if let failure {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.tertiary)
                        Text(failure).foregroundStyle(.secondary)
                    }
                }
                if isLoading {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(minWidth: 560, minHeight: 420)

            HStack(spacing: 12) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled((position ?? 0) <= 0)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(position == nil || position! >= neighbours.count - 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let position {
                    Text("\(position + 1) of \(neighbours.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 600, minHeight: 480)
        .task(id: entry.id) { await load() }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.space) { dismiss(); return .handled }
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
        guard let pixels = image else { return size }
        return "\(Int(pixels.size.width)) × \(Int(pixels.size.height))  ·  \(size)"
    }

    private func step(_ delta: Int) {
        guard let position else { return }
        let next = position + delta
        guard neighbours.indices.contains(next) else { return }
        image = nil
        entry = neighbours[next]
    }

    private func load() async {
        isLoading = true
        failure = nil
        // Something to look at straight away, if the grid already has it.
        image = browser.thumbnails.images[entry.id]
        if let full = await browser.previewImage(for: entry) {
            image = full
        } else if image == nil {
            failure = "Could not read this file from the phone."
        }
        isLoading = false
    }
}
