import SwiftUI

/// Default engine, Claude API key, local server (Nativ, Ollama, vLLM) URL and API key, capture hotkey, launch at login.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("기본 엔진", selection: $settings.engine) {
                    ForEach(model.engineOptions(selected: settings.engine), id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                SecureField("Claude API 키", text: $model.claudeKey)
                    .onSubmit { model.onCommit?() }
            }

            Section {
                TextField("로컬 LLM 서버 주소 (Nativ·Ollama·vLLM 등)", text: $model.baseLLMURLText)
                    .onSubmit { model.onCommit?() }
                SecureField("로컬 LLM API 키 (선택)", text: $model.llmKey)
                    .onSubmit { model.onCommit?() }
            }

            Section {
                LabeledContent("캡처 단축키") {
                    Button(model.isRecordingHotKey ? "새 단축키를 누르세요…" : settings.hotKey.displayString) {
                        model.onToggleRecording?()
                    }
                    .frame(minWidth: 160)
                }
                Toggle("로그인할 때 자동 실행", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.onSetLaunchAtLogin?($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}
