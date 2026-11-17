import AppKit
import SwiftUI

// Standalone synthetic design prototype. No Golos module, services, storage,
// Keychain, microphone, model, recovery, networking or external task transport.
enum Page: String, CaseIterable {
    case overview, meeting, document
    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .meeting: return "Готовность пилота"
        case .document: return "Условия пилота.pdf"
        }
    }
}
struct Paint {
    let dark: Bool
    func c(_ light: UInt, _ darkValue: UInt) -> Color {
        let hex = dark ? darkValue : light
        return Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255, opacity: 1)
    }
    var backdrop: Color { c(0xE9EDF2, 0x141820) }
    var surface: Color { c(0xFFFFFF, 0x20252D) }
    var chat: Color { c(0xF5F7FA, 0x191E26) }
    var ink: Color { c(0x252D39, 0xE7EBF1) }
    var secondary: Color { c(0x5E6979, 0xA7B2C2) }
    var rule: Color { c(0xE7EBF1, 0x333B47) }
    var tint: Color { c(0xEDF3FB, 0x283B54) }
    var blue: Color { c(0x245FAD, 0xA1CAFF) }
    var selected: Color { c(0xDAE8FA, 0x293E59) }
    var warning: Color { c(0x875217, 0xEDBD81) }
    var warningBg: Color { c(0xFBF5EB, 0x332C24) }
    var raised: Color { c(0xF4F6F9, 0x292F39) }
}
@MainActor final class Model: ObservableObject {
    @Published var page: Page
    @Published var draft = ""
    @Published var showChat = true
    @Published var showSidebar = true
    let dark: Bool
    let fullscreen: Bool
    let reduced: Bool
    var p: Paint { Paint(dark: dark) }
    init(_ page: Page, dark: Bool = false, fullscreen: Bool = false, reduced: Bool = false) {
        self.page = page; self.dark = dark
        self.fullscreen = fullscreen; self.reduced = reduced
    }
}
struct Rule: View {
    @EnvironmentObject var m: Model
    var body: some View { Rectangle().fill(m.p.rule).frame(height: 1) }
}
struct SymbolButton: View {
    let symbol: String, title: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}
