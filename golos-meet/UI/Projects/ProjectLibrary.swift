import Foundation
import Combine

/// One observable snapshot shared by the sidebar and meeting screens.
@MainActor
final class ProjectLibrary: ObservableObject {
    static let shared = ProjectLibrary()
    @Published private(set) var snapshot = ProjectSnapshot()
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isLoaded = false
    @Published private(set) var loadError: String?
    let store: ProjectStore

    var isReady: Bool { isLoaded && loadError == nil && !isLoading && !isSaving }
    var projects: [KnowledgeProject] { snapshot.projects }

    init(store: ProjectStore) { self.store = store }
    convenience init() {
        self.init(store: ProjectStore(url: AppPaths.appSupport.appendingPathComponent("knowledge.sqlite")))
    }

    func reload() async {
        guard !isLoading && !isSaving else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshot = try await store.snapshot()
            sortProjects()
            isLoaded = true
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    func create(name: String, parentID: UUID?) async throws -> KnowledgeProject {
        guard isReady else { throw ProjectStoreError.database("Library unavailable") }
        isSaving = true
        defer { isSaving = false }
        let project = try await store.createProject(name: name, parentID: parentID)
        // Mutation is already committed. Do not claim failure or invite duplicate
        // creation if a separate refresh fails afterwards.
        snapshot.projects.append(project)
        sortProjects()
        return project
    }

    func assign(meetingID: String, projectIDs: Set<UUID>) async throws {
        guard isReady else { throw ProjectStoreError.database("Library unavailable") }
        isSaving = true
        defer { isSaving = false }
        try await store.assignMeeting(meetingID, to: projectIDs)
        snapshot.meetingProjects[meetingID] = projectIDs.isEmpty ? nil : projectIDs
    }

    func projectIDs(for meetingID: String) -> Set<UUID> {
        snapshot.meetingProjects[meetingID] ?? []
    }

    func project(_ id: UUID) -> KnowledgeProject? { projects.first { $0.id == id } }

    /// Full names disambiguate same-named projects in separate branches.
    func path(for id: UUID) -> String {
        var parts: [String] = []
        var current: UUID? = id
        var seen: Set<UUID> = []
        while let next = current, seen.insert(next).inserted, let project = project(next) {
            parts.insert(project.name, at: 0)
            current = project.parentID
        }
        return parts.joined(separator: " / ")
    }

    private func sortProjects() {
        snapshot.projects.sort {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}

nonisolated enum ProjectMeetingScope: Hashable {
    case all, inbox, project(UUID)

    func contains(_ meetingID: String, snapshot: ProjectSnapshot) -> Bool {
        let owners = snapshot.meetingProjects[meetingID] ?? []
        switch self {
        case .all: return true
        case .inbox: return owners.isEmpty
        case .project(let id): return owners.contains(id)
        }
    }
}
