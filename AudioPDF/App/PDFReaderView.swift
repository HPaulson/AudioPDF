import AppKit
import PDFKit
import QuartzCore
import SwiftUI
#if canImport(ReaderCore)
import ReaderCore
#endif

@MainActor
final class InteractivePDFView: PDFView {
    var paragraphs: [ParagraphRecord] = []
    var onParagraphClicked: ((UUID) -> Void)?
    var onPlayFromHere: ((UUID) -> Void)?
    var resumeActionsEnabled = false
    var locksManualScrolling = false {
        didSet {
            guard oldValue != locksManualScrolling,
                  let scrollView = documentView?.enclosingScrollView else { return }
            scrollView.verticalScroller?.isEnabled = !locksManualScrolling
            scrollView.horizontalScroller?.isEnabled = !locksManualScrolling
        }
    }

    private var fallbackHighlights: [(paragraph: ParagraphRecord, color: NSColor)] = []
    private var contextParagraphID: UUID?

    func setFallbackHighlights(_ highlights: [(paragraph: ParagraphRecord, color: NSColor)]) {
        fallbackHighlights = highlights
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // OCR paragraphs have coordinates, but the source PDF has no text
        // layer. PDFKit therefore cannot create a PDFSelection for them. Draw
        // the OCR geometry directly in PDFView coordinates as a fallback.
        for highlight in fallbackHighlights {
            guard let page = document?.page(at: highlight.paragraph.pageIndex) else { continue }
            let rect = convert(
                CGRect(
                    x: highlight.paragraph.pdfBoundingBox.x,
                    y: highlight.paragraph.pdfBoundingBox.y,
                    width: highlight.paragraph.pdfBoundingBox.width,
                    height: highlight.paragraph.pdfBoundingBox.height
                ),
                from: page
            )
            guard rect.intersects(dirtyRect) else { continue }
            highlight.color.setFill()
            rect.fill()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !locksManualScrolling else { return }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let scrollingKeys: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        guard !locksManualScrolling || !scrollingKeys.contains(event.keyCode) else { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard resumeActionsEnabled else { return }
        if let paragraph = paragraph(at: event) {
            onParagraphClicked?(paragraph.id)
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard resumeActionsEnabled else { return nil }
        guard let paragraph = paragraph(at: event) else {
            return super.menu(for: event)
        }
        contextParagraphID = paragraph.id
        onParagraphClicked?(paragraph.id)

        let menu = NSMenu(title: "Paragraph")
        let play = NSMenuItem(
            title: "Play From Here",
            action: #selector(playFromContextMenu),
            keyEquivalent: ""
        )
        play.target = self
        play.isEnabled = resumeActionsEnabled
        menu.addItem(play)
        return menu
    }

    @objc private func playFromContextMenu() {
        // The menu item is disabled while audio is unavailable, loading, or
        // generating. Keep the action guarded as well so it cannot be invoked
        // through an already-created menu item during a state transition.
        guard resumeActionsEnabled,
              let contextParagraphID else { return }
        onPlayFromHere?(contextParagraphID)
    }

    private func paragraph(at event: NSEvent) -> ParagraphRecord? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true),
              let pageIndex = document?.index(for: page) else { return nil }
        let pagePoint = convert(viewPoint, to: page)
        guard let index = ParagraphLocator.paragraphIndex(
            pageIndex: pageIndex,
            x: pagePoint.x,
            y: pagePoint.y,
            in: paragraphs
        ) else { return nil }
        return paragraphs[index]
    }
}

@MainActor
struct PDFReaderView: NSViewRepresentable {
    let document: PDFDocument?
    let paragraphs: [ParagraphRecord]
    let currentParagraph: ParagraphRecord?
    let selectedParagraph: ParagraphRecord?
    let followsPlayback: Bool
    let locksManualScrolling: Bool
    let resumeActionsEnabled: Bool
    let scrollRequestID: UUID
    let onParagraphClicked: (UUID) -> Void
    let onPlayFromHere: (UUID) -> Void

    final class Coordinator {
        var lastCurrentParagraphID: UUID?
        var lastSelectedParagraphID: UUID?
        var lastScrollRequestID: UUID?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        return view
    }

