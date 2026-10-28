import SwiftUI

/// Default engine, Claude API key, local server (Nativ, Ollama, vLLM) URL and API key, capture hotkey, launch at login, language.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Default Engine", selection: $settings.engine) {
                    ForEach(model.engineOptions(selected: settings.engine), id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                SecureField("Claude API Key", text: $model.claudeKey)
                    .onSubmit { model.onCommit?() }
            }

            Section {
                TextField("Local LLM Server URL (Nativ, Ollama, vLLM, …)", text: $model.baseLLMURLText)
                    .onSubmit { model.onCommit?() }
                SecureField("Local LLM API Key (optional)", text: $model.llmKey)
                    .onSubmit { model.onCommit?() }
            }

            Section {
                LabeledContent("Capture Shortcut") {
                    Button(model.isRecordingHotKey ? String(localized: "Press a new shortcut…") : settings.hotKey.displayString) {
                        model.onToggleRecording?()
                    }
                    .frame(minWidth: 160)
                }
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.onSetLaunchAtLogin?($0) }
                ))
            }

            Section {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                // macOS applies the language at launch, so a change waits for a restart.
                if settings.needsRestartForLanguage {
                    HStack {
                        Text("Restart iCapture to apply the new language.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { model.onRelaunch?() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}
