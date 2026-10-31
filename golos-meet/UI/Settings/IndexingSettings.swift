import SwiftUI

@MainActor struct IndexingSettings: View {
    @Environment(\.palette) private var p
    @ObservedObject var indexing: KnowledgeIndexing

    var body: some View {
        let state = indexing.snapshot
        VStack(alignment: .leading, spacing: 12) {
            GSectionHeader("Индексирование библиотеки", desc: "Документы и расшифровки обрабатываются в фоне на этом Mac.")
            GCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        if state.modelState == .checking || state.counts[.running, default: 0] > 0 {
                            ProgressView().controlSize(.small)
                        }
                        Text(summary).foregroundStyle(p.ink)
                            .accessibilityLabel(summary)
                        Spacer()
                        Button("Проверить библиотеку") { indexing.refresh() }.buttonStyle(GhostButton())
                    }
                    if let message = state.storageMessage ?? indexing.monitorMessage {
                        Text(message).foregroundStyle(p.danger)
                    }
                    if !state.hasWorkingModel {
                        Text(state.modelMessage).foregroundStyle(state.modelState == .failed ? p.danger : p.muted)
                    }
                    HStack(spacing: 10) {
                        if state.counts[.queued, default: 0] + state.counts[.running, default: 0] + state.counts[.waitingForModel, default: 0] > 0 {
                            Button("Отменить очередь") { indexing.cancelAll() }.buttonStyle(GhostButton())
                        }
                        if state.counts[.failed, default: 0] + state.counts[.cancelled, default: 0] > 0 {
                            Button("Повторить ошибки и отменённые") { indexing.retryAll() }.buttonStyle(GhostButton())
                        }
                    }
                    ForEach(state.jobs.filter { $0.state != .ready }, id: \.source) { job in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(indexing.title(job.source)).foregroundStyle(p.ink)
                                Text(jobMessage(job)).foregroundStyle(job.state == .failed ? p.danger : p.muted)
                                if job.state == .running, job.total > 0 {
                                    ProgressView(value: Double(job.completed), total: Double(job.total))
                                        .progressViewStyle(.linear)
                                        .accessibilityLabel("Индексирование \(indexing.title(job.source))")
                                }
                            }
                            Spacer()
                            if [.queued, .running, .waitingForModel].contains(job.state) {
                                Button("Отменить") { indexing.cancel(job.source) }.buttonStyle(GhostButton())
                            } else {
                                Button("Повторить") { indexing.retry(job.source) }.buttonStyle(GhostButton())
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    ForEach(state.sourceErrors.keys.sorted { $0.rawValue < $1.rawValue }.prefix(20), id: \.self) { key in
                        Text("\(indexing.title(key)): \(state.sourceErrors[key] ?? "")").foregroundStyle(p.danger)
                    }
                    Text("Готово: \(state.counts[.ready, default: 0]) · В очереди: \(state.counts[.queued, default: 0] + state.counts[.waitingForModel, default: 0]) · Ошибок: \(state.counts[.failed, default: 0] + state.sourceErrors.count)")
                        .foregroundStyle(p.muted)
                    Text("Индексирование не отправляет тексты в облако и не останавливает запись или распознавание.")
                        .foregroundStyle(p.muted)
                }
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { indexing.start() }
    }

    private var summary: String {
        let state = indexing.snapshot
        if state.modelState == .checking { return "Проверяем модель…" }
        if !state.hasWorkingModel { return "Ожидаем локальную модель" }
        if state.counts[.running, default: 0] > 0 { return "Индексируем источники…" }
        if state.counts[.queued, default: 0] > 0 { return "Источники в очереди" }
        if state.counts[.failed, default: 0] > 0 || !state.sourceErrors.isEmpty { return "Некоторые источники требуют внимания" }
        if state.counts[.cancelled, default: 0] > 0 { return "Есть отменённые источники" }
        if state.counts.values.reduce(0, +) == 0 { return "В библиотеке пока нет источников для индексации" }
        return "Индексирование завершено"
    }
    private func jobMessage(_ job: EmbeddingIndexJob) -> String {
        switch job.state {
        case .waitingForModel: "Ожидает установки модели"
        case .queued: "В очереди"
        case .running: "Фрагментов: \(job.completed) из \(job.total)"
        case .ready: "Готово"
        case .failed, .cancelled: job.message
        }
    }
}
