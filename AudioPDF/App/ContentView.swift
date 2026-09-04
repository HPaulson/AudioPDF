import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(ReaderCore)
import ReaderCore
#endif

private struct SendableEvent: @unchecked Sendable {
    let value: NSEvent?
}

private final class DropIDAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<UUID>()

    func insert(_ newIDs: Set<UUID>) {
        lock.lock()
        ids.formUnion(newIDs)
        lock.unlock()
    }

    func snapshot() -> Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}

private enum SidebarItem: Hashable {
    case document(UUID)
    case folder(UUID)
    case unfiled
}

private struct ImportBatch: Identifiable {
    struct PDF: Identifiable {
        let id = UUID()
        let title: String
        let bookmark: Data
    }

    let id = UUID()
    let pdfs: [PDF]
}

private struct FolderEditor: Identifiable {
    enum Mode { case create, rename }

    let id = UUID()
    let mode: Mode
    let parentID: UUID?
    let folder: LibraryFolder?
    var name: String
}

struct ContentView: View {
    let applicationDelegate: AudioPDFApplicationDelegate
    @StateObject private var libraryStore = LibraryStore()
    @StateObject private var controller = ReaderController()
    @State private var sidebarSelection: Set<SidebarItem> = []
    @State private var importing = false
    @State private var pendingImport: ImportBatch?
    @State private var folderEditor: FolderEditor?
    @State private var folderPendingDeletion: LibraryFolder?

    private var selectedDocumentIDs: Set<UUID> {
        Set(sidebarSelection.compactMap {
            guard case let .document(id) = $0 else { return nil }
            return id
        })
    }

