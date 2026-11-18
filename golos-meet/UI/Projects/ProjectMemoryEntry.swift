import SwiftUI

struct ProjectMemoryEntry: View {
    var projectID: UUID?
    var meetingID: String?
    var onBack: (() -> Void)?
    var onSettings: (() -> Void)?
    let makeModel: @MainActor (UUID?, String?) -> ProjectMemoryPanelModel?
    @State private var model: ProjectMemoryPanelModel?
    @State private var loaded = false
    var body: some View {
        Group {
            if let model { ProjectMemoryPanel(model:model,onBack:onBack,onSettings:onSettings) }
            else if loaded { ContentUnavailableView("Память недоступна в тестовом host",systemImage:"text.book.closed") }
            else { ProgressView("Открываем память проекта…") }
        }.task {
            if !loaded { model = makeModel(projectID,meetingID); loaded = true }
            model?.start()
        }.onDisappear { model?.close() }
    }
}
