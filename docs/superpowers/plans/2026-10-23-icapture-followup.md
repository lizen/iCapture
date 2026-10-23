# iCapture v1 — 직접 확인할 것과 남은 일

구현 계획(`2026-10-23-icapture.md`)을 마친 뒤 정리한 문서입니다. 자동 테스트로 확인할 수 없는 화면 동작, 나중에 처리할 작은 개선점, 구현 중에 내린 판단을 모았습니다.

## 1. 직접 눌러 보고 확인할 것

실행: `make xcode-run` (설정 → Claude API 키 입력 후)

**캡처와 권한**
1. 처음 `⌘⇧2`를 누르면 화면 기록 권한을 묻는다. 허용 후 앱을 다시 실행한다.
2. 다시 빌드한 뒤에도 권한을 또 묻지 않는다.
3. 드래그하면 결과 창이 바로 열리고, 이미지 → 자리표시줄 → 글자 스트리밍 → 완료 순서로 상태 줄이 바뀐다.
4. `esc`를 누르거나 클릭만 하면 캡처되지 않고, 원래 쓰던 앱에 바로 타이핑된다.
5. 모니터가 두 대라면 보조 모니터에서도 정확한 영역이 찍힌다.
6. 영역 선택 중 `⌘Tab`으로 다른 앱으로 가면 선택이 취소되고, 이후 단축키가 다시 동작한다.

**결과 창**
7. 앱을 새로 띄운 뒤 첫 캡처에서 클릭 없이 `⌘A` → `⌘C`가 동작하고, VS Code에 서식 없이 붙는다. "전체 복사"도 같다.
8. 글자를 고치고 `⌘Z` / `⌘⇧Z`가 동작한다. "다시 인식" 뒤 `⌘Z`로 이전 결과로 돌아간다.
9. 노란 표시 글자를 고치면 그 표시만 사라지고 "확인 필요 N곳"이 바로 줄어든다. 한글 입력(IME)으로 고쳐도 다른 표시는 남는다.
10. 인식 중 `esc`를 누르면 받은 텍스트가 남고 편집할 수 있다.
11. 인식 중 `⌘⇧2` → `esc`를 누르면 인식이 계속된다. 영역을 고르면 그때 이전 인식이 취소되고 글자가 섞이지 않는다.
12. 다른 앱을 보는 사이 인식이 끝나면 메뉴 막대 아이콘에 초록 점이 붙고, 결과 창을 열면 사라진다.

**이력**
13. 11번 캡처하면 `hist/` 폴더가 10개로 유지되고, 메뉴에는 최근 5개, 이력 창(`⌘Y`)에는 10개가 최신순으로 보인다.
14. 이력 창에서 검색·"이력 비우기"·"결과 창에서 열기"가 동작한다.
15. 글자를 고친 뒤 1초 안에 `⌘Q` → 다시 실행해 이력에서 열면 고친 내용이 남아 있다.
16. Nativ를 끈 채 "다시 인식"이 실패해도 이력의 텍스트는 그대로다(창은 비지만 `⌘Z`로 되돌릴 수 있다).

**엔진·설정**
17. Nativ 서버를 끈 채 Nativ 엔진으로 인식하면 연결 안내가 빨간색으로 나온다. Nativ를 켜고 비전 모델을 올리면 엔진 목록에 `Nativ: <id>`가 보이고 인식된다.
18. API 키를 비우고 인식하면 "설정에서 Claude API 키를 입력해 주세요."가 나온다.
19. 설정에서 키를 넣고 Return 없이 `⌘Q` → 다시 열어도 키가 저장돼 있다. 앞뒤 공백은 자동으로 지워진다.
20. 단축키를 바꾸면 새 조합이 바로 동작하고 메뉴 표시도 바뀐다. 다른 앱이 쓰는 조합이면 안내가 뜨고 이전 조합이 유지된다.
21. "로그인할 때 자동 실행" 토글이 동작한다.
22. 빌더가 정한 문구(검색 자리표시, 빈 목록, 설정 라벨, 창 제목 "이력"/"설정", 다시 연 항목의 상태 줄, 메뉴의 "(텍스트 없음)")가 어색하지 않은지 본다.

## 2. 정확도 측정

기본은 로컬 서버만 재서 비용이 들지 않는다.

```bash
ICAPTURE_ACCURACY=1 make -C ~/github/iCapture accuracy
```