    private var activeDocumentID: UUID? {
        libraryStore.documents.first(where: { selectedDocumentIDs.contains($0.id) })?.id
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Library")
                        .font(.title2)
                    Spacer()
                    Button("Import") {
                        importing = true
                    }
                    .keyboardShortcut("o")
                    .help("Import PDFs")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                List(selection: $sidebarSelection) {
                    Section {
                        ForEach(libraryStore.folderTree) { node in
                            FolderBranch(
                                node: node,
                                libraryStore: libraryStore,
                                selection: sidebarSelection,
                                onCreateFolder: beginCreatingFolder,
                                onRenameFolder: beginRenamingFolder,
                                onDeleteFolder: { folderPendingDeletion = $0 },
                                onSelectFolderContents: selectFolderContents,
                                onDeleteDocuments: deleteDocuments,
                                onSynthesizeDocuments: { controller.synthesize(documentIDs: $0) },
                                onStopDocuments: { controller.stopSynthesis(for: $0) },
                                onQueuePosition: { controller.processingQueuePosition(for: $0) },
                                onIsProcessing: { controller.isProcessing(documentIDs: [$0]) },
                                onDropDocuments: moveDocuments
                            )
                        }
                    } header: {
                        HStack {
                            Text("Folders")
                            Spacer()
                            Button {
                                beginCreatingFolder(parentID: nil)
                            } label: {
                                Label("New Folder", systemImage: "folder.badge.plus")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.plain)
                            .help("New Folder")
                        }
                    }

                    Section {
                        ForEach(libraryStore.documents(in: nil)) { document in
                            documentRow(document)
                        }
                    } header: {
                        HStack {
                            Label("Unfiled", systemImage: "tray")
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                            .onDrop(of: [.utf8PlainText], delegate: PDFDropDelegate { ids in
                                moveDocuments(ids, nil)
                            })
                    }
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 240)
        } detail: {
            detailView
        }
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 980, minHeight: 650)
        .background(PlaybackKeyboardHandler(controller: controller))
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: true,
            onCompletion: prepareImport
        )
        .sheet(item: $pendingImport) { batch in
            ImportDestinationPicker(batch: batch, folders: libraryStore.folderTree) { folderID in
                importPDFs(batch, into: folderID)
            }
        }
        .alert(
            folderEditor?.mode == .rename ? "Rename Folder" : "New Folder",
            isPresented: Binding(
                get: { folderEditor != nil },
                set: { if !$0 { folderEditor = nil } }
            )
        ) {
            TextField("Folder name", text: Binding(
                get: { folderEditor?.name ?? "" },
                set: { folderEditor?.name = $0 }
            ))
            Button("Cancel", role: .cancel) { folderEditor = nil }
            Button(folderEditor?.mode == .rename ? "Rename" : "Create") {
                saveFolder()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(folderEditor?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        } message: {
            Text("Folders can contain PDFs and other folders.")
        }
        .confirmationDialog(
            "Delete \(folderPendingDeletion?.name ?? "folder")?",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder and PDFs", role: .destructive) {
                deleteFolder()
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { folderPendingDeletion = nil }
        } message: {
            Text("This removes this folder, every folder inside it, and their PDF entries from the library. The original PDF files will not be deleted.")
        }
        .onAppear {
            applicationDelegate.register(readerController: controller)
            controller.setLibraryStore(libraryStore)
            if sidebarSelection.isEmpty, let first = libraryStore.documents.first {
                sidebarSelection = [.document(first.id)]
            }
        }
        .onChange(of: sidebarSelection) { _, _ in
            loadSelectedDocument()
        }
        .alert(
            "AudioPDF",
            isPresented: Binding(
                get: { controller.presentedError != nil },
                set: { if !$0 { controller.presentedError = nil } }
            ),
            presenting: controller.presentedError
        ) { _ in
            Button("OK") {}
                .keyboardShortcut(.defaultAction)
        } message: { error in
            Text(error.localizedDescription)
        }
    }

    private struct PlaybackKeyboardHandler: NSViewRepresentable {
        let controller: ReaderController

        func makeCoordinator() -> Coordinator {
            Coordinator(controller: controller)
        }

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: .zero)
            context.coordinator.install()
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}

        static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
            coordinator.remove()
        }

        @MainActor
        final class Coordinator {
            private let controller: ReaderController
            private var monitor: Any?

            init(controller: ReaderController) {
                self.controller = controller
            }

            func install() {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let sendableEvent = SendableEvent(value: event)
                    let shouldConsume = MainActor.assumeIsolated { () -> Bool in
                        guard let event = sendableEvent.value,
                              let self else { return false }
                        return self.shouldConsume(event)
                    }
                    return shouldConsume ? nil : event
                }
            }

            func remove() {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
            }

            private func shouldConsume(_ event: NSEvent) -> Bool {
                guard controller.pdfDocument != nil,
                      !isEditingText,
                      event.window != nil else {
                    return false
                }

                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let noModifiers = modifiers.isEmpty
                let commandOnly = modifiers == .command

                switch event.keyCode {
                case 49 where noModifiers:
                    guard controller.isAudioReady, !event.isARepeat else { return false }
                    controller.togglePlayback()
                    return true
                case 123 where noModifiers:
                    guard controller.isAudioReady else { return false }
                    controller.skip(by: -10)
                    return true
                case 124 where noModifiers:
                    guard controller.isAudioReady else { return false }
                    controller.skip(by: 10)
                    return true
                case 123 where commandOnly:
                    guard controller.isAudioReady else { return false }
                    controller.moveByParagraph(-1)
                    return true
                case 124 where commandOnly:
                    guard controller.isAudioReady else { return false }
                    controller.moveByParagraph(1)
                    return true
                case 125 where noModifiers:
                    guard controller.isAudioReady else { return false }
                    controller.adjustSpeed(by: -1)
                    return true
                case 126 where noModifiers:
                    guard controller.isAudioReady else { return false }
                    controller.adjustSpeed(by: 1)
                    return true
                default:
                    return false
                }
            }

            private var isEditingText: Bool {
                guard let responder = NSApp.keyWindow?.firstResponder else { return false }
                return responder is NSTextField || responder is NSTextView
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if controller.pdfDocument != nil {
            VStack(spacing: 0) {
                PDFReaderView(
                    document: controller.pdfDocument,
                    paragraphs: controller.paragraphs,
                    currentParagraph: controller.currentParagraph,
                    selectedParagraph: controller.selectedParagraph,
                    followsPlayback: controller.isPlaybackActive && !controller.isScrubbing,
                    locksManualScrolling: controller.isPlaybackActive,
                    resumeActionsEnabled: controller.isAudioReady,
                    scrollRequestID: controller.readerScrollRequestID,
                    onParagraphClicked: controller.selectParagraph,
                    onPlayFromHere: { id in controller.playFromHere(at: id) }
                )
                .frame(minWidth: 560)
                if let paragraph = controller.selectedParagraph {
                    ParagraphActionBar(
                        paragraph: paragraph,
                        audioReady: controller.isAudioReady,
                        onPlay: { controller.playFromHere(at: paragraph.id) },
                        onDismiss: controller.clearParagraphSelection
                    )
                }
                if let progress = controller.audioGenerationProgress {
                    AudioGenerationProgressView(progress: progress)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.bar)
                        .overlay(alignment: .top) { Divider() }
                }
                PlaybackBar(controller: controller)
            }
            .navigationTitle(libraryStore.documents.first(where: { $0.id == activeDocumentID })?.title ?? "")
        } else if controller.audioState == .loading {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("Preparing PDF")
                        .font(.headline)
                }
                ProgressView()
                Text("This may take a moment for scanned PDFs.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No PDF Selected", systemImage: "book.pages", description: Text(controller.status))
        }
    }

    @ViewBuilder
    private func documentRow(_ document: LibraryDocument) -> some View {
        LibraryRow(
            document: document,
            queuePosition: queuePosition(for: document.id),
            isGenerating: controller.isProcessing(documentIDs: [document.id]),
            onStop: { controller.stopSynthesis(for: [document.id]) }
        )
            .tag(SidebarItem.document(document.id))
            .contextMenu {
                let ids = selectedDocumentIDs.contains(document.id) ? selectedDocumentIDs : [document.id]
                Button(ids.count > 1 ? "Generate Audio for Selected PDFs" : "Generate Audio") {
                    controller.synthesize(documentIDs: ids)
                }
                Button(ids.count > 1 ? "Stop Audio for Selected PDFs" : "Stop Audio") {
                    controller.stopSynthesis(for: ids)
                }
                Divider()
                Button(
                    selectedDocumentIDs.contains(document.id) && selectedDocumentIDs.count > 1 ? "Delete Selected PDFs" : "Delete",
                    role: .destructive
                ) {
                    deleteDocuments(ids)
                }
            }
            .onDrag {
                let ids = selectedDocumentIDs.contains(document.id) ? selectedDocumentIDs : [document.id]
                return NSItemProvider(object: ids.map(\.uuidString).joined(separator: ",") as NSString)
            }
    }

    private func prepareImport(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            let pdfs = try urls.map { url -> ImportBatch.PDF in
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return ImportBatch.PDF(
                    title: url.deletingPathExtension().lastPathComponent,
                    bookmark: try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                )
            }
            if !pdfs.isEmpty { pendingImport = ImportBatch(pdfs: pdfs) }
        } catch {
            controller.presentedError = error
        }
    }

    private func importPDFs(_ batch: ImportBatch, into folderID: UUID?) {
        do {
            let records = batch.pdfs.map { LibraryDocument(title: $0.title, bookmark: $0.bookmark, folderID: folderID) }
            for record in records { try libraryStore.add(record) }
            sidebarSelection = Set(records.map { .document($0.id) })
            pendingImport = nil
        } catch {
            controller.presentedError = error
        }
    }

    private func beginCreatingFolder(parentID: UUID?) {
        folderEditor = FolderEditor(mode: .create, parentID: parentID, folder: nil, name: "")
    }

    private func beginRenamingFolder(_ folder: LibraryFolder) {
        folderEditor = FolderEditor(mode: .rename, parentID: folder.parentID, folder: folder, name: folder.name)
    }

    private func saveFolder() {
        guard let editor = folderEditor else { return }
        let name = editor.name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            switch editor.mode {
            case .create:
                _ = try libraryStore.addFolder(name: name, parentID: editor.parentID)
            case .rename:
                if let folder = editor.folder { try libraryStore.rename(folder, to: name) }
            }
            folderEditor = nil
        } catch {
            controller.presentedError = error
        }
    }

    private func deleteFolder() {
        guard let folder = folderPendingDeletion else { return }
        do {
            controller.unload()
            let deletedDocumentIDs = try libraryStore.deleteFolder(folder)
            controller.cancelProcessing(for: deletedDocumentIDs)
            sidebarSelection = Set(sidebarSelection.filter { item in
                switch item {
                case let .document(id):
                    return !deletedDocumentIDs.contains(id)
                case let .folder(id):
                    return libraryStore.folders.contains { $0.id == id }
                case .unfiled:
                    return true
                }
            })
            folderPendingDeletion = nil
            loadSelectedDocument()
        } catch {
            controller.presentedError = error
        }
    }

    private func deleteDocuments(_ ids: Set<UUID>) {
        do {
            controller.cancelProcessing(for: ids)
            if let activeDocumentID, ids.contains(activeDocumentID) {
                controller.unload()
            }
            for document in libraryStore.documents where ids.contains(document.id) {
                try libraryStore.delete(document)
            }
            sidebarSelection.subtract(ids.map(SidebarItem.document))
            loadSelectedDocument()
        } catch {
            controller.presentedError = error
        }
    }

    private func moveDocuments(_ ids: Set<UUID>, _ folderID: UUID?) {
        do {
            try libraryStore.move(ids, to: folderID)
        } catch {
            controller.presentedError = error
        }
    }

    private func selectFolderContents(_ folderID: UUID) {
        sidebarSelection = Set(libraryStore.documents(includingDescendantsOf: folderID).map { .document($0.id) })
    }

    private func loadSelectedDocument() {
        let orderedIDs = libraryStore.documents.map(\.id).filter { selectedDocumentIDs.contains($0) }
        guard let id = orderedIDs.first,
              let record = libraryStore.documents.first(where: { $0.id == id }) else {
            controller.setGenerationQueuePosition(nil)
            controller.unload()
            return
        }
        controller.setGenerationQueuePosition(
            orderedIDs.count > 1 ? (position: 1, total: orderedIDs.count) : nil
        )
        controller.load(record)
    }

    private func queuePosition(for id: UUID) -> (position: Int, total: Int)? {
        _ = controller.processingQueueIDs
        return controller.processingQueuePosition(for: id)
    }
}

