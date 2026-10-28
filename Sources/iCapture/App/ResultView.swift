import AppKit
import SwiftUI

/// Capture on the left; toolbar / text / status line on the right. A thin progress bar runs along the top while working.
struct ResultView: View {
    @ObservedObject var model: ResultModel
    /// Observed so the mark counts ("needs review N") follow user edits.
    @ObservedObject var text: RecognizedTextController

    private var phase: RecognitionPhase? { model.session?.phase }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                imagePane
                    .frame(width: geometry.size.width * 0.42)
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    textArea
                    Divider()
                    statusLine
                }
                .frame(maxWidth: .infinity)
            }
        }
        .overlay(alignment: .top) {
            if model.isRunning { FlowingProgressBar() }
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    private var imagePane: some View {
        ZStack {
            Color(white: 0.12)
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Engine", selection: $model.selectedEngine) {
                ForEach(model.engineOptions, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .fixedSize()
            .disabled(model.isRunning)

            Button("↻ Recognize Again") { model.onRecognizeAgain?(model.selectedEngine) }
                .disabled(model.isRunning || !model.canRecognizeAgain)
            Button("Copy All") { model.onCopyAll?() }
                .disabled(model.isRunning)

            Spacer(minLength: 8)

            if phase == .verifying {
                Button("Copy First Pass") { model.onCopyAll?() }
                Button("Skip Check") {
                    model.skipPressed = true
                    model.onSkipVerification?()
                }
                .disabled(model.skipPressed)
            }
            if model.isRunning {
                // esc is intercepted by ResultWindowController and sent as the same cancel.
                Button("Cancel") { model.onCancel?() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var textArea: some View {
        ResultTextArea(textView: text.textView, caretText: phase == .receiving ? model.session?.text : nil)
            .opacity(phase == .verifying ? 0.5 : 1)
            .overlay(alignment: .topLeading) {
                if phase == .reading { SkeletonLines().padding(14) }
            }
    }

    @ViewBuilder
    private var statusLine: some View {
        Group {
            if let session = model.session, session.isRunning {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    StatusLine(session: session, historyEngineName: model.historyEngineName, marks: markCounts, now: context.date)
                }
            } else {
                StatusLine(session: model.session, historyEngineName: model.historyEngineName, marks: markCounts, now: Date())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var markCounts: (confusion: Int, revision: Int) {
        (text.confusionMarks.count, text.revisionMarks.count)
    }
}

// MARK: - Status line

private struct StatusLine: View {
    let session: RecognitionSession?
    let historyEngineName: String
    /// Current mark counts of the text area. The session's values are fixed at completion and miss later user fixes.
    let marks: (confusion: Int, revision: Int)
    let now: Date

    var body: some View {
        HStack {
            Text(message)
                .foregroundStyle(isFailure ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let dots {
                Text(dots).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
    }

    private var isFailure: Bool {
        if case .failed = session?.phase { return true }
        return false
    }

    private var message: String {
        guard let session else { return historyEngineName }
        let elapsed = String(format: "%.1f", session.elapsed(now: now))
        switch session.phase {
        case .reading:
            return String(localized: "Reading image… \(elapsed)s")
        case .receiving:
            let lines = String(localized: "\(session.lineCount) lines")
            return String(localized: "Receiving text… \(lines) · \(elapsed)s")
        case .verifying:
            return String(localized: "Checking… \(elapsed)s · editing after the check")
        case .done:
            var parts = ""
            if marks.confusion > 0 { parts += String(localized: "\(marks.confusion) to review") + " · " }
            if marks.revision > 0 { parts += String(localized: "\(marks.revision) fixed by check") + " · " }
            return parts + String(localized: "\(session.engineChoice.displayName) · \(elapsed)s")
        case .failed(let error):
            return "⚠︎ \(error.userMessage)"
        case .cancelled:
            return String(localized: "Cancelled · \(elapsed)s")
        }
    }

    /// Visible only while running.
    private var dots: String? {
        switch session?.phase {
        case .reading: "●○○"
        case .receiving: "✓●○"
        case .verifying: "✓✓●"
        default: nil
        }
    }
}

// MARK: - Progress indicator

/// A 2pt bar along the top of the window. A bright band keeps sliding from left to right.
private struct FlowingProgressBar: View {
    private let period: TimeInterval = 1.4

    var body: some View {
        TimelineView(.animation) { context in
            GeometryReader { geometry in
                let progress = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let bandWidth = geometry.size.width * 0.3
                LinearGradient(colors: [.clear, .accentColor, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: bandWidth)
                    .offset(x: -bandWidth + (geometry.size.width + bandWidth) * progress)
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Three shimmering placeholder lines shown in place of the text during `.reading`.
private struct SkeletonLines: View {
    var body: some View {
        TimelineView(.animation) { context in
            let wave = (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2) + 1) / 2
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array([0.85, 0.65, 0.75].enumerated()), id: \.offset) { _, fraction in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12 + 0.18 * wave))
                        .frame(width: 320 * fraction, height: 12)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Text area

/// Shows `RecognizedTextController.textView` inside a scroll view.
/// When `caretText` is non-nil (`.receiving`), draws a blinking bar after the end of the text,
/// because the text view is locked for editing then and the system caret isn't visible.
private struct ResultTextArea: NSViewRepresentable {
    let textView: PlainTextView
    let caretText: String?

    @MainActor final class Coordinator {
        let caret = StreamingCaretView()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView

        textView.addSubview(context.coordinator.caret)
        context.coordinator.caret.isHidden = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let caret = context.coordinator.caret
        guard caretText != nil else {
            caret.isHidden = true
            return
        }
        caret.frame = Self.endOfTextRect(in: textView)
        caret.isHidden = false
    }

    /// The caret position right after the last character (the start of the next line if the text ends with a newline).
    private static func endOfTextRect(in textView: NSTextView) -> NSRect {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return .zero }
        layoutManager.ensureLayout(for: container)
        let origin = textView.textContainerOrigin
        let text = textView.string as NSString
        let width: CGFloat = 2

        if text.length == 0 || text.character(at: text.length - 1) == 0x0A {
            let extra = layoutManager.extraLineFragmentRect
            let lineHeight = layoutManager.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular))
            return NSRect(
                x: origin.x + extra.minX + container.lineFragmentPadding,
                y: origin.y + extra.minY,
                width: width,
                height: extra.height > 0 ? extra.height : lineHeight
            )
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: text.length - 1)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSRect(x: origin.x + glyphRect.maxX, y: origin.y + line.minY, width: width, height: line.height)
    }
}

/// A vertical bar that blinks every 0.5 seconds.
final class StreamingCaretView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textColor.cgColor
    }

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            if isHidden {
                layer?.removeAnimation(forKey: "blink")
            } else {
                let blink = CABasicAnimation(keyPath: "opacity")
                blink.fromValue = 1
                blink.toValue = 0
                blink.duration = 0.5
                blink.autoreverses = true
                blink.repeatCount = .infinity
                layer?.add(blink, forKey: "blink")
            }
        }
    }
}