struct SourceLink: View {
    @EnvironmentObject var m: Model
    let text: String
    let page: Page
    var body: some View {
        Button { m.page = page } label: {
            HStack(spacing: 5) {
                Image(systemName: page == .meeting ? "waveform" : "doc.text").font(.system(size: 10))
                Text(text).font(.system(size: 11, weight: .medium))
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .medium))
            }.foregroundStyle(m.p.blue)
        }.buttonStyle(.plain).help("Открыть локальный источник: " + text)
            .accessibilityLabel("Открыть источник: " + text)
    }
}
struct SectionHeading: View {
    @EnvironmentObject var m: Model
    let text: String
    var suffix = ""
    var body: some View {
        HStack {
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(m.p.ink)
            Spacer()
            if !suffix.isEmpty { Text(suffix).font(.system(size: 11)).foregroundStyle(m.p.secondary) }
        }.padding(.bottom, 12)
    }
}
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
struct ProjectTree: View {
    @EnvironmentObject var m: Model
    func item(_ title: String, _ symbol: String, count: String = "", selected: Bool = false, indent: CGFloat = 0, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 13)).frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                if !count.isEmpty { Text(count).font(.system(size: 11)).foregroundStyle(m.p.secondary) }
            }.font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? m.p.blue : m.p.ink)
                .padding(.leading, 10 + indent).padding(.trailing, 10).frame(height: 33)
                .background(selected ? m.p.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(title)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {} label: {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text("Поиск материалов")
                    Spacer()
                    Text("⌘K").font(.system(size: 10)).foregroundStyle(m.p.secondary)
                }.font(.system(size: 12)).foregroundStyle(m.p.secondary)
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(m.p.surface.opacity(m.dark ? 0.45 : 0.75), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).padding(.bottom, 17)
            item("Все встречи", "waveform", count: "24") { m.page = .meeting }
            item("Входящие", "tray", count: "3")
            HStack { Text("Проекты"); Spacer(); Image(systemName: "plus").font(.system(size: 11)) }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(m.p.secondary)
                .padding(.horizontal, 10).padding(.top, 25).padding(.bottom, 8)
            HStack(spacing: 7) {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                Text("Север").font(.system(size: 12, weight: .medium))
            }.foregroundStyle(m.p.secondary).padding(.leading, 10).padding(.vertical, 9)
            item("Клиентский портал", "folder.fill", selected: true, indent: 12) { m.page = .overview }
            item("Мобильный кабинет", "folder", indent: 12)
            item("Исследования", "folder", indent: 12)
            HStack { Image(systemName: "chevron.right").font(.system(size: 8)); Text("Личные проекты").font(.system(size: 12)) }
                .foregroundStyle(m.p.secondary).padding(.leading, 10).padding(.top, 16)
            Text("Закреплено").font(.system(size: 11, weight: .medium)).foregroundStyle(m.p.secondary)
                .padding(.leading, 10).padding(.top, 29).padding(.bottom, 8)
            item("Готовность пилота", "waveform") { m.page = .meeting }
            item("Условия пилота", "doc.text") { m.page = .document }
            Spacer(minLength: 20)
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(m.p.secondary)
                Text("Индекс обновлён").font(.system(size: 11)).foregroundStyle(m.p.secondary)
            }.padding(.horizontal, 10).padding(.bottom, 14)
            Rule().opacity(0.8)
            item("Настройки", "gearshape")
        }.padding(.horizontal, 13).padding(.top, 19).padding(.bottom, 11)
            .frame(minWidth: 210, idealWidth: 220, maxWidth: 280)
            .background {
                if m.reduced { m.p.backdrop }
                else { SidebarMaterial() }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Проекты")
    }
}
struct Workspace: View {
    @EnvironmentObject var m: Model
    var body: some View {
        HSplitView {
            if m.showSidebar { ProjectTree().frame(width: m.fullscreen ? 232 : 220) }
            HSplitView {
                mainSurface.frame(minWidth: 570, maxWidth: .infinity, maxHeight: .infinity)
                if m.showChat { ContextChat().frame(minWidth: 304, idealWidth: 326, maxWidth: 410).frame(width: m.fullscreen ? 364 : 326) }
            }.padding(.top, 8).padding(.trailing, 10).padding(.bottom, 9)
        }.background(m.p.backdrop).foregroundStyle(m.p.ink)
            .font(.system(size: 13))
            .environment(\.colorScheme, m.dark ? .dark : .light)
    }
    var mainSurface: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Клиентский портал").font(.system(size: 20, weight: .medium)).tracking(-0.3)
                    Text("Север").font(.system(size: 11)).foregroundStyle(m.p.secondary)
                }
                Spacer()
                Button {} label: { Label("Добавить", systemImage: "plus") }.controlSize(.small)
                SymbolButton(symbol: "ellipsis", title: "Действия проекта")
            }.padding(.horizontal, 27).padding(.top, 22).padding(.bottom, 21)
            HStack(spacing: 24) {
                tab("Обзор", active: m.page == .overview) { m.page = .overview }
                tab("Материалы", active: m.page != .overview) { m.page = .meeting }
                tab("Память", active: false) {}
                tab("Задачи", active: false) {}
                Spacer()
                Text("На этом Mac").font(.system(size: 10)).foregroundStyle(m.p.secondary)
            }.padding(.horizontal, 27)
            Rule()
            if m.page == .document { DocumentPage() }
            else {
                ScrollView {
                    Group {
                        if m.page == .overview { ProjectOverview() }
                        else { MeetingPage() }
                    }.padding(27).frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if m.page == .meeting { player }
            }
            HStack {
                Text("Макет A · новая визуальная итерация · синтетические данные")
                Spacer()
                Text(m.reduced ? "Непрозрачный режим" : (m.fullscreen ? "1920 × 1080" : "1440 × 900"))
            }.font(.system(size: 9)).foregroundStyle(m.p.secondary).padding(.horizontal, 20).frame(height: 23)
        }.background(m.p.surface, in: RoundedRectangle(cornerRadius: 11))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .shadow(color: .black.opacity(m.dark ? 0.16 : 0.065), radius: 10, x: 0, y: 4)
            .accessibilityElement(children: .contain).accessibilityLabel("Материал")
    }
    func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Text(title).font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? m.p.ink : m.p.secondary)
                Rectangle().fill(active ? m.p.blue : .clear).frame(height: 2)
            }.fixedSize(horizontal: true, vertical: false)
        }.buttonStyle(.plain)
    }
    var player: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 13) {
                SymbolButton(symbol: "gobackward.10", title: "Назад на 10 секунд — макет")
                Button {} label: { Image(systemName: "play.fill").frame(width: 24, height: 24) }.buttonStyle(.bordered).controlSize(.small)
                Text("14:32").font(.system(size: 11, weight: .medium)).monospacedDigit()
                Slider(value: .constant(0.345)).controlSize(.small)
                Text("42:08").font(.system(size: 11)).monospacedDigit().foregroundStyle(m.p.secondary)
                Text("1×").font(.system(size: 11)).padding(.horizontal, 7)
            }.padding(.horizontal, 22).frame(height: 54)
        }.background(m.p.surface).accessibilityLabel("Макет плеера, аудио отсутствует")
    }
}
struct MaterialRow: View {
    @EnvironmentObject var m: Model
    let title: String, subtitle: String, trailing: String
    let page: Page
    var body: some View {
        Button { m.page = page } label: {
            HStack(spacing: 11) {
                Image(systemName: page == .meeting ? "waveform" : "doc.text").font(.system(size: 16, weight: .light)).foregroundStyle(m.p.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(m.p.ink)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(m.p.secondary)
                }
                Spacer(minLength: 8)
                Text(trailing).font(.system(size: 10)).foregroundStyle(m.p.secondary)
            }.padding(.vertical, 14)
        }.buttonStyle(.plain)
    }
}
struct ProjectOverview: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("К запуску 12 ноября").font(.system(size: 23, weight: .regular)).tracking(-0.4)
                Spacer()
                Text("Обновлено сегодня, 10:48").font(.system(size: 10)).foregroundStyle(m.p.secondary)
            }
            Text("Пилот начнётся в режиме чтения. Осталось согласовать экспорт\nи назначить владельца приёмки.")
                .font(.system(size: 13)).foregroundStyle(m.p.secondary).lineSpacing(5).padding(.top, 10)
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 15)).foregroundStyle(m.p.warning).padding(.top, 2)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Экспорт ждёт подтверждения безопасности").font(.system(size: 12, weight: .medium))
                    HStack(spacing: 17) {
                        SourceLink(text: "Встреча · 14:32", page: .meeting)
                        SourceLink(text: "Условия · с. 7", page: .document)
                    }
                }
                Spacer()
            }.padding(15).background(m.p.warningBg, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 21)
            HStack(alignment: .top, spacing: 27) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeading(text: "Последние материалы", suffix: "20 материалов")
                    MaterialRow(title: "Готовность пилота", subtitle: "Встреча · 30 октября", trailing: "42 мин", page: .meeting)
                    Rule()
                    MaterialRow(title: "Условия пилота.pdf", subtitle: "Документ · версия 3", trailing: "18 стр.", page: .document)
                    Rule()
                    MaterialRow(title: "Обсуждение доступа", subtitle: "Встреча · 28 октября", trailing: "28 мин", page: .meeting)
                    Rule()
                    MaterialRow(title: "Критерии приёмки.md", subtitle: "Документ · 27 октября", trailing: "Текст", page: .document)
                    Button("Все материалы") { m.page = .meeting }.font(.system(size: 11)).buttonStyle(.link).padding(.top, 14)
                }.frame(maxWidth: .infinity)
                Rectangle().fill(m.p.rule).frame(width: 1)
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeading(text: "Открытые вопросы", suffix: "2")
                    question("Кто принимает результат?", detail: "Владелец пока не назначен", source: "Встреча · 28:10")
                    Rule()
                    question("Когда будет доступен экспорт?", detail: "Нужно решение до 5 ноября", source: "Встреча · 14:32")
                    Text("Последнее решение").font(.system(size: 12, weight: .semibold)).padding(.top, 13)
                    Text("В первый запуск — только чтение").font(.system(size: 13)).lineSpacing(4)
                    SourceLink(text: "Встреча · 14:32", page: .meeting)
                }.frame(width: m.fullscreen ? 290 : 240, alignment: .leading)
            }.fixedSize(horizontal: false, vertical: true).padding(.top, 30)
            Rule().padding(.top, 27).padding(.bottom, 22)
            SectionHeading(text: "Связанные задачи", suffix: "Constance · 4")
            task("DEMO-142", "Проверить экспорт", "В работе", "5 ноя")
            Rule()
            task("DEMO-139", "Назначить владельца приёмки", "Открыта", "7 ноя")
        }
    }
    func question(_ title: String, detail: String, source: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.system(size: 11)).foregroundStyle(m.p.secondary)
            SourceLink(text: source, page: .meeting)
        }
    }
    func task(_ id: String, _ title: String, _ state: String, _ due: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: state == "В работе" ? "circle.lefthalf.filled" : "circle").foregroundStyle(m.p.secondary).font(.system(size: 12))
            Text(id).font(.system(size: 10)).foregroundStyle(m.p.secondary).frame(width: 67, alignment: .leading)
            Text(title).font(.system(size: 12))
            Spacer()
            Text(state).font(.system(size: 10)).foregroundStyle(m.p.secondary)
            Text(due).font(.system(size: 10)).foregroundStyle(m.p.secondary).frame(width: 42, alignment: .trailing)
        }.padding(.vertical, 12)
    }
}
struct MeetingPage: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Готовность пилота").font(.system(size: 24, weight: .regular)).tracking(-0.4)
                    Text("30 октября, 10:00 · 42 минуты · Толк").font(.system(size: 11)).foregroundStyle(m.p.secondary)
                }
                Spacer()
                Label("Расшифрована", systemImage: "checkmark.circle").font(.system(size: 10)).foregroundStyle(m.p.secondary).padding(.top, 5)
            }
            HStack {
                Picker("Раздел встречи", selection: .constant(1)) {
                    Text("Конспект").tag(0)
                    Text("Расшифровка").tag(1)
                    Text("Договорённости").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 320).controlSize(.small)
                Spacer()
                SymbolButton(symbol: "magnifyingglass", title: "Найти в расшифровке")
                SymbolButton(symbol: "square.and.arrow.up", title: "Действия встречи — макет")
            }.padding(.top, 24).padding(.bottom, 23)
            Rule()
            HStack(spacing: 7) {
                Image(systemName: "link").font(.system(size: 10))
                Text("Открыто из ответа · 14:32").font(.system(size: 10))
            }.foregroundStyle(m.p.blue).padding(.top, 18).padding(.bottom, 13)
            VStack(spacing: 4) {
                line("13:58", speaker: "Я", text: "Давайте зафиксируем, что именно входит в первый запуск. Нужен экспорт или пока только просмотр?")
                line("14:32", speaker: "Участники", text: "В пилот идём с чтением. Экспорт включим, когда получим подтверждение от безопасности.", selected: true)
                line("15:06", speaker: "Я", text: "Тогда проверку выносим в отдельную задачу и сохраняем ссылку на это обсуждение.")
                line("15:24", speaker: "Участники", text: "Да, условия пилота нужно обновить после проверки. Сейчас там остаётся прежняя формулировка про экспорт.")
                line("16:02", speaker: "Я", text: "Хорошо. Дату запуска оставляем 12 ноября, объём первой версии не расширяем.")
                line("28:10", speaker: "Участники", text: "Кто будет принимать результат на стороне команды? Этот вопрос пока оставим открытым.")
            }.frame(maxWidth: 900, alignment: .leading)
        }
    }
    func line(_ time: String, speaker: String, text: String, selected: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(time).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(selected ? m.p.blue : m.p.secondary).frame(width: 44, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(speaker).font(.system(size: 11, weight: .semibold)).foregroundStyle(m.p.secondary)
                Text(text).font(.system(size: 14)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 14).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? m.p.tint : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
struct DocumentPage: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(m.p.secondary)
                Text("Условия пилота.pdf").font(.system(size: 12, weight: .medium))
                Text("v3").font(.system(size: 10)).foregroundStyle(m.p.secondary)
                Spacer()
                Text("Страница 7 из 18").font(.system(size: 10)).foregroundStyle(m.p.secondary)
                SymbolButton(symbol: "magnifyingglass", title: "Поиск в документе")
            }.padding(.horizontal, 24).frame(height: 49)
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { Text("Условия проведения пилота").font(.system(size: 23, weight: .medium)); Spacer() }
                    Text("Север / Клиентский портал").font(.system(size: 11)).foregroundStyle(m.p.secondary).padding(.top, 10)
                    Rule().padding(.top, 22).padding(.bottom, 29)
                    Text("4. Доступ к данным").font(.system(size: 16, weight: .medium))
                    paragraph("Участники пилота получают доступ к согласованному набору данных в режиме просмотра. Состав участников подтверждается владельцем проекта.")
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Экспорт данных допускается после проверки безопасности. До подтверждения доступен только просмотр.")
                            .font(.system(size: 14)).lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        HStack { Image(systemName: "link").font(.system(size: 10)); Text("Фрагмент из ответа").font(.system(size: 10, weight: .medium)) }.foregroundStyle(m.p.blue)
                    }.padding(16).background(m.p.tint, in: RoundedRectangle(cornerRadius: 6)).padding(.top, 20)
                    Text("5. Приёмка результата").font(.system(size: 16, weight: .medium)).padding(.top, 30)
                    paragraph("Критерии приёмки и ответственный согласуются до начала пилота. Изменения условий фиксируются отдельным решением со ссылкой на исходное обсуждение.")
                    Text("6. Границы первой версии").font(.system(size: 16, weight: .medium)).padding(.top, 29)
                    paragraph("Первая версия предназначена для проверки сценариев просмотра. Расширение доступа согласуется после оценки результатов пилота.")
                    Rule().padding(.top, 33).padding(.bottom, 13)
                    HStack { Text("Текстовый макет страницы · версия 3"); Spacer(); Text("7") }.font(.system(size: 10)).foregroundStyle(m.p.secondary)
                }.padding(m.fullscreen ? 48 : 35).frame(maxWidth: 760)
                    .background(m.p.surface, in: RoundedRectangle(cornerRadius: 3))
                    .shadow(color: .black.opacity(m.dark ? 0.18 : 0.07), radius: 10, x: 0, y: 4)
                    .padding(.horizontal, m.fullscreen ? 55 : 27).padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            }.background(m.p.raised)
        }
    }
    func paragraph(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).lineSpacing(7).fixedSize(horizontal: false, vertical: true).padding(.top, 15)
    }
}
struct ContextChat: View {
    @EnvironmentObject var m: Model
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Диалог проекта", systemImage: "bubble.left.and.bubble.right").font(.system(size: 12, weight: .medium))
                Spacer()
                SymbolButton(symbol: "square.and.pencil", title: "Новый вопрос — макет")
                SymbolButton(symbol: "sidebar.right", title: "Скрыть диалог") { m.showChat = false }
            }.padding(.horizontal, 18).frame(height: 49)
            Rule().padding(.horizontal, 17)
            ScrollView {
                VStack(alignment: .leading, spacing: 21) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text("Клиентский портал · 2 источника").font(.system(size: 10))
                    }.foregroundStyle(m.p.secondary)
                    Text("Что мешает запуску пилота?")
                        .font(.system(size: 13, weight: .medium)).lineSpacing(4)
                        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                        .background(m.p.surface.opacity(m.dark ? 0.8 : 0.95), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Два вопроса остаются открытыми.").font(.system(size: 13)).lineSpacing(4)
                        Text("Экспорт").font(.system(size: 12, weight: .semibold)).padding(.top, 3)
                        Text("Встреча ограничивает пилот чтением, документ допускает экспорт после проверки. Подтверждения проверки в материалах нет.")
                            .font(.system(size: 12)).lineSpacing(5)
                        SourceLink(text: "Встреча · 14:32", page: .meeting)
                        SourceLink(text: "Условия · с. 7", page: .document)
                    }
                    VStack(alignment: .leading, spacing: 11) {
                        Text("Приёмка").font(.system(size: 12, weight: .semibold))
                        Text("Владелец не назначен. На встрече вопрос оставили открытым.").font(.system(size: 12)).lineSpacing(5)
                        SourceLink(text: "Встреча · 28:10", page: .meeting)
                    }
                    HStack(spacing: 17) {
                        SymbolButton(symbol: "doc.on.doc", title: "Копировать ответ — макет")
                        SymbolButton(symbol: "bookmark", title: "Сохранить в память — макет")
                        Spacer()
                        Text("По источникам").font(.system(size: 10)).foregroundStyle(m.p.secondary)
                    }.padding(.top, 2)
                    if m.page != .overview {
                        Rule()
                        VStack(alignment: .leading, spacing: 11) {
                            HStack { Text("Открытый источник").font(.system(size: 11, weight: .medium)); Spacer(); Image(systemName: "link").font(.system(size: 10)) }.foregroundStyle(m.p.secondary)
                            SourceLink(text: m.page == .meeting ? "Готовность пилота · 14:32" : "Условия пилота · с. 7", page: m.page)
                            Text(m.page == .meeting ? "«В пилот идём с чтением…»" : "«Экспорт данных допускается после проверки безопасности…»")
                                .font(.system(size: 11)).foregroundStyle(m.p.secondary).lineSpacing(4)
                            Text("Цитата открыта только в Golos Meet").font(.system(size: 9)).foregroundStyle(m.p.secondary)
                        }
                    }
                }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 20)
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 14) {
                TextField("Спросить по проекту…", text: $m.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(2...4)
                HStack {
                    Button {} label: { Image(systemName: "plus").font(.system(size: 12)) }.buttonStyle(.borderless).help("Выбрать локальные материалы — макет")
                    Spacer()
                    Text("⌘↵").font(.system(size: 10)).foregroundStyle(m.p.secondary)
                    Button {} label: { Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)).frame(width: 19, height: 19) }.buttonStyle(.bordered).controlSize(.small).disabled(m.draft.isEmpty)
                }
            }.padding(14).background(m.p.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(m.p.rule, lineWidth: 1))
                .padding(.horizontal, 14).padding(.bottom, 9)
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield").font(.system(size: 9))
                Text("OpenRouter · разрешено для проекта").font(.system(size: 9))
            }.foregroundStyle(m.p.secondary).padding(.horizontal, 20).padding(.bottom, 14)
        }.frame(maxHeight: .infinity).background(m.p.chat, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel("Диалог проекта")
    }
}