private struct FolderBranch: View {
    let node: LibraryFolderNode
    @ObservedObject var libraryStore: LibraryStore
    @State private var isExpanded = false
    let selection: Set<SidebarItem>
    let onCreateFolder: (UUID?) -> Void
    let onRenameFolder: (LibraryFolder) -> Void
    let onDeleteFolder: (LibraryFolder) -> Void
    let onSelectFolderContents: (UUID) -> Void
    let onDeleteDocuments: (Set<UUID>) -> Void
    let onSynthesizeDocuments: (Set<UUID>) -> Void
    let onStopDocuments: (Set<UUID>) -> Void
    let onQueuePosition: (UUID) -> (position: Int, total: Int)?
    let onIsProcessing: (UUID) -> Bool
    let onDropDocuments: (Set<UUID>, UUID?) -> Void

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(node.children) { child in
                FolderBranch(
                    node: child,
                    libraryStore: libraryStore,
                    selection: selection,
                    onCreateFolder: onCreateFolder,
                    onRenameFolder: onRenameFolder,
                    onDeleteFolder: onDeleteFolder,
                    onSelectFolderContents: onSelectFolderContents,
                    onDeleteDocuments: onDeleteDocuments,
                    onSynthesizeDocuments: onSynthesizeDocuments,
                    onStopDocuments: onStopDocuments,
                    onQueuePosition: onQueuePosition,
                    onIsProcessing: onIsProcessing,
                    onDropDocuments: onDropDocuments
                )
            }
            ForEach(libraryStore.documents(in: node.folder.id)) { document in
                documentRow(document)
            }
        } label: {
            HStack {
                Label(node.folder.name, systemImage: "folder")
                Spacer(minLength: 0)
            }
                .tag(SidebarItem.folder(node.folder.id))
                .contextMenu {
                    let documentIDs = Set(libraryStore.documents(includingDescendantsOf: node.folder.id).map(\.id))
                    Button("Generate Audio for All PDFs") {
                        onSynthesizeDocuments(documentIDs)
                    }
                    .disabled(documentIDs.isEmpty)
                    Button("Stop Audio for All PDFs") {
                        onStopDocuments(documentIDs)
                    }
                    .disabled(documentIDs.isEmpty)
                    Divider()
                    Button("New Folder") { onCreateFolder(node.folder.id) }
                    Button("Rename") { onRenameFolder(node.folder) }
                    Divider()
                    Button("Delete Folder", role: .destructive) { onDeleteFolder(node.folder) }
                }
                .contentShape(Rectangle())
                .onDrop(of: [.utf8PlainText], delegate: PDFDropDelegate { ids in
                    onDropDocuments(ids, node.folder.id)
                })
                .onTapGesture {
                    isExpanded.toggle()
                }
                .onTapGesture(count: 2) {
                    onSelectFolderContents(node.folder.id)
                }
        }
    }

    @ViewBuilder
    private func documentRow(_ document: LibraryDocument) -> some View {
        LibraryRow(
            document: document,
            queuePosition: queuePosition(for: document.id),
            isGenerating: isProcessing(document.id),
            onStop: { onStopDocuments([document.id]) }
        )
            .tag(SidebarItem.document(document.id))
            .contextMenu {
                let ids = selection.contains(.document(document.id)) ? selectedDocumentIDs : [document.id]
                Button(ids.count > 1 ? "Generate Audio for Selected PDFs" : "Generate Audio") {
                    onSynthesizeDocuments(ids)
                }
                Button(ids.count > 1 ? "Stop Audio for Selected PDFs" : "Stop Audio") {
                    onStopDocuments(ids)
                }
                Divider()
                Button(ids.count > 1 ? "Delete Selected PDFs" : "Delete", role: .destructive) {
                    onDeleteDocuments(ids)
                }
            }
            .onDrag {
                let ids = selection.contains(.document(document.id)) ? selectedDocumentIDs : [document.id]
                return NSItemProvider(object: ids.map(\.uuidString).joined(separator: ",") as NSString)
            }
    }

    private var selectedDocumentIDs: Set<UUID> {
        Set(selection.compactMap {
            guard case let .document(id) = $0 else { return nil }
            return id
        })
    }

    private func queuePosition(for id: UUID) -> (position: Int, total: Int)? {
        return onQueuePosition(id)
    }

    private func isProcessing(_ id: UUID) -> Bool {
        onIsProcessing(id)
    }
}

