import XCTest
@testable import iCapture

@MainActor
final class RecognitionSessionTests: XCTestCase {
    func testHappyPathPhasesAndMarks() async {
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("<<KIND:sql>>\nWHERE u.level = 1")]), ocr: FakeOCR("WHERE u.1evel = 1"))
        XCTAssertEqual(s.phase, .reading)
        XCTAssertEqual(s.engineChoice, .claude(.sonnet))
        s.start(); await s.waitUntilFinished()
        XCTAssertEqual(s.phase, .done); XCTAssertEqual(s.kind, .sql)
        XCTAssertEqual(s.text, "WHERE u.level = 1"); XCTAssertEqual(s.confusionMarks, [NSRange(location: 8, length: 1)])
        XCTAssertEqual(s.revisionMarks, [])
        XCTAssertTrue(s.isEditable); XCTAssertFalse(s.isRunning)
    }

    func testReceivingPhaseAfterFirstDelta() async {
        let gate = TestGate()
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("<<KIND:sql>>\nSELECT 1"), .textDelta("\nFROM t")], gate: gate), ocr: FakeOCR(""))
        s.start()
        await gate.open()
        await s.waitUntil(.receiving)
        XCTAssertEqual(s.kind, .sql)
        XCTAssertEqual(s.text, "SELECT 1")
        XCTAssertEqual(s.lineCount, 1)
        XCTAssertTrue(s.isRunning); XCTAssertFalse(s.isEditable)

        await gate.open()
        await s.waitUntilFinished()
        XCTAssertEqual(s.phase, .done)
        XCTAssertEqual(s.lineCount, 2)
    }

    func testEmptyDeltaIsIgnored() async {
        let gate = TestGate()
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta(""), .textDelta("abc")], gate: gate), ocr: FakeOCR(""))
        s.start()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(s.phase, .reading)
        XCTAssertEqual(s.text, "")

        await gate.open()
        await s.waitUntilFinished()
        XCTAssertEqual(s.text, "abc")
    }

    func testLineCount() async {
        for (raw, expected) in [("", 0), ("a", 1), ("a\nb", 2), ("a\n", 1)] {
            let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("<<KIND:other>>\n" + raw)]), ocr: FakeOCR(""))
            s.start(); await s.waitUntilFinished()
            XCTAssertEqual(s.lineCount, expected, "본문: \(raw.debugDescription)")
        }
    }

    func testErrorAfterDeltasKeepsPartialText() async {
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("<<KIND:log>>\nError at")], thenThrow: RecognitionError.http(status: 529, message: "overloaded")), ocr: FakeOCR(""))
        s.start(); await s.waitUntilFinished()
        XCTAssertEqual(s.phase, .failed(.http(status: 529, message: "overloaded"))); XCTAssertEqual(s.text, "Error at"); XCTAssertTrue(s.isEditable)
        XCTAssertEqual(s.kind, .log)
    }

    func testNonRecognitionErrorBecomesNetworkError() async {
        let error = PlainError(reason: "timed out")
        let s = RecognitionSession(png: Data(), engine: FakeEngine([], thenThrow: error), ocr: FakeOCR(""))
        s.start(); await s.waitUntilFinished()
        XCTAssertEqual(s.phase, .failed(.network(String(describing: error))))
    }

    func testOCRFailureFinishesWithoutConfusionMarks() async {
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("<<KIND:sql>>\nu.level")]), ocr: FailingOCR())
        s.start(); await s.waitUntilFinished()
        XCTAssertEqual(s.phase, .done)
        XCTAssertEqual(s.text, "u.level")
        XCTAssertEqual(s.confusionMarks, [])
    }

    func testCompletionStripsTrailingFence() async {
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("<<KIND:sql>>\n```sql\nSELECT 1\n```")]), ocr: FakeOCR(""))
        s.start(); await s.waitUntilFinished()
        XCTAssertEqual(s.text, "SELECT 1")
    }

    func testCancelKeepsTextAndStops() async {
        let gate = TestGate()
        let clock = FakeClock()
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("<<KIND:log>>\nline 1"), .textDelta("\nline 2")], gate: gate), ocr: FakeOCR(""), clock: { clock.now })
        s.start()
        await gate.open()
        await s.waitUntil(.receiving)

        clock.now = Date(timeIntervalSince1970: 4)
        s.cancel()
        XCTAssertEqual(s.phase, .cancelled)
        XCTAssertEqual(s.text, "line 1")
        XCTAssertTrue(s.isEditable); XCTAssertFalse(s.isRunning)
        XCTAssertEqual(s.finishedAt, Date(timeIntervalSince1970: 4))

        clock.now = Date(timeIntervalSince1970: 9)
        s.cancel()
        s.skipVerification()
        XCTAssertEqual(s.phase, .cancelled)
        XCTAssertEqual(s.finishedAt, Date(timeIntervalSince1970: 4))

        await gate.open()
    }

    func testCancelledSessionIgnoresLateEvents() async {
        let gate = TestGate()
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("<<KIND:sql>>\nSELECT"), .textDelta(" 1"), .verifying, .revisedText("<<KIND:log>>\nX")], gate: gate), ocr: FakeOCR(""))
        s.start()
        await gate.open()
        await s.waitUntil(.receiving)
        s.cancel()

        for _ in 0..<3 { await gate.open() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(s.phase, .cancelled)
        XCTAssertEqual(s.text, "SELECT")
        XCTAssertEqual(s.kind, .sql)
        XCTAssertEqual(s.revisionMarks, [])
        XCTAssertEqual(s.confusionMarks, [])
    }

    func testVerificationFlowSetsRevisionMarks() async {
        let gate = TestGate()
        let e = FakeEngine([.textDelta("<<KIND:sql>>\nu.1evel"), .verifying, .revisedText("<<KIND:sql>>\nu.level")], gate: gate)
        let s = RecognitionSession(png: Data(), engine: e, ocr: FakeOCR("u.level"))
        s.start()
        await gate.open(); await gate.open()
        await s.waitUntil(.verifying)
        XCTAssertFalse(s.isEditable)
        XCTAssertEqual(s.text, "u.1evel")

        await gate.open()
        await s.waitUntilFinished()
        XCTAssertEqual(s.phase, .done)
        XCTAssertEqual(s.text, "u.level")
        XCTAssertEqual(s.revisionMarks, [NSRange(location: 2, length: 1)])
        XCTAssertEqual(s.confusionMarks, [])
    }

    func testSkipVerificationFinishesWithFirstPass() async {
        let gate = TestGate()
        let e = FakeEngine([.textDelta("<<KIND:sql>>\nu.1evel"), .verifying, .revisedText("<<KIND:sql>>\nu.level")], gate: gate)
        let s = RecognitionSession(png: Data(), engine: e, ocr: FakeOCR("u.level"))
        s.start()
        await gate.open(); await gate.open()
        await s.waitUntil(.verifying)

        s.skipVerification()
        await s.waitUntilFinished()
        XCTAssertEqual(s.phase, .done)
        XCTAssertEqual(s.text, "u.1evel")
        XCTAssertEqual(s.revisionMarks, [])
        XCTAssertEqual(s.confusionMarks, [NSRange(location: 2, length: 1)])

        await gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(s.text, "u.1evel")
        XCTAssertEqual(s.revisionMarks, [])
        XCTAssertEqual(s.phase, .done)
    }

    func testSkipVerificationIsIgnoredOutsideVerifying() async {
        let gate = TestGate()
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("abc"), .textDelta("def")], gate: gate), ocr: FakeOCR(""))
        s.start()
        await gate.open()
        await s.waitUntil(.receiving)
        s.skipVerification()
        XCTAssertEqual(s.phase, .receiving)

        await gate.open()
        await s.waitUntilFinished()
        XCTAssertEqual(s.text, "abcdef")
    }

    func testElapsedFreezesWhenFinished() async {
        let gate = TestGate()
        let clock = FakeClock()
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("a")], gate: gate), ocr: FakeOCR(""), clock: { clock.now })
        XCTAssertEqual(s.elapsed(now: Date(timeIntervalSince1970: 5)), 0)

        s.start()
        XCTAssertEqual(s.startedAt, Date(timeIntervalSince1970: 0))
        XCTAssertNil(s.finishedAt)
        XCTAssertEqual(s.elapsed(now: Date(timeIntervalSince1970: 2)), 2)

        clock.now = Date(timeIntervalSince1970: 3)
        await gate.open()
        await s.waitUntilFinished()
        XCTAssertEqual(s.finishedAt, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(s.elapsed(now: Date(timeIntervalSince1970: 10)), 3)
    }

    func testStartTwiceIsNoOp() async {
        let clock = FakeClock()
        let s = RecognitionSession(png: Data(), engine: FakeEngine([.textDelta("a")]), ocr: FakeOCR(""), clock: { clock.now })
        s.start()
        clock.now = Date(timeIntervalSince1970: 7)
        s.start()
        XCTAssertEqual(s.startedAt, Date(timeIntervalSince1970: 0))
        await s.waitUntilFinished()
        XCTAssertEqual(s.text, "a")
    }
}

@MainActor
private final class FakeClock {
    var now = Date(timeIntervalSince1970: 0)
}

private struct PlainError: Error {
    let reason: String
}

private struct FailingOCR: OCRProvider {
    func recognizeText(png: Data) async throws -> String {
        throw PlainError(reason: "ocr failed")
    }
}
