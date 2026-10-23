import AppKit
import SwiftUI

/// 왼쪽: 검색 칸 / 이력 목록 / "이력 비우기". 오른쪽: 고른 항목의 이미지와 텍스트(읽기 전용)와 "결과 창에서 열기".
/// 편집은 결과 창에서 한다(스펙 5.3의 빌더 재량).
struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    let onClear: () -> Void

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
            detail
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .frame(minWidth: 640, minHeight: 360)
    }

    // MARK: - 왼쪽

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("검색", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            list
            Divider()
            HStack {
                Button("이력 비우기", action: onClear)
                    .disabled(model.entries.isEmpty)
                Spacer()
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var list: some View {
        let entries = model.filteredEntries
        if entries.isEmpty {
            placeholder(model.entries.isEmpty ? "아직 캡처가 없어요" : "검색 결과가 없어요")
        } else {
            List(entries, selection: $model.selectedID) { entry in
                HistoryRow(entry: entry)
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: - 오른쪽

    @ViewBuilder
    private var detail: some View {
        if let entry = model.selectedEntry {
            VStack(spacing: 0) {
                ZStack {
                    Color(white: 0.12)
                    if let image = model.selectedImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                ScrollView {
                    Text(entry.text)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                .frame(maxHeight: .infinity)
                Divider()
                HStack {
                    Text(entry.engineName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("결과 창에서 열기") { model.onOpenInResult?(entry) }
                }
                .padding(8)
            }
        } else {
            placeholder("")
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 배지(`kind.badge`) · 첫 줄 · 캡처 시각.
private struct HistoryRow: View {
    let entry: HistoryEntry

    private static let timeStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
        .locale(Locale(identifier: "ko_KR"))

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.kind.badge)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.2)))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.firstLine.isEmpty ? "(텍스트 없음)" : entry.firstLine)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.capturedAt.formatted(Self.timeStyle))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