// A read-only status is intentionally legible even in an inactive window.
// Drawing within its own NSView avoids AppKit retinting label/control children
// as inactive toolbar affordances during offscreen export.
final class RecordingReadout: NSView {
    let dark: Bool
    init(dark: Bool) {
        self.dark = dark
        super.init(frame: NSRect(x: 0, y: 0, width: 213, height: 24))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Запись, 18 минут 42 секунды, две дорожки; синтетический макет")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(paletteColors: [.systemRed]))!
        image.isTemplate = false
        image.draw(in: NSRect(x: 0, y: 5, width: 13, height: 13))
        let color = dark ? NSColor(calibratedWhite: 0.92, alpha: 1) : NSColor(calibratedWhite: 0.15, alpha: 1)
        let text = NSAttributedString(string: "Запись 18:42  ·  2 дорожки", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: color
        ])
        text.draw(at: NSPoint(x: 20, y: 5))
    }
}
@MainActor final class ResearchToolbar: NSObject, NSToolbarDelegate {
    let model: Model
    init(_ model: Model) { self.model = model }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
    var ids: [NSToolbarItem.Identifier] { [.init("sidebar"), .init("back"), .init("crumb"), .flexibleSpace, .init("recording"), .init("inspector")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        if id.rawValue == "crumb" {
            let label = NSTextField(labelWithString: "Golos Meet  /  Север")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            item.view = label
            item.label = "Проект"
        } else if id.rawValue == "recording" {
            // Read-only ongoing state: never inherit disabled toolbar styling.
            item.autovalidates = false
            item.isEnabled = true
            if #available(macOS 26.0, *) { item.isBordered = false }
            item.view = RecordingReadout(dark: model.dark)
            item.label = "Состояние записи — синтетический макет"
        } else {
            let symbol = id.rawValue == "sidebar" ? "sidebar.left" : (id.rawValue == "back" ? "chevron.left" : "sidebar.right")
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: id.rawValue)!, target: self, action: #selector(activate(_:)))
            button.identifier = .init(id.rawValue)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.frame = NSRect(x: 0, y: 0, width: 28, height: 25)
            item.view = button
            item.label = id.rawValue
        }
        return item
    }
    @objc func activate(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "sidebar": model.showSidebar.toggle()
        case "inspector": model.showChat.toggle()
        default: model.page = .overview
        }
    }
}
@main struct MockHost {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "--export" else {
            print("Synthetic research-only host. Usage: MockHost --export <output-directory>")
            return
        }
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("golos-ui18-v2-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        for page in Page.allCases {
            try capture(Model(page), width: 1440, height: 900, name: "A2-\(page.rawValue)-wide-light", output: output)
            try capture(Model(page, dark: true, fullscreen: true), width: 1920, height: 1080, name: "A2-\(page.rawValue)-fullscreen-dark", output: output)
        }
        try capture(Model(.meeting, reduced: true), width: 1440, height: 900, name: "A2-meeting-reduced", output: output)
        print("Exported 7 new native conceptual renders")
    }
    @MainActor static func capture(_ model: Model, width: CGFloat, height: CGFloat, name: String, output: URL) throws {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: model.dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height - 52), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Golos Meet — макет A, synthetic"
        window.appearance = app.appearance
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = NSColor.windowBackgroundColor
        let delegate = ResearchToolbar(model)
        let toolbar = NSToolbar(identifier: "ResearchToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: false)
        let host = NSHostingView(rootView: Workspace().environmentObject(model))
        host.frame = window.contentLayoutRect
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.18))
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            throw NSError(domain: "UI18Native", code: 1)
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "UI18Native", code: 2) }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        withExtendedLifetime(delegate) {}
        window.contentView = nil
        window.close()
    }
}