private struct PDFDropDelegate: DropDelegate {
    let onDrop: (Set<UUID>) -> Void

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.utf8PlainText])
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let accumulator = DropIDAccumulator()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier, options: nil) { item, _ in
                let text = (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let providerIDs = text.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
                accumulator.insert(Set(providerIDs))
                group.leave()
            }
        }
        group.notify(queue: .main) {
            onDrop(accumulator.snapshot())
        }
        return true
    }
}

private struct ImportDestinationPicker: View {
    let batch: ImportBatch
    let folders: [LibraryFolderNode]
    let onImport: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import \(batch.pdfs.count) PDF\(batch.pdfs.count == 1 ? "" : "s")")
                .font(.headline)
            Text("Choose where to add them.")
                .foregroundStyle(.secondary)
            List(selection: $destination) {
                Label("Unfiled", systemImage: "tray").tag(Optional<UUID>.none)
                OutlineGroup(folders, children: \.optionalChildren) { node in
                    Label(node.folder.name, systemImage: "folder").tag(Optional(node.folder.id))
                }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import") { onImport(destination) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct AudioGenerationProgressView: View {
    let progress: AudioGenerationProgress

    private var message: String {
        switch progress.phase {
        case .generatingParagraphs:
            return "Generating audio · \(progress.completedParagraphs) of \(progress.totalParagraphs) paragraphs"
        case .assembling:
            return "Assembling audiobook…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(progress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: progress.fractionCompleted)
                .progressViewStyle(.linear)
                .accessibilityLabel("Audio generation progress")
                .accessibilityValue(message)
        }
    }
}

private struct ParagraphActionBar: View {
    let paragraph: ParagraphRecord
    let audioReady: Bool
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.quote").foregroundStyle(.blue).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Page \(paragraph.pageIndex + 1)").font(.caption).foregroundStyle(.secondary)
                Text(paragraph.text).font(.callout).lineLimit(2).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Play From Here", action: onPlay)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!audioReady)
            Button(action: onDismiss) { Label("Dismiss paragraph actions", systemImage: "xmark").labelStyle(.iconOnly) }
                .buttonStyle(.plain)
                .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected paragraph on page \(paragraph.pageIndex + 1)")
    }
}

private struct LibraryRow: View {
    @ObservedObject var document: LibraryDocument
    let queuePosition: (position: Int, total: Int)?
    let isGenerating: Bool
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).lineLimit(2)
                if let queuePosition {
                    Text("In queue \(queuePosition.position)/\(queuePosition.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(format(document.resumePosition)) / \(format(document.audioDuration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if isGenerating {
                Button(action: onStop) {
                    Label("Stop generation", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Stop generation for this PDF")
                .accessibilityLabel("Stop generation for \(document.title)")
            }
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