    func updateNSView(_ view: InteractivePDFView, context: Context) {
        view.paragraphs = paragraphs
        view.onParagraphClicked = onParagraphClicked
        view.onPlayFromHere = onPlayFromHere
        view.resumeActionsEnabled = resumeActionsEnabled
        view.locksManualScrolling = locksManualScrolling

        if view.document !== document {
            view.document = document
            view.highlightedSelections = []
            view.setFallbackHighlights([])
            context.coordinator.lastCurrentParagraphID = nil
            context.coordinator.lastSelectedParagraphID = nil
            context.coordinator.lastScrollRequestID = nil
        }

        let currentID = currentParagraph?.id
        let selectedID = selectedParagraph?.id
        let currentChanged = currentID != context.coordinator.lastCurrentParagraphID
        if currentID != context.coordinator.lastCurrentParagraphID ||
            selectedID != context.coordinator.lastSelectedParagraphID {
            updateHighlights(in: view)
            context.coordinator.lastCurrentParagraphID = currentID
            context.coordinator.lastSelectedParagraphID = selectedID
        }

        let explicitRequest = scrollRequestID != context.coordinator.lastScrollRequestID
        context.coordinator.lastScrollRequestID = scrollRequestID

        if let currentParagraph, explicitRequest || (followsPlayback && currentChanged) {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                ensureVisible(currentParagraph, in: view, animated: true)
            }
        }
    }

    @MainActor
    private func updateHighlights(in view: PDFView) {
        var selections: [PDFSelection] = []
        var fallbackHighlights: [(paragraph: ParagraphRecord, color: NSColor)] = []
        if let currentParagraph,
           let selection = selection(for: currentParagraph, in: view) {
            selection.color = .systemYellow.withAlphaComponent(0.42)
            selections.append(selection)
        } else if let currentParagraph,
                  document?.page(at: currentParagraph.pageIndex) != nil {
            fallbackHighlights.append((currentParagraph, .systemYellow.withAlphaComponent(0.42)))
        }
        if let selectedParagraph,
           selectedParagraph.id != currentParagraph?.id,
           let selection = selection(for: selectedParagraph, in: view) {
            selection.color = .systemBlue.withAlphaComponent(0.26)
            selections.append(selection)
        } else if let selectedParagraph,
                  selectedParagraph.id != currentParagraph?.id,
                  document?.page(at: selectedParagraph.pageIndex) != nil {
            fallbackHighlights.append((selectedParagraph, .systemBlue.withAlphaComponent(0.26)))
        }
        view.highlightedSelections = selections
        if let interactiveView = view as? InteractivePDFView {
            interactiveView.setFallbackHighlights(fallbackHighlights)
        }
    }

    @MainActor
    private func selection(for paragraph: ParagraphRecord, in view: PDFView) -> PDFSelection? {
        guard let page = document?.page(at: paragraph.pageIndex) else { return nil }
        guard let selection = page.selection(for: rect(for: paragraph)),
              !(selection.string?.isEmpty ?? true) else { return nil }
        return selection
    }

    @MainActor
    private func ensureVisible(
        _ paragraph: ParagraphRecord,
        in view: PDFView,
        animated: Bool
    ) {
        guard let page = document?.page(at: paragraph.pageIndex) else { return }
        let paragraphRect = rect(for: paragraph)
        guard let documentView = view.documentView,
              let scrollView = documentView.enclosingScrollView else {
            view.go(to: paragraphRect, on: page)
            return
        }

        view.layoutSubtreeIfNeeded()
        let pdfViewRect = view.convert(paragraphRect, from: page)
        let documentRect = documentView.convert(pdfViewRect, from: view)
        let visibleRect = scrollView.documentVisibleRect
        let comfortableRect = visibleRect.insetBy(
            dx: visibleRect.width * 0.06,
            dy: visibleRect.height * 0.18
        )
        guard !comfortableRect.contains(documentRect) else { return }

        let clipView = scrollView.contentView
        let documentBounds = documentView.bounds
        var origin = clipView.bounds.origin
        origin.y = documentRect.midY - clipView.bounds.height * 0.45
        origin.x = min(max(origin.x, documentBounds.minX), max(documentBounds.minX, documentBounds.maxX - clipView.bounds.width))
        origin.y = min(max(origin.y, documentBounds.minY), max(documentBounds.minY, documentBounds.maxY - clipView.bounds.height))

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clipView.animator().setBoundsOrigin(origin)
            }
        } else {
            clipView.setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clipView)
    }

    private func rect(for paragraph: ParagraphRecord) -> CGRect {
        let bounds = paragraph.pdfBoundingBox
        return CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }
}
