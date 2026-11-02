import SwiftUI

/// Shared production navigation used by the isolated synthetic composition too.
struct ProjectMemoryOpenButton: View {
    var title = "Контекст проекта"
    var systemImage = "sidebar.right"
    var identifier = "meeting.memory"
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: systemImage) }
            .buttonStyle(GhostButton())
            .accessibilityIdentifier(identifier)
    }
}

extension View {
    func projectMemoryInspector<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder panel: () -> Panel) -> some View {
        inspector(isPresented: isPresented) {
            panel().inspectorColumnWidth(min: 380, ideal: 460, max: 600)
        }
    }
}
