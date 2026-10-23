import AppKit
import SwiftUI

/// 왼쪽 캡처 이미지, 오른쪽 도구 막대 / 텍스트 / 상태 줄. 진행 중에는 맨 위에 얇은 진행 막대가 흐른다.
struct ResultView: View {
    @ObservedObject var model: ResultModel
    let textView: PlainTextView

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
            Picker("엔진", selection: $model.selectedEngine) {
                ForEach(model.engineOptions, id: \.self) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .fixedSize()
            .disabled(model.isRunning)

            Button("↻ 다시 인식") { model.onRecognizeAgain?(model.selectedEngine) }
                .disabled(model.isRunning || !model.canRecognizeAgain)
            Button("전체 복사") { model.onCopyAll?() }
                .disabled(model.isRunning)

            Spacer(minLength: 8)

            if phase == .verifying {
                Button("1차 결과 복사") { model.onCopyAll?() }
                Button("검사 건너뛰기") {
                    model.skipPressed = true
                    model.onSkipVerification?()
                }
                .disabled(model.skipPressed)
            }
            if model.isRunning {
                // esc는 ResultWindowController가 가로채 같은 취소로 보낸다.
                Button("취소") { model.onCancel?() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var textArea: some View {
        ResultTextArea(textView: textView, caretText: phase == .receiving ? model.session?.text : nil)
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
                    StatusLine(session: session, historyEngineName: model.historyEngineName, now: context.date)
                }
            } else {
                StatusLine(session: model.session, historyEngineName: model.historyEngineName, now: Date())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 상태 줄

private struct StatusLine: View {
    let session: RecognitionSession?
    let historyEngineName: String
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
            return "이미지 읽는 중… \(elapsed)초"
        case .receiving:
            return "텍스트 받는 중… \(session.lineCount)줄 · \(elapsed)초"
        case .verifying:
            return "정밀 검사 중… \(elapsed)초 · 편집은 검사 후"
        case .done:
            var parts = ""
            if !session.confusionMarks.isEmpty { parts += "확인 필요 \(session.confusionMarks.count)곳 · " }
            if !session.revisionMarks.isEmpty { parts += "검사로 수정 \(session.revisionMarks.count)곳 · " }
            return parts + "\(session.engineChoice.displayName) · \(elapsed)초"
        case .failed(let error):
            return "⚠︎ \(error.userMessage)"
        case .cancelled:
            return "취소됨 · \(elapsed)초"
        }
    }

    /// 진행 중일 때만 보인다.
    private var dots: String? {
        switch session?.phase {
        case .reading: "●○○"
        case .receiving: "✓●○"
        case .verifying: "✓✓●"
        default: nil
        }
    }
}

// MARK: - 진행 표시

/// 창 맨 위 2pt 막대. 밝은 띠가 왼쪽에서 오른쪽으로 계속 흐른다.
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

/// `.reading` 동안 텍스트 자리에 보이는 반짝이는 자리표시줄 3개.
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

// MARK: - 텍스트 영역

/// `RecognizedTextController.textView`를 스크롤 뷰에 넣어 보여 준다.
/// `caretText`가 nil이 아니면(`.receiving`) 텍스트 끝에 깜빡이는 막대를 그린다.
/// 이때 텍스트 뷰는 편집 잠금이라 시스템 커서가 보이지 않기 때문이다.
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

    /// 마지막 글자 바로 뒤(텍스트가 줄바꿈으로 끝나면 다음 줄 처음)의 커서 자리.
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

/// 0.5초마다 깜빡이는 세로 막대.
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
