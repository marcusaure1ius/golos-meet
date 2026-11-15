import SwiftUI

/// Готовое предложение проекта для карточки Входящих.
/// Только read-model принятого assignment store (#45/#46): работа встречи в
/// состоянии `.current`, решение с origin `.proposal`, лучшее неблокированное
/// основание. Никаких новых вычислений в UI — тот же смысл, что и в блоке
/// «Предложение по проектам» на странице встречи.
struct InboxMeetingProposal: Equatable {
    let meetingID: String
    let projectID: UUID
    let projectName: String
}

/// Предложение read-model без имени проекта (имя даёт ProjectLibrary по пути).
struct InboxProposalCandidate: Equatable {
    let meetingID: String
    let projectID: UUID
}

enum InboxProposalResolver {
    /// Предложение для одной встречи или nil: без работы в `.current`, при
    /// ручном/автоматическом решении или когда все основания заблокированы
    /// (отрицание, чужое название) — предложение не показываем, как и панель встречи.
    static func proposal(for meetingID: String,
                         snapshot: MeetingAssignmentRuntimeSnapshot) -> InboxProposalCandidate? {
        guard snapshot.work[meetingID]?.state == .current,
              let decision = snapshot.decisions[meetingID],
              decision.origin == .proposal,
              let result = decision.result else { return nil }
        let candidate = result.evidence
            .filter { $0.support?.blocked != true }
            .max { $0.similarity < $1.similarity }
        guard let candidate else { return nil }
        return InboxProposalCandidate(meetingID: meetingID, projectID: candidate.projectID)
    }

    /// Все предложения ленты Входящих с именами проектов (полные пути различают
    /// одноимённые проекты в разных ветках).
    static func proposals(meetingIDs: [String], snapshot: MeetingAssignmentRuntimeSnapshot,
                          path: (UUID) -> String) -> [String: InboxMeetingProposal] {
        var result: [String: InboxMeetingProposal] = [:]
        for id in meetingIDs {
            guard let proposal = proposal(for: id, snapshot: snapshot) else { continue }
            result[id] = InboxMeetingProposal(meetingID: id, projectID: proposal.projectID,
                                              projectName: path(proposal.projectID))
        }
        return result
    }

    /// Тихая пометка на экране Входящих, когда предложений на карточках нет.
    /// Честно различает «индексация не догнала» и «уверенных совпадений нет».
    static func note(meetingIDs: [String], proposals: [String: InboxMeetingProposal],
                     snapshot: MeetingAssignmentRuntimeSnapshot) -> String? {
        guard !meetingIDs.isEmpty, proposals.isEmpty else { return nil }
        let notCaughtUp = meetingIDs.contains { id in
            guard let work = snapshot.work[id] else { return true }
            switch work.state {
            case .current, .manual: return false
            default: return true
            }
        }
        return notCaughtUp
            ? "Предложений пока нет: агент индексирует архив."
            : "Уверенных совпадений пока нет: проверьте встречу и выберите проекты вручную."
    }
}

/// Инлайн-строка предложения на карточке Входящих:
/// «Агент предлагает проект «X»» + [Подтвердить] + «Другие варианты»
/// (переход на страницу встречи, где видны все варианты и основания).
struct InboxProposalRow: View {
    let proposal: InboxMeetingProposal
    let onConfirm: () -> Void
    let onOtherOptions: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        HStack(spacing: 10) {
            Text("Агент предлагает проект «\(proposal.projectName)»")
                .font(.system(size: 13)).foregroundStyle(p.ink)
                .lineLimit(2)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Button("Подтвердить", action: onConfirm)
                .buttonStyle(GhostButton())
                .accessibilityIdentifier("inbox.proposal.confirm")
            Button("Другие варианты", action: onOtherOptions).buttonStyle(GhostButton())
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(p.selection.opacity(0.4))
    }
}

/// Лента Входящих с инлайн-предложениями и тихой пометкой экрана.
/// Отдельный view, чтобы наблюдать snapshot assignment store без наблюдения
/// за ним во всём MeetingsScreen.
struct InboxMeetingsFeed: View {
    @ObservedObject var assignments: KnowledgeAssignments
    let meetings: [MeetingSummary]
    let confirmError: String?
    let onSelect: (MeetingSummary) -> Void
    let onConfirm: (InboxMeetingProposal) -> Void
    @EnvironmentObject private var projects: ProjectLibrary
    @Environment(\.palette) private var p

    private var proposals: [String: InboxMeetingProposal] {
        InboxProposalResolver.proposals(meetingIDs: meetings.map(\.id),
                                        snapshot: assignments.snapshot) { projects.path(for: $0) }
    }

    var body: some View {
        let snapshot = assignments.snapshot
        VStack(spacing: 8) {
            if let message = confirmError {
                Text(message).font(.system(size: 13)).foregroundStyle(p.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 56)
            }
            if let note = InboxProposalResolver.note(meetingIDs: meetings.map(\.id),
                                                     proposals: proposals, snapshot: snapshot) {
                Text(note).font(.system(size: 13)).foregroundStyle(p.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 56)
            }
            MeetingFeedView(meetings: meetings, now: Date(), proposals: proposals,
                            onConfirmProposal: onConfirm, onSelect: onSelect)
        }
    }
}
