import Foundation
import XCTest

/// A fake engine that emits preset events in order and, with `thenThrow`, ends with that error.
/// With `gate`, it pauses on `gate.wait()` before each event so the test can release it step by step.
struct FakeEngine: RecognitionEngine {
    let choice: EngineChoice = .claude(.sonnet)
    private let events: [RecognitionEvent]
    private let thenThrow: Error?
    private let gate: TestGate?

    init(_ events: [RecognitionEvent], thenThrow: Error? = nil, gate: TestGate? = nil) {
        self.events = events
        self.thenThrow = thenThrow
        self.gate = gate
    }

    func recognize(png: Data) -> AsyncThrowingStream<RecognitionEvent, Error> {
        let events = events
        let thenThrow = thenThrow
        let gate = gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events {
                    if let gate { await gate.wait() }
                    continuation.yield(event)
                }
                continuation.finish(throwing: thenThrow)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Each `open()` lets one `wait()` through. Without a waiter, the pass is banked.
actor TestGate {
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

struct FakeOCR: OCRProvider {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    func recognizeText(png: Data) async throws -> String {
        text
    }
}

extension RecognitionSession {
    /// Waits until `.done`, `.failed` or `.cancelled`. Fails the test if that doesn't happen within 5 seconds.
    func waitUntilFinished(file: StaticString = #filePath, line: UInt = #line) async {
        await waitFor("끝 상태", file: file, line: line) { $0.isEditable }
    }

    /// Waits until `phase` equals the given value. Fails the test if that doesn't happen within 5 seconds.
    func waitUntil(_ phase: RecognitionPhase, file: StaticString = #filePath, line: UInt = #line) async {
        await waitFor("\(phase)", file: file, line: line) { $0.phase == phase }
    }

    private func waitFor(
        _ description: String,
        file: StaticString,
        line: UInt,
        _ condition: (RecognitionSession) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(self) {
            if Date() > deadline {
                XCTFail("\(description)을(를) 기다리다 시간 초과 — 현재 phase: \(phase)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
