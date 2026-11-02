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

extension ProjectMemoryEntry {
    /// Normal application entry retains the guarded production factory.
    init(projectID: UUID? = nil, meetingID: String? = nil,
         onBack: (() -> Void)? = nil, onSettings: (() -> Void)? = nil) {
        self.init(projectID: projectID, meetingID: meetingID, onBack: onBack,
                  onSettings: onSettings, makeModel: ProductionMemoryPanel.makeModel)
    }
}
