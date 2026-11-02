import SwiftUI
import Combine

@MainActor enum ProductionMemoryPanel {
    static func makeModel(projectID: UUID? = nil, meetingID: String? = nil) -> ProjectMemoryPanelModel? {
        // Must precede real shared store/settings/queue/Keychain paths.
        guard !AppRuntime.isTestHost, let queue = ProductionMemoryQueue.shared else { return nil }
        let settings = UISettings.shared
        return .init(store:ProjectLibrary.shared.store,worker:queue.worker,meetingsRoot:AppPaths.meetingsRoot,
            documentsRoot:AppPaths.appSupport.appendingPathComponent("knowledge"),projectID:projectID,meetingID:meetingID,
            enabled:settings.llmEnabled,provider:"OpenRouter · " + settings.llmModel,center:.default,
            configuration:settings.$llmEnabled.combineLatest(settings.$llmModel)
                .map { ($0.0,"OpenRouter · " + $0.1) }.eraseToAnyPublisher())
    }
}

struct ProjectMemoryEntry: View {
    var projectID: UUID?
    var meetingID: String?
    var onBack: (() -> Void)?
    var onSettings: (() -> Void)?
    @State private var model: ProjectMemoryPanelModel?
    @State private var loaded = false
    var body: some View {
        Group {
            if let model { ProjectMemoryPanel(model:model,onBack:onBack,onSettings:onSettings) }
            else if loaded { ContentUnavailableView("Память недоступна в тестовом host",systemImage:"text.book.closed") }
            else { ProgressView("Открываем память проекта…") }
        }.task {
            if !loaded { model = ProductionMemoryPanel.makeModel(projectID:projectID,meetingID:meetingID); loaded = true }
            model?.start()
        }.onDisappear { model?.close() }
    }
}
