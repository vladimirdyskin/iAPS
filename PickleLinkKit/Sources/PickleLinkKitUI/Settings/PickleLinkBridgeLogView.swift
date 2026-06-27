#if canImport(SwiftUI) && canImport(LoopKitUI)
    import PickleLinkKit
    import SwiftUI

    /// Экран просмотра диагностического лога моста (SCMD 0x1A GET_LOG).
    /// Записи отображаются новые сверху (reverse от порядка payload).
    struct PickleLinkBridgeLogView: View {
        let pumpManager: PickleLinkPumpManager

        @State private var lines: [BridgeLogLine] = []
        @State private var loading = false
        @State private var errorMessage: String?
        @State private var showShareSheet = false

        var body: some View {
            Group {
                if loading && lines.isEmpty {
                    ProgressView("Loading log...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty && errorMessage == nil {
                    Text("Log is empty")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    logList
                }
            }
            .navigationTitle("Bridge Log")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if loading { ProgressView() }
                    Button {
                        Task { await fetchLog() }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .disabled(loading)

                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                    .disabled(lines.isEmpty)
                }
            }
            .sheet(isPresented: $showShareSheet) {
                // Текст вычисляем здесь (свежий lines), а не через @State до показа —
                // иначе sheet захватывает старое пустое значение и файл пустой.
                ActivityView(activityItems: [exportText()])
            }
            .onAppear {
                Task { await fetchLog() }
            }
        }

        // MARK: - Список

        private var logList: some View {
            List {
                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                // Новые записи — сверху: reversed()
                ForEach(lines.reversed()) { line in
                    logRow(line)
                }
            }
            .listStyle(.plain)
            .font(.system(.caption, design: .monospaced))
        }

        private func logRow(_ line: BridgeLogLine) -> some View {
            HStack(alignment: .top, spacing: 6) {
                Text(line.timeStr)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                Text(line.text)
                    .foregroundStyle(color(for: line.severity))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 1)
        }

        // MARK: - Запрос

        private func fetchLog() async {
            loading = true
            errorMessage = nil
            do {
                lines = try await pumpManager.fetchBridgeLog()
            } catch {
                errorMessage = "GET_LOG error: \(error.localizedDescription)"
            }
            loading = false
        }

        // MARK: - Экспорт

        private func exportText() -> String {
            lines.reversed().map { "\($0.timeStr)  \($0.text)" }.joined(separator: "\n")
        }

        // MARK: - Утилиты

        private func color(for severity: BridgeLogSeverity) -> Color {
            switch severity {
            case .normal: return .primary
            case .warning: return .orange
            case .error: return .red
            }
        }
    }

    // MARK: - UIActivityViewController обёртка

    private struct ActivityView: UIViewControllerRepresentable {
        let activityItems: [Any]

        func makeUIViewController(context _: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }

        func updateUIViewController(_: UIActivityViewController, context _: Context) {}
    }
#endif
