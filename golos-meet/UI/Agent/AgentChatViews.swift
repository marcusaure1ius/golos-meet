import SwiftUI
import AppKit

// MARK: - Экран «Агент» (issue #94)
//
// Чат-оболочка по паттернам AutoClaw (research/agent-ui-94/SPEC.md):
// один поток, narration-строки, свёрнутый блок процесса, артефакты-карточки
// инлайном, минимальный композер. Дизайн — язык golos (Palette, GCard).

struct AgentScreen: View {
    @StateObject private var model: AgentChatModel

    init(library: MeetingLibrary) {
        _model = StateObject(wrappedValue: AgentChatModel(library: library))
    }

    /// Для превью и рендер-тестов.
    init(model: AgentChatModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        AgentChatView(model: model)
    }
}

struct AgentChatView: View {
    @Environment(\.palette) private var p
    @ObservedObject var model: AgentChatModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(p.borderSoft)
            if model.items.isEmpty {
                emptyState
            } else {
                chatStream
            }
            composer
        }
        .background(p.content)
    }

    // MARK: Шапка

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(p.accent)
                .frame(width: 18, height: 18)
            Text("Агент")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(p.ink)
            Text("Демо-режим: отвечает по правилам на данных архива, без модели")
                .font(.system(size: 12))
                .foregroundStyle(p.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if model.isThinking {
                HStack(spacing: 6) {
                    Spinner(color: p.muted, size: 12, lineWidth: 1.4)
                    Text("Работаю…")
                        .font(.system(size: 12))
                        .foregroundStyle(p.muted)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Экран Агент, демо-режим")
    }

    // MARK: Пустой экран

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(p.muted2)
            Text("Что ищем в архиве?")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(p.ink)
            Text("Спросите по встречам: найду встречи, перескажу конспект и предложу проект по теме. Отвечаю на данных QA-архива, локально.")
                .font(.system(size: 13.5))
                .foregroundStyle(p.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 10) {
                suggestion("О чём договорились на последней встрече?")
                suggestion("Найди встречи по слову прайсинг")
                suggestion("Предложи проект по теме прайсинг")
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func suggestion(_ text: String) -> some View {
        Button { model.draft = text } label: {
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(p.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(p.card)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(p.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Подсказка: \(text)")
    }

    // MARK: Поток сообщений

    private var chatStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.items) { item in
                        row(item).id(item.id)
                    }
                    Color.clear.frame(height: 4)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
            // Новый элемент потока всегда подтягивает ленту к концу
            // (упрощение macOS 14.4; AutoClaw keeps bottom-follow, П1 SPEC.md).
            .onChange(of: model.items.count) { _, _ in
                guard let last = model.items.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder private func row(_ item: AgentChatItem) -> some View {
        switch item {
        case .userMessage(_, let text, _):
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(p.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(p.cardSel)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .frame(maxWidth: 560, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Вы написали: \(text)")

        case .agentMessage(_, let text, _):
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.system(size: 14))
                    .foregroundStyle(p.ink)
                    .lineSpacing(3)
                    .frame(maxWidth: 640, alignment: .leading)
                Text("Ответ агента · проверьте важное по источникам")
                    .font(.system(size: 11))
                    .foregroundStyle(p.muted2)
            }
            .accessibilityElement(children: .combine)

        case .narration(_, let text):
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(p.muted2)
                    .frame(width: 5, height: 5)
                    .padding(.top, 5)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(p.muted)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Шаг агента: \(text)")

        case .toolSteps(_, let label, let steps):
            AgentToolStepsBlock(label: label, steps: steps)

        case .artifact(let artifact):
            AgentArtifactCard(artifact: artifact)

        case .failure(_, let text):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(p.danger)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(p.danger)
            }
            .padding(10)
            .background(p.dangerBg)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Композер

    private var composer: some View {
        HStack(spacing: 12) {
            TextField("Спросите по встречам и проектам", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...4)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(p.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(p.fieldBorder, lineWidth: 1)
                )
                .onSubmit { model.send() }
                .accessibilityLabel("Сообщение агенту")
            Button {
                if model.isThinking { model.stop() } else { model.send() }
            } label: {
                Image(systemName: model.isThinking ? "stop.fill" : "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(p.btnInk)
                    .frame(width: 30, height: 30)
                    .background(canSend || model.isThinking ? p.btn : p.cardSel)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !model.isThinking)
            .accessibilityLabel(model.isThinking ? "Остановить агента" : "Отправить")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(p.bg.opacity(0.0))
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - Свёрнутый блок процесса (П3 SPEC.md)

struct AgentToolStepsBlock: View {
    @Environment(\.palette) private var p
    let label: String
    let steps: [AgentToolStep]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(p.muted)
                        .frame(width: 12)
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(p.muted)
                    Text("· \(steps.count) \(steps.count == 1 ? "шаг" : steps.count < 5 ? "шага" : "шагов")")
                        .font(.system(size: 12.5))
                        .foregroundStyle(p.muted2)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Свернуть" : "Раскрыть") процесс, шагов: \(steps.count)")
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 6) {
                            Text("–")
                                .font(.system(size: 12))
                                .foregroundStyle(p.muted2)
                            Text(step.label)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(p.muted)
                            if let result = step.result {
                                Text("→ \(result)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(p.muted2)
                            }
                        }
                        .frame(maxWidth: 640, alignment: .leading)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}

// MARK: - Карточка-артефакт (П4 SPEC.md)

struct AgentArtifactCard: View {
    @Environment(\.palette) private var p
    let artifact: AgentArtifact
    @State private var copied = false

    private var icon: String {
        switch artifact.kind {
        case .meeting: return "waveform"
        case .summary: return "doc.text"
        case .projectSuggestion: return "folder.badge.plus"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(p.accent)
                    .frame(width: 30, height: 30)
                    .background(p.cardSel)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(p.ink)
                        .lineLimit(2)
                    Text(artifact.meta)
                        .font(.system(size: 12))
                        .foregroundStyle(p.muted)
                }
                Spacer(minLength: 0)
            }
            if !artifact.body.isEmpty {
                Text(artifact.body)
                    .font(.system(size: 13))
                    .foregroundStyle(p.ink)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !artifact.points.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(artifact.points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(p.muted)
                                .padding(.top, 2)
                            Text(point)
                                .font(.system(size: 13))
                                .foregroundStyle(p.ink)
                                .lineSpacing(2.6)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Text(artifact.sourceLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(p.muted2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button {
                    let text = [artifact.title, artifact.meta, artifact.body, artifact.points.joined(separator: "\n")]
                        .filter { !$0.isEmpty }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(GhostButton())
                .accessibilityLabel("Скопировать текст карточки")
            }
        }
        .padding(14)
        .frame(maxWidth: 640, alignment: .leading)
        .background(p.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(p.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Карточка: \(artifact.title)")
    }
}