- 로컬 서버 주소·모델을 바꾸려면 `LOCAL_BASE_URL=http://127.0.0.1:8000`(vLLM 등), `LOCAL_MODEL=<모델 id>`, `LOCAL_API_KEY=<키>`를 앞에 붙인다. 모델을 안 주면 메모리에 올라간 비전 모델을 고른다.
- Claude도 비교하려면 `ANTHROPIC_API_KEY`를 함께 준다(요청 18회, API 비용 발생).
- 결과는 `build/accuracy-report.md`. 엔진마다 스펙 8장 기준(SQL·로그에서 표시 없는 오류 0) 판정이 나온다. 못 미치면 지시문, 이미지 전처리, 다른 모델 같은 다음 수단을 함께 정한다.

## 3. 나중에 처리할 작은 개선점

작업별 검토에서 나온 Minor 항목 가운데 병합 전 수정 묶음에 들어가지 않은 것들입니다.

- Task 1: minor (deferred): Makefile `export DEVELOPER_DIR ?= /Applications/Xcode.app/...` hardcodes Xcode path
- Task 1: minor (deferred): `make xcode-run` uses `open` — stale running instance is re-activated instead of new build (add pkill first)
- Task 1: minor (deferred): `make test` adds -project/-derivedDataPath; Task 12 `accuracy` should reuse same flags
- Task 2: minor (deferred): testPromptConstants checks only prefix/suffix — full system literal unguarded
- Task 2: minor (deferred): KindTagParser.swift:45 dead `?? (.other, raw)` fallback
- Task 2: minor (deferred): malformed first line `<<KIND:sql>` / `<<KIND:sql>> SELECT` passes through into body; untested
- Task 2: minor (deferred): CRLF input not handled (`\r\n` is one Character) — matters only if a local model emits CRLF
- Task 2: minor (deferred): untested edges — parseComplete without tag, last line ```json, open+close fence only, partial `<<KIND:sq` hold
- Task 3: minor (deferred): no test that consumer cancellation cancels the URL task (onTermination)
- Task 3: minor (deferred): no fixture with \r\n line endings or Korean text_delta; stub delivers body in one chunk
- Task 3: minor (deferred): dead `if let event` in EOF flush (ClaudeEngine.swift ~143)
- Task 3: minor (deferred): SSE error event with non-JSON data swallowed; stream ending without message_stop = success
- Task 3: minor (deferred): ImageEncoder resamples the previous result each 0.8 step (compounding blur) — resizing from original would be sharper for text; relevant to accuracy
- Task 3: minor (deferred): StubURLProtocol.canned not reset between tests
- Task 4: minor (deferred): `[DONE]` sets flag but keeps draining until server closes
- Task 4: minor (deferred): `SSEParser.forEachEvent` concrete over URLSession.AsyncBytes — generic AsyncSequence<UInt8> would allow direct splitter tests (CRLF, EOF w/o newline)
- Task 4: minor (deferred): catch chain + non-200 drain duplicated between ClaudeEngine and NativEngine
- Task 4: minor (deferred): NativEngine test gaps — cancellation, model entry w/o id, /v1/models 200 invalid JSON
- Task 5: minor (deferred): MarkRanges boundary cases (replace ending at mark start, insert at start/inside/end, spanning delete, merge) verified by reviewer probe but untested
- Task 5: minor (deferred): ConfusionMarker untested branches — unequal-length hunk, 3 vs 4 cap, emoji offsets, merge, `|` under .sql vs .table
- Task 5: minor (deferred): VisionOCR Task.detached ignores caller cancellation (runs to completion, blocks a pool thread)
- Task 5: minor (deferred): VisionOCR invalidImage path and line grouping untested
- Task 5: minor (deferred): shared helpers are module-level free functions with generic names
- Task 6: minor (deferred): skipVerification after `.revisedText` but before stream end pairs first-pass body with revised kind — store firstPass as (kind, body)
- Task 6: minor (deferred): in-loop generation guard not forced by a test (late events dropped by stream termination instead)
- Task 6: minor (deferred): no tests for cancel during OCR await, skip→cancel before OCR done, cancel during .verifying, cancel before start (needs gated FakeOCR)
- Task 6: minor (deferred): testEmptyDeltaIsIgnored relies on a 50ms sleep
- Task 6: minor (deferred → Task 11): after skip, phase stays .verifying while OCR finishes; UI should disable 검사 건너뛰기 once pressed
- Task 6: minor (deferred → Task 11): no deinit cancel — owners must call cancel() on window close / new capture
- Task 7: minor (deferred): `.iso8601` whole seconds — same-second captures tie (ordered by UUID); fractional-seconds ISO8601 strategy would fix (plan-mandated `.iso8601`)
- Task 7: minor (deferred): failed `add` after image write leaves orphan folder never evicted
- Task 7: minor (deferred): eviction removes by entry.id not scanned folder URL
- Task 7: minor (deferred): no tests for corrupt entry.json bytes, clear() sparing non-UUID siblings, tie order
- Task 8: minor (deferred): AppSettings.swift imports only Foundation but uses ObservableObject/@Published — add `import Combine`
- Task 8: minor (deferred): KeychainStore.read maps every non-success status to nil (locked keychain / ACL denial looks like "no key") — note for Task 11
- Task 8: minor (deferred): AppSettings.save discards encode failure with try?
- Task 8: minor (deferred): tests lack Korean keychain value, unknown stored keyCode, ⌃/⌥-only events
- Task 9: minor (deferred): hotkey callback doesn't read EventHotKeyID — signature/id unchecked, swallows any kEventHotKeyPressed
- Task 9: minor (deferred → Task 11): register() unregisters first; a failed new combo leaves no hotkey — Task 11 settings change must restore previous combo on failure
- Task 9: minor (deferred): ScreenCapturer @MainActor — could pass Sendable displayID/frame/scale and stay nonisolated
- Task 9: minor (deferred): TEMP PNG write ignores nil representation silently
- Task 9: minor (deferred → Task 11): focus not returned to previous frontmost app after overlay/capture
- Task 9: minor (deferred): selection rect computed assuming panel.frame == screen.frame (convertToScreen would remove assumption)
- Task 9: minor (deferred): isTooSmall height boundary untested
- Task 9: minor (deferred): overlay re-entrancy gap between finish() and dismiss() (one run-loop turn)
- Task 9: minor (deferred → manual check): cooperative NSApp.activate() may not activate LSUIElement app → esc/resign may not fire until user clicks
- Task 10: minor (deferred): replaceAll doesn't clear hasPendingUserEdit; double beginReplacement overwrites saved text (needs guard); test gaps readablePasteboardTypes / same-text re-recognition / marks after redo; linkd log noise in tests
- Task 10: minor (deferred): custom undo:/redo: validation drops NSWindow's undoMenuItemTitle updates ("Undo Typing")
- Task 11a: minor (deferred): permission flow calls CGRequest + opens Settings together (double prompt first time) — use a "requested once" flag
- Task 11a: minor (deferred): status menu starts with 0 items, relies on menuNeedsUpdate — call it once at init
- Task 11a: minor (deferred): .doneUnseen icon is non-template drawn image — no inversion when highlighted, cached color across appearance change
- Task 11a: minor (deferred): reopening a Nativ entry before model list loads shows settings.engine in Picker
- Task 11a: minor (deferred): focus not returned to previous app after esc-cancelled overlay (from Task 9)
- Task 11a: minor (deferred): caret bar position not updated on window resize during .receiving
- Task 11a: minor (deferred): whitespace-only text on failed/cancelled still overwrites the entry
- Task 11b: minor (deferred): SMAppService .requiresApproval gives no hint (open Login Items settings)
- Task 11b: minor (deferred): keychain write failure still updates saved value → never retried, only NSLog
- Task 11b: minor (deferred): recorder accepts ⌘Q/⌘C/⌘V etc. as global hotkey
- Task 11b: minor (deferred): refreshNativModels duplicated (AppCoordinator / SettingsWindowController); engine option assembly duplicated
- Task 11b: minor (deferred): history double reload on show; duplicate setCaptureShortcut at start; matches trims only spaces
- Task 12: minor (deferred): `exact` strict == — trailing newline from model shows ✗ despite ~100% charAccuracy
- Task 12: minor (deferred): report should note omissions only show in charAccuracy
- Task 12: minor (deferred): `try? await Task.sleep` swallows cancellation in poll loop
- Task 12: minor (deferred): AccuracyTests doc comment still says no pass/fail criterion; Haiku display name hard-coded in test
- Final review: mid-stream refusal 때 부분 텍스트가 이력의 최종 텍스트로 저장됨
- Final review: Nativ 주소를 http 호스트명으로 바꾸면 ATS가 막음(`NSAllowsLocalNetworking` 검토)
- Final review: 오버레이가 iCapture 자신의 다른 창에 key를 넘겨 취소되면 앞 앱을 다시 활성화해 그 창이 뒤로 밀릴 수 있음
- Final review: 앞 앱 비교를 `processIdentifier`로

## 4. 구현 중 내린 판단

- Ruling 1: Work on branch `feat/icapture-v1` in the existing checkout instead of a separate worktree — new personal repo, only docs on main, nothing else in flight — cost if wrong: none (branch can be moved to a worktree later).
- Ruling 2: `TestImages.text(_:pointSize:)` returns PNG `Data` (it feeds `recognizeText(png:)`), while `noise`/`solid` return `CGImage` — matches each call site in the plan — cost if wrong: trivial helper rename.
- Ruling 3: `ClaudeEngine` treats an empty-string API key the same as nil (`.missingAPIKey`) — the keychain store deletes empty values, so an empty key can only come from a blank field — cost if wrong: none.
- Ruling 4: Steps that need a human at the keyboard (T9 Step 5, T11 Step 3: permission prompts, pressing ⌘⇧2, dragging) are not performed by implementers. Implementers build, run automated tests, launch the app and confirm it starts without errors; the manual checklists are handed to the user at the finish — cost if wrong: UI bugs surface later, at the user's check.
- Ruling 5: T12 `AccuracyTests.testMeasure` keeps the plan's report-only design (spec §8: numeric targets are set with the user after the first measurement), but must assert the harness actually produced a result row per fixture×engine and wrote the report file — so it is not a test that asserts nothing — cost if wrong: a reviewer may still flag it; low.
- Ruling 6: `DEVELOPMENT_TEAM = QR5M2843GW` (the certificate's OU), not `CJXSU64RQ8` (the name suffix the plan copied) — verified with `openssl x509 -subject` on the login-keychain cert; xcodebuild rejected the plan's value — cost if wrong: none, build signs. Plan + global-constraints corrected (plan edit uncommitted until next docs commit).
- Ruling 7: Commit trailers name the model that actually wrote the commit (subagents on Sonnet use their own harness attribution line) — accurate attribution beats a uniform string — cost if wrong: cosmetic.
- Ruling 8: Task 4 moves ClaudeEngine's byte-level SSE line splitter into SSEParser.swift as a shared helper used by both engines (Nativ needs the same blank-line-preserving split) — avoids verbatim duplication of a logic block — cost if wrong: a small refactor of reviewed Task 3 code; covered by Task 3's existing ClaudeEngine tests.
- Ruling 9: Task 6's session ignores empty `.textDelta("")` (no phase change, no text change), independent of the Nativ fix — defense in depth so a role-only chunk can't flip the UI to "receiving" — cost if wrong: none.
- Ruling 10: Vision's first request takes ~16s (model load) and the session waits for OCR before .done — Task 11 warms Vision up at app launch with a tiny background OCR request so the first real capture isn't delayed; the session's wait stays as the plan says — cost if wrong: first capture after launch may still finish late.
- Ruling 11: swap undo/redo DOES call `onUserEdit?(string)` after restoring text (marks still cleared) — overrides my earlier clarification "restores text only"; spec §6.4 saves the user's current text to history and Task 11 learns of changes only via onUserEdit — cost if wrong: one extra history write per undo.
- Ruling 12: An LSUIElement app has no visible menu bar, so ⌘C/⌘V/⌘X/⌘A/⌘Z/⌘⇧Z/⌘W in its windows only work if NSApp.mainMenu holds an Edit menu (and a window Close item). Task 11 installs a minimal main menu (App: 설정… ⌘, / 종료 ⌘Q; Edit: Undo/Redo/Cut/Copy/Paste/Select All; Window: Close ⌘W, 모든 이력… ⌘Y) — spec §4/§5.2 require these shortcuts — cost if wrong: none (invisible menu).
- Ruling 13: Task 11 is split into two dispatches with one review each — 11a: AppCoordinator, result window/view, status menu (recent 5, icon states), main menu, TEMP removal, Vision warm-up; 11b: history window/view, settings window/view, hotkey re-registration — the task touches 7+ files across three windows; one review surface each keeps reviews tractable — cost if wrong: one extra review.
- Ruling 14: when a session ends .failed/.cancelled with empty text, the coordinator must NOT overwrite the history entry's text (keep the previous text/engine) — spec §5.2 keeps received text on failure; wiping an edited entry on a network error loses user work — cost if wrong: none.
- Ruling 15: Task 12 Steps 4–6 (real paid measurement with an API key) are not run by the implementer — the user approves spend and runs/asks for it after the finish; implementer delivers fixtures + harness + skip-path verification and commits (Step 7) — cost if wrong: accuracy numbers come later.
- Ruling 16: Final review runs on Opus 5.5 instead of Fable 5.1 — Fable requires usage credits the account doesn't have (HTTP 429) — cost if wrong: slightly less capable final reviewer.
- Ruling 17: The single final fix wave includes the 4 Importants, the first-responder fix, and 6 cheap user-facing minors (Nativ 401 message, hotkey+esc cancelling a running recognition, silent capture failure, live "확인 필요" count, API key trim, Nativ empty delta) — all small and local; one wave avoids a second fix round — cost if wrong: slightly larger fix diff to re-review.
