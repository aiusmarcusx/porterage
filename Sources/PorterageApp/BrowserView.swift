import AppKit
import MTPKit
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var browser: PhoneBrowser
    @ObservedObject private var transfers: TransferQueue
    @ObservedObject private var thumbnails: ThumbnailStore

    @State private var isDropTargeted = false
    @State private var renaming: MTPEntry?
    @State private var draftName = ""
    @State private var isCreatingFolder = false
    @State private var deleting: [MTPEntry] = []
    @State private var problem: String?
    @State private var previewing: MTPEntry?
    @AppStorage("browser.showsGrid") private var showsGrid = false

    init(browser: PhoneBrowser) {
        self.browser = browser
        transfers = browser.transfers
        thumbnails = browser.thumbnails
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if !transfers.jobs.isEmpty {
                Divider()
                transferBar
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 480)
        .sheet(item: $renaming) { entry in
            nameSheet(title: "Rename", confirm: "Rename") { name in
                await browser.rename(entry, to: name)
            }
        }
        .sheet(isPresented: $isCreatingFolder) {
            nameSheet(title: "New Folder", confirm: "Create") { name in
                await browser.createFolder(named: name)
            }
        }
        .confirmationDialog(deleteQuestion, isPresented: .constant(!deleting.isEmpty)) {
            Button("Delete \(deleting.count) item\(deleting.count == 1 ? "" : "s")", role: .destructive) {
                let targets = deleting
                deleting = []
                Task { problem = await browser.delete(targets) }
            }
            Button("Cancel", role: .cancel) { deleting = [] }
        } message: {
            Text("Deleting on the phone is permanent. There is no trash to recover from.")
        }
        .confirmationDialog(clashQuestion, isPresented: .constant(browser.pendingUpload != nil)) {
            Button("Keep Both") { browser.resolvePendingUpload(.keepBoth) }
            Button("Replace", role: .destructive) { browser.resolvePendingUpload(.replace) }
            Button("Skip Duplicates") { browser.resolvePendingUpload(.skip) }
            Button("Cancel", role: .cancel) { browser.pendingUpload = nil }
        } message: {
            Text(clashMessage)
        }
        .confirmationDialog(downloadClashQuestion, isPresented: .constant(browser.pendingDownload != nil)) {
            Button("Keep Both") { browser.resolvePendingDownload(.keepBoth) }
            Button("Replace", role: .destructive) { browser.resolvePendingDownload(.replace) }
            Button("Skip Existing") { browser.resolvePendingDownload(.skip) }
            Button("Cancel", role: .cancel) { browser.pendingDownload = nil }
        } message: {
            Text("""
            Replace overwrites the files already on this Mac. Skip Existing copies only what is not \
            there yet, which also finishes a copy that was interrupted.
            """)
        }
        .sheet(item: $previewing) { entry in
            PreviewSheet(browser: browser, entry: entry)
        }
        .alert("That didn't work", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: browser.goUp) { Image(systemName: "chevron.left") }
                .disabled(browser.path.isEmpty)
                .help("Go up one folder")

            breadcrumb

            Spacer(minLength: 12)

            if browser.isLoading { ProgressView().controlSize(.small) }

            searchField
            sortMenu

            Picker("", selection: $showsGrid) {
                Image(systemName: "list.bullet").tag(false)
                Image(systemName: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 74)
            .help("Switch between list and photo grid")

            Button { isCreatingFolder = true } label: { Image(systemName: "folder.badge.plus") }
                .disabled(!browser.status.isReady)
                .help("New folder")

            Button("Copy to Mac…", action: chooseDestination)
                .disabled(browser.selection.isEmpty)

            Button(action: browser.reload) { Image(systemName: "arrow.clockwise") }
                .disabled(!browser.status.isReady)
                .help("Reload")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
            TextField("Search this folder", text: $browser.searchText)
                .textFieldStyle(.plain)
                .frame(width: 150)
            if !browser.searchText.isEmpty {
                Button { browser.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        .disabled(!browser.status.isReady)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $browser.sortField) {
                ForEach(PhoneBrowser.SortField.allCases) { field in
                    Text(field.label).tag(field)
                }
            }
            Divider()
            Picker("Order", selection: $browser.sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort")
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(label: storageName, entry: nil)
                ForEach(browser.path) { entry in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    crumb(label: entry.name, entry: entry)
                }
            }
        }
    }

    private func crumb(label: String, entry: MTPEntry?) -> some View {
        Button(label) { browser.navigate(to: entry) }
            .buttonStyle(.plain)
            .fontWeight(entry == browser.path.last ? .semibold : .regular)
    }

    private var storageName: String {
        if case let .ready(storage) = browser.status { return storage.name }
        return "Phone"
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        let count = browser.selection.count
        panel.message = "Choose where on this Mac to copy \(count) item\(count == 1 ? "" : "s")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { problem = await browser.downloadSelection(to: url) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if case .ready = browser.status {
            ZStack {
                if let errorText = browser.errorText {
                    message(icon: "exclamationmark.triangle", title: "Could not read this folder", detail: errorText)
                } else if browser.entries.isEmpty, browser.isLoading {
                    message(icon: "", title: "Reading the folder…",
                            detail: "The first read after plugging in can take a while — the phone is "
                                + "building its index of everything on it.", spinner: true)
                } else if browser.visibleEntries.isEmpty {
                    emptyState
                } else if showsGrid {
                    photoGrid
                } else {
                    fileList
                }
                if isDropTargeted { dropHighlight }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
            .onDeleteCommand(perform: askToDeleteSelection)
            .onKeyPress(.space) { openPreview(); return .handled }
            .background(selectAllShortcut)
        } else {
            connectionHelp
        }
    }

    /// Off-screen button purely so ⌘A reaches the browser; SwiftUI has no select-all command hook.
    private var selectAllShortcut: some View {
        Button("", action: browser.selectAll)
            .keyboardShortcut("a", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !browser.searchText.isEmpty {
            message(icon: "magnifyingglass", title: "Nothing matches",
                    detail: "No item in \(browser.currentFolderName) contains “\(browser.searchText)”.")
        } else {
            message(icon: "folder", title: "This folder is empty",
                    detail: "Drag files here from the Finder to copy them onto the phone.")
        }
    }

    private var fileList: some View {
        List(browser.visibleEntries, selection: $browser.selection) { entry in
            HStack(spacing: 8) {
                Image(systemName: icon(for: entry))
                    .foregroundStyle(entry.isFolder ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                if !entry.isFolder {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                // 150 fits the widest measured English region, en_CA "2026-12-31, 10:59 AM" at
                // 143 pt. Too narrow and the date wraps onto a second line rather than truncating.
                Text(entry.modified.map(Self.dateFormatter.string(from:)) ?? "—")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: 150, alignment: .trailing)
            }
            .contentShape(Rectangle())
            // Has to be simultaneous: an ordinary onTapGesture swallows the single click the List
            // needs to move its own selection, leaving rows unselectable.
            .simultaneousGesture(TapGesture(count: 2).onEnded { browser.open(entry) })
            .onDrag { browser.dragProvider(for: entry) }
            .contextMenu { menu(for: entry) }
        }
        .listStyle(.inset)
    }

    // MARK: - Grid

    private var photoGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 12)], spacing: 12) {
                ForEach(browser.visibleEntries) { entry in
                    gridTile(entry)
                }
            }
            .padding(12)
        }
    }

    private func gridTile(_ entry: MTPEntry) -> some View {
        let isSelected = browser.selection.contains(entry.id)
        return VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06))
                if let image = thumbnails.images[entry.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if entry.isPhoto, !thumbnails.unavailable.contains(entry.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon(for: entry))
                        .font(.system(size: 30))
                        .foregroundStyle(entry.isFolder ? Color.accentColor : Color.secondary)
                }
            }
            // A photo scaled to fill is wider than its cell, so it has to be clipped to the cell —
            // without this it paints over the neighbouring tiles and the filename below.
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )
            Text(entry.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(entry) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { browser.open(entry) })
        .onDrag { browser.dragProvider(for: entry) }
        .contextMenu { menu(for: entry) }
    }

    /// Plain click replaces the selection, ⌘-click adds to it — the same rules as the Finder.
    private func toggle(_ entry: MTPEntry) {
        if NSEvent.modifierFlags.contains(.command) {
            if browser.selection.contains(entry.id) { browser.selection.remove(entry.id) }
            else { browser.selection.insert(entry.id) }
        } else {
            browser.selection = [entry.id]
        }
    }

    // MARK: - Per-item menu

    @ViewBuilder
    private func menu(for entry: MTPEntry) -> some View {
        if entry.isFolder {
            Button("Open") { browser.open(entry) }
        }
        if entry.isPhoto {
            Button("Quick Look") { previewing = entry }
        }
        Button("Copy to Mac…") {
            browser.selection = [entry.id]
            chooseDestination()
        }
        Divider()
        Button("Rename…") {
            draftName = entry.name
            renaming = entry
        }
        Button("Delete", role: .destructive) {
            deleting = browser.selection.contains(entry.id) ? browser.selectedEntries : [entry]
        }
    }

    /// Space bar previews the first selected photo, the way Quick Look does.
    private func openPreview() {
        previewing = browser.selectedEntries.first { $0.isPhoto }
            ?? browser.visibleEntries.first { browser.selection.contains($0.id) }
    }

    private func askToDeleteSelection() {
        let targets = browser.selectedEntries
        guard !targets.isEmpty else { return }
        deleting = targets
    }

    private var deleteQuestion: String {
        if deleting.count == 1 {
            return deleting[0].isFolder
                ? "Delete “\(deleting[0].name)” and everything in it from the phone?"
                : "Delete “\(deleting[0].name)” from the phone?"
        }
        return deleting.contains(where: \.isFolder)
            ? "Delete \(deleting.count) items, including everything inside the folders, from the phone?"
            : "Delete \(deleting.count) items from the phone?"
    }

    private var clashQuestion: String {
        guard let pending = browser.pendingUpload else { return "" }
        return pending.clashes.count == 1
            ? "The phone already has “\(pending.clashes[0])”"
            : "The phone already has \(pending.clashes.count) files with these names"
    }

    private var clashMessage: String {
        let warning = """
        The phone's storage treats upper and lower case as the same name, so Replace will destroy the \
        file that is already there.
        """
        guard let notice = browser.pendingUpload?.notice else { return warning }
        return warning + "\n\n" + notice
    }

    private var downloadClashQuestion: String {
        guard let pending = browser.pendingDownload else { return "" }
        return pending.clashes.count == 1
            ? "“\(pending.clashes[0])” is already in that folder on this Mac"
            : "\(pending.clashes.count) of these files are already in that folder on this Mac"
    }

    // MARK: - Name sheet

    private func nameSheet(title: String, confirm: String, action: @escaping (String) async -> String?) -> some View {
        NameSheet(title: title, confirm: confirm, name: $draftName) { name in
            if let failure = await action(name) {
                problem = failure
                return false
            }
            return true
        }
    }

    // MARK: - Drop

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.08))
            .overlay(
                Text("Drop into \(browser.currentFolderName)")
                    .font(.title3)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            )
            .padding(6)
            .allowsHitTesting(false)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let raw = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                   let decoded = URL(dataRepresentation: raw, relativeTo: nil) {
                    urls.append(decoded)
                }
            }
            guard !urls.isEmpty else { return }
            if let note = browser.upload(urls) { problem = note }
        }
        return true
    }

    private func icon(for entry: MTPEntry) -> String {
        if entry.isFolder { return "folder.fill" }
        if entry.isPhoto { return "photo" }
        return "doc"
    }

    /// Field order, separators and the 12- or 24-hour clock follow the user's region; only the
    /// calendar is pinned, because a Buddhist-calendar region would otherwise show 2026 as 2569.
    /// The calendar has to be set before the template: set afterwards, the pattern keeps the
    /// region's era field and prints "13/9/2026 A". A template rather than `dateStyle = .short`,
    /// which gives US and Thai users a two-digit year.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.setLocalizedDateFormatFromTemplate("yMdjmm")
        return f
    }()

    // MARK: - Transfers

    private var transferBar: some View {
        HStack(spacing: 12) {
            if let job = transfers.activeJob {
                Image(systemName: job.direction == .fromPhone ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).lineLimit(1).truncationMode(.middle)
                    ProgressView(value: job.fraction).frame(width: 240)
                }
                Text(speedText).foregroundStyle(.secondary).monospacedDigit()
                Text(etaText).foregroundStyle(.secondary).monospacedDigit()
                if transfers.remaining > 1 {
                    Text("\(transfers.remaining - 1) to go").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop", action: transfers.cancelAll)
            } else {
                let failed = transfers.jobs.contains { if case .failed = $0.state { return true } else { return false } }
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(failed ? Color.orange : Color.green)
                Text(summaryText)
                Spacer()
                Button("Clear", action: transfers.clearFinished)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var speedText: String {
        guard transfers.currentSpeed > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(transfers.currentSpeed), countStyle: .file) + "/s"
    }

    private var etaText: String {
        guard let seconds = transfers.secondsRemaining else { return "" }
        if seconds < 60 { return "~\(Int(seconds))s left" }
        if seconds < 3600 { return "~\(Int(seconds / 60)) min left" }
        return String(format: "~%.1f h left", seconds / 3600)
    }

    private var summaryText: String {
        let done = transfers.jobs.filter { $0.state == .done }.count
        let failures = transfers.jobs.compactMap { job -> String? in
            if case let .failed(reason) = job.state { return reason }
            return nil
        }
        let cancelled = transfers.jobs.filter { $0.state == .cancelled }.count
        var parts: [String] = []
        if done > 0 { parts.append("\(done) copied") }
        if cancelled > 0 { parts.append("\(cancelled) stopped") }
        if let first = failures.first {
            parts.append(failures.count > 1 ? "\(failures.count) failed — \(first)" : "failed: \(first)")
        }
        return parts.isEmpty ? "Nothing copied yet" : parts.joined(separator: ", ")
    }

    // MARK: - Connection help
    //
    // Each state below maps to a signature measured on real hardware; the point of naming them
    // separately is that "busy or not connected" tells the user nothing about what to do next.

    @ViewBuilder
    private var connectionHelp: some View {
        switch browser.status {
        case .searching:
            message(icon: "cable.connector", title: "Looking for a phone…", detail: nil, spinner: true)
        case .noDevice:
            message(
                icon: "cable.connector.slash",
                title: "No phone found",
                detail: """
                • Plug the phone into this Mac with a **data** cable — many charging cables carry power only.
                • On the phone, pull down the notification shade, tap the USB notification, and choose **File transfer**.
                """
            )
        case .locked:
            message(
                icon: "lock.fill",
                title: "The phone is locked",
                detail: """
                Android will not let a computer read its storage while the screen is locked. Unlock it and this window fills in by itself.

                A copy that is already running is unaffected — locking the screen mid-transfer does not interrupt it.
                """
            )
        case .photoMode:
            message(
                icon: "photo.on.rectangle",
                title: "A device is connected in Photo transfer mode",
                detail: """
                If it's your phone, pull down the notification shade, tap the USB notification, and choose **File transfer**. In Photo transfer mode a phone shows only its photo folders.
                """
            )
        case .busy:
            message(
                icon: "exclamationmark.triangle.fill",
                title: "Another program is holding the phone",
                detail: "Quit any other phone manager (OpenMTP, Android File Transfer, and so on) and try again."
            )
        case .unresponsive:
            message(
                icon: "bolt.horizontal.circle",
                title: "The phone is connected but not answering",
                detail: """
                Unplug the cable and plug it back in. Once a phone stops answering, only a replug brings it back — restarting this app is not enough.
                """
            )
        case .ready:
            EmptyView()
        }
    }

    private func message(icon: String, title: String, detail: String?, spinner: Bool = false) -> some View {
        VStack(spacing: 12) {
            if spinner {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.tertiary)
            }
            Text(title).font(.title3).fontWeight(.medium)
            if let detail {
                Text(LocalizedStringKey(detail))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if case let .ready(storage) = browser.status {
                let used = Double(storage.capacity - storage.free) / Double(max(storage.capacity, 1))
                ProgressView(value: used).frame(width: 90)
                Text("\(format(storage.free)) free of \(format(storage.capacity))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !browser.selection.isEmpty {
                Text("\(browser.selection.count) selected").foregroundStyle(.secondary)
                Button("Deselect", action: browser.clearSelection).buttonStyle(.link)
            }
            if browser.hiddenCount > 0 {
                Toggle("Show \(browser.hiddenCount) hidden", isOn: $browser.showsHiddenFiles)
                    .toggleStyle(.checkbox)
            }
            Text("\(browser.visibleEntries.count) items").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Asks for one name, and stays open when the phone or the name rules reject it.
private struct NameSheet: View {
    let title: String
    let confirm: String
    @Binding var name: String
    let commit: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirm, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
        .padding(18)
    }

    private func submit() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            let ok = await commit(name)
            isWorking = false
            if ok { dismiss() }
        }
    }
}
