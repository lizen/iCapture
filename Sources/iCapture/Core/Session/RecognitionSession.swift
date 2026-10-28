import Combine
import Foundation

enum RecognitionPhase: Equatable, Sendable {
    case reading, receiving, verifying, done, failed(RecognitionError), cancelled
}

extension RecognitionPhase {
    /// Whether a session that ended in this phase should overwrite the history entry with its result (text, kind, engine).
    /// A failure or cancel with no text keeps the previous result (Ruling 14). false while still running.
    func shouldReplaceStoredResult(text: String) -> Bool {
        switch self {
        case .done: true
        case .failed, .cancelled: !text.isEmpty
        case .reading, .receiving, .verifying: false
        }
    }
}

/// State machine for recognizing one capture.
/// Runs the engine stream and the built-in OCR together, and computes look-alike and check-revision marks when done.
@MainActor final class RecognitionSession: ObservableObject {
    let png: Data
    let engineChoice: EngineChoice
    @Published private(set) var phase: RecognitionPhase = .reading
    @Published private(set) var text = ""
    @Published private(set) var kind: TextKind = .other
    @Published private(set) var confusionMarks: [NSRange] = []
    @Published private(set) var revisionMarks: [NSRange] = []
    private(set) var startedAt: Date
    private(set) var finishedAt: Date?

    private let engine: any RecognitionEngine
    private let ocr: any OCRProvider
    private let clock: @MainActor () -> Date

    private var hasStarted = false
    private var isCompleting = false
    /// Bumped on every finish, cancel or skipped check. Stops work from an earlier generation from changing state.
    private var generation = 0
    private var work: Task<Void, Never>?
    private var ocrTask: Task<String, Error>?

    private var parser = KindTagParser()
    private var raw = ""
    private var firstPass: String?
    private var revised: (kind: TextKind, body: String)?

    init(png: Data, engine: any RecognitionEngine, ocr: any OCRProvider, clock: @escaping @MainActor () -> Date = Date.init) {
        self.png = png
        self.engineChoice = engine.choice
        self.engine = engine
        self.ocr = ocr
        self.clock = clock
        self.startedAt = clock()
    }

    var lineCount: Int {
        guard let last = text.last else { return 0 }
        let newlines = text.reduce(0) { $1.isNewline ? $0 + 1 : $0 }
        return last.isNewline ? newlines : newlines + 1
    }

    var isEditable: Bool {
        switch phase {
        case .done, .failed, .cancelled: true
        case .reading, .receiving, .verifying: false
        }
    }

    var isRunning: Bool { !isEditable }

    func elapsed(now: Date) -> TimeInterval {
        guard hasStarted else { return 0 }
        return (finishedAt ?? now).timeIntervalSince(startedAt)
    }

    func start() {
        guard !hasStarted, isRunning else { return }
        hasStarted = true
        startedAt = clock()

        let png = png
        let ocr = ocr
        ocrTask = Task { try await ocr.recognizeText(png: png) }

        let stream = engine.recognize(png: png)
        let token = generation
        work = Task { @MainActor in
            do {
                for try await event in stream {
                    guard token == generation else { return }
                    handle(event)
                }
                guard token == generation else { return }
                let result = revised ?? KindTagParser.parseComplete(raw)
                await complete(kind: result.kind, body: result.body, token: token)
            } catch {
                guard token == generation else { return }
                fail(error)
            }
        }
    }

    func cancel() {
        guard isRunning else { return }
        stop()
        phase = .cancelled
    }

    func skipVerification() {
        guard phase == .verifying, !isCompleting, let firstPass else { return }
        generation += 1
        work?.cancel()
        let token = generation
        let kind = kind
        revisionMarks = []
        work = Task { @MainActor in
            await complete(kind: kind, body: firstPass, token: token)
        }
    }

    private func handle(_ event: RecognitionEvent) {
        switch event {
        case .textDelta(let delta):
            guard !delta.isEmpty else { return }
            raw += delta
            let parsed = parser.consume(delta)
            if let parsedKind = parsed.kind { kind = parsedKind }
            text = parsed.body
            if phase == .reading { phase = .receiving }
        case .verifying:
            let result = KindTagParser.parseComplete(raw)
            firstPass = result.body
            kind = result.kind
            text = result.body
            phase = .verifying
        case .revisedText(let revisedRaw):
            let result = KindTagParser.parseComplete(revisedRaw)
            revisionMarks = TextDiff.changedRanges(from: firstPass ?? text, to: result.body)
            revised = result
            kind = result.kind
            text = result.body
        }
    }

    /// Settles the final body, waits for the OCR result, computes look-alike marks, then finishes as `.done`.
    private func complete(kind: TextKind, body: String, token: Int) async {
        isCompleting = true
        self.kind = kind
        text = body
        let reference = try? await ocrTask?.value
        guard token == generation else { return }
        confusionMarks = reference.map { ConfusionMarker.marks(candidate: body, reference: $0, kind: kind) } ?? []
        stop()
        phase = .done
    }

    private func fail(_ error: Error) {
        stop()
        phase = .failed(error as? RecognitionError ?? .network(String(describing: error)))
    }

    /// Stops all in-flight work and records the finish time. Events and results arriving later are ignored.
    private func stop() {
        generation += 1
        work?.cancel()
        ocrTask?.cancel()
        finishedAt = clock()
    }
}
