import Foundation
import XCTest
@testable import iCapture

/// 정해 둔 이벤트를 차례로 내보내고, `thenThrow`가 있으면 그 오류로 끝나는 가짜 엔진.
/// `gate`가 있으면 이벤트를 하나 내기 전마다 `gate.wait()`로 멈춰서 테스트가 한 단계씩 풀어 준다.
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

/// `open()` 한 번이 `wait()` 한 번을 통과시킨다. 기다리는 쪽이 없으면 통과권을 쌓아 둔다.
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
    /// `.done` / `.failed` / `.cancelled`가 될 때까지 기다린다. 5초 안에 안 되면 테스트를 실패시킨다.
    func waitUntilFinished(file: StaticString = #filePath, line: UInt = #line) async {
        await waitFor("끝 상태", file: file, line: line) { $0.isEditable }
    }

    /// `phase`가 주어진 값이 될 때까지 기다린다. 5초 안에 안 되면 테스트를 실패시킨다.
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
