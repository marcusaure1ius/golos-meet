import AppKit
import SwiftUI

// Research-only host. This file imports no Golos module and creates no services.
// All strings below are synthetic fixtures, never read from the user's library.
enum Scene: String, CaseIterable {
    case overview, search, meeting, document, memory, tasks, taskEdit, settings, states, health
    var title: String {
        switch self {
        case .overview: return "Обзор проекта"
        case .search: return "Поиск"
        case .meeting: return "Готовность пилота"
        case .document: return "Условия пилота.pdf"
        case .memory: return "Память проекта"
        case .tasks: return "Задачи Constance"
        case .taskEdit: return "Редактирование задачи"
        case .settings: return "Настройки и разрешения"
        case .states: return "Состояния рабочей области"
        case .health: return "Запись и строка меню"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .meeting: return "waveform"
        case .document: return "doc.text"
        case .memory: return "clock.arrow.circlepath"
        case .tasks, .taskEdit: return "checklist"
        case .settings: return "gearshape"
        case .states: return "rectangle.3.group"
        case .health: return "record.circle"
        }
    }
}
@MainActor final class Fixture: ObservableObject {
    @Published var scene: Scene
    @Published var sidebar = true
    @Published var inspector = true
    @Published var query = "экспорт пилота"
    @Published var draft = ""
    let variant: String
    let dark: Bool
    let opaque: Bool
    let fullscreen: Bool
    init(_ variant: String, _ scene: Scene, dark: Bool = false, opaque: Bool = false, fullscreen: Bool = false) {
        self.variant = variant; self.scene = scene; self.dark = dark
        self.opaque = opaque; self.fullscreen = fullscreen
    }
}
let paper = Color(nsColor: .textBackgroundColor)
let chrome = Color(nsColor: .windowBackgroundColor)
let quiet = Color(nsColor: .controlBackgroundColor)

struct NavMaterial: ViewModifier {
    let opaque: Bool
    func body(content: Content) -> some View {
        if opaque { content.background(chrome) }
        else { content.background(.regularMaterial) }
    }
}
struct GlassControl: ViewModifier {
    let opaque: Bool
    let renderingSnapshot = true
    @ViewBuilder func body(content: Content) -> some View {
        // Offscreen cacheDisplay cannot prove adaptive optical glass.
        // Keep an opaque conceptual backing in exported images.
        if #available(macOS 26.0, *), !opaque, !renderingSnapshot {
            content.glassEffect(.regular, in: .capsule)
        } else { content.background(chrome, in: Capsule()) }
    }
}
struct Tag: View {
    let text: String
    var icon: String? = nil
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 5) { if let icon { Image(systemName: icon) }; Text(text) }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
struct SectionTitle: View {
    let title: String
    var trailing = ""
    var body: some View {
        HStack { Text(title).font(.system(size: 17, weight: .semibold)); Spacer()
            if !trailing.isEmpty { Text(trailing).font(.system(size: 12)).foregroundStyle(.secondary) }
        }.padding(.top, 12).padding(.bottom, 7)
    }
}
struct SourceButton: View {
    @EnvironmentObject var f: Fixture
    let title: String
    let scene: Scene
    var body: some View {
        Button { f.scene = scene; f.inspector = true } label: {
            Label(title, systemImage: scene.icon).font(.system(size: 12, weight: .medium))
        }.buttonStyle(.plain).foregroundStyle(Color.accentColor).accessibilityLabel("Открыть источник: \(title)")
    }
}
struct Sidebar: View {
    @EnvironmentObject var f: Fixture
    func row(_ title: String, _ icon: String, scene: Scene, inset: CGFloat = 0, count: String = "", highlight: Bool = true) -> some View {
        Button { f.scene = scene } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 17)
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                if !count.isEmpty { Text(count).foregroundStyle(.secondary).font(.system(size: 11)) }
            }.font(.system(size: 13, weight: highlight && f.scene == scene ? .medium : .regular))
                .padding(.leading, inset + 10).padding(.trailing, 10).padding(.vertical, 9)
                .background(highlight && f.scene == scene ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(title)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Image(systemName: "waveform.circle.fill").font(.title2); Text("Golos Meet").font(.system(size: 16, weight: .semibold)); Spacer() }
                .padding(.horizontal, 10).padding(.top, 15).padding(.bottom, 16)
            row("Поиск в материалах", "magnifyingglass", scene: .search)
            row("Входящие", "tray", scene: .overview, count: "3", highlight: false)
            Text("ПРОЕКТЫ").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 24).padding(.bottom, 8)
            HStack { Image(systemName: "chevron.down").font(.system(size: 9)); Text("Север").font(.system(size: 13, weight: .semibold)); Spacer() }.padding(.horizontal, 12).padding(.vertical, 7)
            HStack(spacing: 8) { Image(systemName: "folder.fill").foregroundStyle(Color.accentColor); Text("Клиентский портал").fontWeight(.medium) }.font(.system(size: 13)).padding(.leading, 26).padding(.vertical, 9)
            row("Обзор", "square.grid.2x2", scene: .overview, inset: 20)
            row("Встречи", "waveform", scene: .meeting, inset: 20, count: "8")
            row("Документы", "doc.text", scene: .document, inset: 20, count: "12")
            row("Память", "clock.arrow.circlepath", scene: .memory, inset: 20)
            row("Задачи Constance", "checklist", scene: .tasks, inset: 20, count: "4")
            HStack(spacing: 8) { Image(systemName: "chevron.right").font(.system(size: 9)); Image(systemName: "folder"); Text("Мобильный кабинет").lineLimit(1) }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 14)
            Text(f.variant == "A" ? "НЕДАВНИЕ МАТЕРИАЛЫ" : "ДИАЛОГИ ПРОЕКТА").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 12).padding(.top, 22).padding(.bottom, 7)
            row(f.variant == "A" ? "Готовность пилота" : "Что мешает запуску?", f.variant == "A" ? "waveform" : "bubble.left", scene: .meeting, highlight: false)
            row(f.variant == "A" ? "Условия пилота.pdf" : "История решений", f.variant == "A" ? "doc.text" : "bubble.left", scene: .memory, highlight: false)
            Spacer()
            Divider().padding(.horizontal, 10)
            row("Модели и разрешения", "gearshape", scene: .settings)
            HStack(spacing: 6) { Image(systemName: "internaldrive"); Text("Индекс на этом Mac") }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
        }.padding(.horizontal, 9).frame(width: 236).modifier(NavMaterial(opaque: f.opaque))
            .accessibilityElement(children: .contain).accessibilityLabel("Проекты")
    }
}
struct Workspace: View {
    @EnvironmentObject var f: Fixture
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("МАКЕТ \(f.variant) · синтетические данные").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(f.opaque ? "Reduce Transparency / Motion" : (f.fullscreen ? "Полноэкранная композиция · 1920 × 1080" : "Широкое окно · 1440 × 900"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 18).frame(height: 30).background(chrome)
            HStack(spacing: 0) {
                if f.sidebar { Sidebar(); Divider() }
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    if f.scene == .states { StatesBoard() }
                    else if f.scene == .health { HealthBoard() }
                    else if f.scene == .settings { SettingsMock() }
                    else {
                        HStack(spacing: 0) {
                            if f.variant == "B" {
                                ChatPane(primary: true).frame(width: f.inspector ? (f.fullscreen ? 650 : 510) : nil)
                                if f.inspector { Divider(); material(isInspector: true) }
                            } else {
                                material(isInspector: false)
                                if f.inspector { Divider(); ChatPane(primary: false).frame(width: f.fullscreen ? 390 : 340) }
                            }
                        }
                    }
                }
            }
        }.background(paper).foregroundStyle(.primary).font(.system(size: 14))
            .preferredColorScheme(f.dark ? .dark : .light)
    }
    var toolbar: some View {
        HStack(spacing: 14) {
            Button { f.sidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("Показать проекты")
            VStack(alignment: .leading, spacing: 3) {
                Text("Север / Клиентский портал").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(f.variant == "B" ? "Что мешает запуску пилота?" : f.scene.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 5)
            Button { f.scene = .health } label: {
                HStack(spacing: 7) { Image(systemName: "record.circle.fill").foregroundStyle(.red); Text("Запись 18:42").monospacedDigit(); Text("2 дорожки").foregroundStyle(.secondary) }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8)
            }.buttonStyle(.plain).modifier(GlassControl(opaque: f.opaque)).accessibilityLabel("Запись, 18 минут 42 секунды, две дорожки готовы")
            Button { f.inspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("Показать контекстную панель")
        }.buttonStyle(.borderless).padding(.horizontal, 20).frame(height: 70).modifier(NavMaterial(opaque: f.opaque))
    }
    func material(isInspector: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Label(isInspector ? "Материалы" : "Рабочая область", systemImage: "rectangle.split.2x1").fontWeight(.medium)
                if isInspector {
                    Button("Память") { f.scene = .memory }
                    Button("Задачи") { f.scene = .tasks }
                }
                Spacer()
                Menu { ForEach(Scene.allCases, id: \.self) { scene in Button(scene.title) { f.scene = scene } } } label: { Label("Открыть", systemImage: "plus") }
            }.font(.system(size: 12)).padding(.horizontal, 24).frame(height: 43).background(quiet.opacity(0.6))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch f.scene {
                    case .overview: Overview()
                    case .search: SearchMock()
                    case .meeting: MeetingMock()
                    case .document: DocumentMock()
                    case .memory: MemoryMock()
                    case .tasks: TasksMock()
                    case .taskEdit: TaskEditorMock()
                    default: EmptyView()
                    }
                }.frame(maxWidth: 860, alignment: .leading).padding(30).frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(paper)
            .accessibilityElement(children: .contain).accessibilityLabel("Материал")
    }
}
struct Overview: View {
    @EnvironmentObject var f: Fixture
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Клиентский портал").font(.system(size: 29, weight: .semibold))
            Text("Пилот 12 ноября · Север").foregroundStyle(.secondary)
            HStack { Tag(text: "8 встреч", icon: "waveform"); Tag(text: "12 документов", icon: "doc.text"); Tag(text: "4 задачи", icon: "checklist") }.padding(.top, 4)
            SectionTitle(title: "После последней встречи", trailing: "30 октября")
            Text("Пилот начнётся с режима чтения. Экспорт пока не согласован: в документе и обсуждении разные условия.").font(.system(size: 16)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            SourceButton(title: "Готовность пилота · 14:32", scene: .meeting)
            SectionTitle(title: "Требует внимания", trailing: "2 вопроса")
            decision("Экспорт в пилоте", detail: "Нужно подтверждение безопасности до 5 ноября", icon: "exclamationmark.triangle", color: .orange)
            decision("Владелец приёмки", detail: "На встрече не назначен · уточнить у команды", icon: "person.crop.circle.badge.questionmark", color: .secondary)
            SectionTitle(title: "Материалы", trailing: "Все материалы")
            materialRow("Готовность пилота", subtitle: "Встреча · 30 октября · 42 мин", scene: .meeting)
            Divider()
            materialRow("Условия пилота.pdf", subtitle: "Документ · версия 3 · 18 страниц", scene: .document)
            Divider()
            materialRow("Решения и открытые вопросы", subtitle: "Память · обновлена после встречи", scene: .memory)
            SectionTitle(title: "Следующее действие")
            HStack(alignment: .top, spacing: 12) { Image(systemName: "circle.lefthalf.filled").foregroundStyle(.orange); VStack(alignment: .leading, spacing: 6) { Text("Проверить экспорт").fontWeight(.medium); Text("DEMO-142 · Constance · в работе").font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Button("Открыть") { f.scene = .tasks } }
        }
    }
    func materialRow(_ title: String, subtitle: String, scene: Scene) -> some View {
        Button { f.scene = scene } label: { HStack(spacing: 12) { Image(systemName: scene.icon).foregroundStyle(.secondary).frame(width: 22); VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.medium); Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.secondary) }.padding(.vertical, 7) }.buttonStyle(.plain)
    }
    func decision(_ title: String, detail: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) { Image(systemName: icon).foregroundStyle(color).frame(width: 20); VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.medium); Text(detail).font(.system(size: 13)).foregroundStyle(.secondary) } }.padding(.vertical, 8)
    }
}
struct ChatPane: View {
    @EnvironmentObject var f: Fixture
    let primary: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Label(primary ? "Диалог проекта" : "Спросить по проекту", systemImage: "bubble.left.and.bubble.right").fontWeight(.semibold); Spacer(); Image(systemName: "square.and.pencil") }.font(.system(size: 12)).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 6) { Image(systemName: "folder"); Text("Клиентский портал"); Spacer() }.font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("Что мешает запуску пилота?").font(.system(size: primary ? 22 : 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("По выбранным материалам есть два открытых вопроса.").lineSpacing(4)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Экспорт ещё не согласован").fontWeight(.semibold)
                        Text("Встреча ограничивает пилот чтением. Документ допускает экспорт после проверки безопасности. Подтверждения проверки в источниках нет.").lineSpacing(5)
                        SourceButton(title: "Встреча · 14:32", scene: .meeting)
                        SourceButton(title: "Условия пилота · с. 7", scene: .document)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Не назначен владелец приёмки").fontWeight(.semibold)
                        Text("На встрече вопрос остался открытым. В доступных материалах назначения нет.").lineSpacing(5)
                        SourceButton(title: "Встреча · 28:10", scene: .meeting)
                    }
                    Text("Это вывод по источникам, а не подтверждение текущего состояния работ.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                    Button { f.scene = .tasks; f.inspector = true } label: { Label("Открыть связанную задачу", systemImage: "arrow.up.right.square") }.font(.system(size: 12))
                    if primary { SectionTitle(title: "Контекст ответа"); Text("2 источника · версия документа 3\nВстреча 30 октября, 10:00").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5) }
                }.padding(primary ? 30 : 22).frame(maxWidth: 650, alignment: .leading)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack { Image(systemName: "checkmark.shield"); Text("Облако разрешено для проекта") }.font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Уточнить по этим источникам…", text: $f.draft, axis: .vertical).textFieldStyle(.plain).lineLimit(2...4)
                HStack { Label("2 источника", systemImage: "paperclip").font(.system(size: 11)).foregroundStyle(.secondary); Spacer(); Button { f.draft = "" } label: { Image(systemName: "arrow.up") }.help("Макет отправки: очищает поле, запрос не выполняется") }
            }.padding(16).background(quiet, in: RoundedRectangle(cornerRadius: 12)).padding(16)
        }.background(paper).frame(maxHeight: .infinity).accessibilityElement(children: .contain).accessibilityLabel("Диалог")
    }
}
struct SearchMock: View {
    @EnvironmentObject var f: Fixture
    var body: some View {
        Text("Найти в материалах").font(.system(size: 26, weight: .semibold))
        TextField("Поиск", text: $f.query).textFieldStyle(.roundedBorder).font(.system(size: 16))
        HStack { Tag(text: "Клиентский портал", icon: "folder"); Tag(text: "Все типы"); Spacer(); Text("Локально на Mac").font(.system(size: 11)).foregroundStyle(.secondary) }
        SectionTitle(title: "3 результата", trailing: "По релевантности")
        result("Условия пилота.pdf", meta: "Документ · версия 3 · страница 7", text: "Экспорт данных допускается после проверки безопасности. До подтверждения доступен только просмотр.", scene: .document)
        Divider()
        result("Готовность пилота", meta: "Встреча · 30 октября · 14:32", text: "В пилот идём с чтением. Экспорт включим, когда получим подтверждение от безопасности.", scene: .meeting)
        Divider()
        result("Режим пилота", meta: "Решение памяти · 30 октября · 2 источника", text: "Только чтение. Условия экспорта требуют уточнения; обе версии сохранены.", scene: .memory)
        Divider()
        Text("Открытие результата сохраняет запрос. Цитата ведёт к странице или времени, а не только к названию файла.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
    }
    func result(_ title: String, meta: String, text: String, scene: Scene) -> some View {
        VStack(alignment: .leading, spacing: 10) { Button { f.scene = scene } label: { Label(title, systemImage: scene.icon).font(.system(size: 16, weight: .semibold)) }.buttonStyle(.link); Text(meta).font(.system(size: 12)).foregroundStyle(.secondary); Text(text).lineSpacing(5).fixedSize(horizontal: false, vertical: true) }.padding(.vertical, 12)
    }
}
struct MeetingMock: View {
    var body: some View {
        HStack { Tag(text: "Встреча", icon: "waveform"); Tag(text: "Расшифрована", icon: "checkmark.circle"); Spacer() }
        Text("Готовность пилота").font(.system(size: 27, weight: .semibold))
        Text("30 октября · 10:00–10:42 · Клиентский портал").font(.system(size: 12)).foregroundStyle(.secondary)
        HStack { Button {} label: { Image(systemName: "play.fill") }; Text("14:32 / 42:08").monospacedDigit().font(.system(size: 12)); Slider(value: .constant(0.35)); Text("1×").font(.system(size: 12)) }.padding(12).background(quiet, in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel("Макет плеера, аудио отсутствует")
        HStack(spacing: 22) { Text("Расшифровка").fontWeight(.semibold); Text("Конспект").foregroundStyle(.secondary); Text("Договорённости").foregroundStyle(.secondary) }.font(.system(size: 13)).padding(.vertical, 10)
        Divider()
        transcript("13:58", "Я", "Давайте зафиксируем, что именно входит в первый запуск. Нужен экспорт или пока только просмотр?", selected: false)
        transcript("14:32", "Участники", "В пилот идём с чтением. Экспорт включим, когда получим подтверждение от безопасности.", selected: true)
        transcript("15:06", "Я", "Тогда проверку выносим в отдельную задачу и сохраняем ссылку на это обсуждение.", selected: false)
        transcript("28:10", "Участники", "Кто будет принимать результат на стороне команды? Этот вопрос пока оставим открытым.", selected: false)
        Text("Выделенный фрагмент открыт из ссылки в ответе.").font(.system(size: 12)).foregroundStyle(.secondary)
    }
    func transcript(_ time: String, _ speaker: String, _ text: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 15) { Text(time).monospacedDigit().font(.system(size: 12)).foregroundStyle(Color.accentColor).frame(width: 43); VStack(alignment: .leading, spacing: 9) { Text(speaker).font(.system(size: 12, weight: .semibold)); Text(text).font(.system(size: 15)).lineSpacing(6).fixedSize(horizontal: false, vertical: true) } }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(selected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
struct DocumentMock: View {
    var body: some View {
        HStack { Tag(text: "PDF", icon: "doc.text"); Tag(text: "Версия 3"); Spacer(); Text("7 из 18").font(.system(size: 12)).foregroundStyle(.secondary) }
        Text("Условия пилота.pdf").font(.system(size: 25, weight: .semibold))
        Text("Локальный документ · текстовый макет страницы").font(.system(size: 12)).foregroundStyle(.secondary)
        Divider()
        VStack(alignment: .leading, spacing: 23) {
            Text("Условия проведения пилота").font(.system(size: 23, weight: .semibold))
            Text("4. Доступ к данным").font(.system(size: 18, weight: .semibold)).padding(.top, 16)
            Text("Участники пилота получают доступ к согласованному набору данных в режиме просмотра. Состав участников подтверждается владельцем проекта.").lineSpacing(7)
            Text("Экспорт данных допускается после проверки безопасности. До подтверждения доступен только просмотр.").lineSpacing(7).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
            Text("5. Приёмка результата").font(.system(size: 18, weight: .semibold)).padding(.top, 13)
            Text("Критерии приёмки и ответственный согласуются до начала пилота. Изменения условий фиксируются отдельным решением со ссылкой на исходное обсуждение.").lineSpacing(7)
            Spacer(minLength: 20)
            HStack { Text("Север · Клиентский портал"); Spacer(); Text("7") }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(28).background(quiet.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
        SourceButton(title: "Связанный фрагмент встречи · 14:32", scene: .meeting)
    }
}
struct MemoryMock: View {
    var body: some View {
        Text("Решения и вопросы").font(.system(size: 27, weight: .semibold))
        Text("Обновлено после встречи 30 октября · история сохранена").font(.system(size: 12)).foregroundStyle(.secondary)
        SectionTitle(title: "Режим пилота")
        Text("Запуск 12 ноября, сначала только чтение.").font(.system(size: 17, weight: .medium)).lineSpacing(5)
        SourceButton(title: "Готовность пилота · 14:32", scene: .meeting)
        HStack { Tag(text: "Есть расхождение", icon: "exclamationmark.triangle", color: .orange); Spacer() }.padding(.top, 16)
        Text("Условия экспорта требуют уточнения").font(.system(size: 19, weight: .semibold))
        Text("Встреча: экспорт отложен до подтверждения.\nДокумент: допускается после проверки безопасности.").lineSpacing(7)
        SourceButton(title: "Условия пилота · версия 3 · с. 7", scene: .document)
        Text("Нет источника, подтверждающего прохождение проверки. Версии сохранены отдельно; новая формулировка не затирает предыдущую.").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
        Divider().padding(.vertical, 10)
        SectionTitle(title: "Открытый вопрос")
        Text("Кто принимает результат пилота?").font(.system(size: 17, weight: .medium))
        SourceButton(title: "Готовность пилота · 28:10", scene: .meeting)
        HStack { Button("Добавить уточнение") {}; Button("История решения") {} }.padding(.top, 12)
    }
}
struct TasksMock: View {
    @EnvironmentObject var f: Fixture
    var body: some View {
        Text("Задачи Constance").font(.system(size: 27, weight: .semibold))
        HStack { Label("Последняя синхронизация 10:48", systemImage: "arrow.triangle.2.circlepath"); Spacer(); Text("Данные макета") }.font(.system(size: 11)).foregroundStyle(.secondary)
        SectionTitle(title: "Связанные с проектом", trailing: "4 задачи")
        taskRow("DEMO-142", "Проверить экспорт", "В работе", selected: true)
        taskRow("DEMO-139", "Назначить владельца приёмки", "Открыта", selected: false)
        taskRow("DEMO-136", "Согласовать состав пилота", "Готово", selected: false)
        taskRow("DEMO-128", "Уточнить правила доступа", "Открыта", selected: false)
        Divider().padding(.vertical, 7)
        HStack { Text("DEMO-142").foregroundStyle(.secondary); Spacer(); Label("Открыть в Constance", systemImage: "arrow.up.right.square").foregroundStyle(Color.accentColor) }.font(.system(size: 12))
        Text("Проверить экспорт").font(.system(size: 20, weight: .semibold))
        HStack { Tag(text: "В работе", icon: "circle.lefthalf.filled", color: .orange); Text("Анна · до 5 ноября").font(.system(size: 12)).foregroundStyle(.secondary) }
        Text("Проверить ограничения экспорта перед пилотом. Сохранить результат проверки и согласовать обновлённые условия.").lineSpacing(5)
        SourceButton(title: "Источник: встреча · 15:06", scene: .meeting)
        SectionTitle(title: "Подзадачи", trailing: "1 из 2")
        Label("Собрать требования безопасности", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
        Label("Подтвердить условия экспорта", systemImage: "circle")
        HStack { Button("Добавить подзадачу") {}; Spacer(); Button("Редактировать") { f.scene = .taskEdit } }.padding(.top, 14)
        Text("Поля и действия — предложение для #6. Изменения в этом макете не отправляются во внешнюю систему.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
    }
    func taskRow(_ id: String, _ title: String, _ status: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) { Text(id).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 68, alignment: .leading); Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)); Spacer(); Text(status).font(.system(size: 11)).foregroundStyle(.secondary) }.padding(12).background(selected ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
struct TaskEditorMock: View {
    @EnvironmentObject var f: Fixture
    var body: some View {
        HStack { Text("DEMO-142").foregroundStyle(.secondary); Spacer(); Tag(text: "Черновик · не отправлен", icon: "pencil") }.font(.system(size: 12))
        Text("Редактирование задачи").font(.system(size: 26, weight: .semibold))
        Text("Предложение интерфейса. Поля и операции ещё проверяются в #6.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
        SectionTitle(title: "Название")
        TextField("Название", text: .constant("Проверить экспорт")).textFieldStyle(.roundedBorder)
        SectionTitle(title: "Описание")
        Text("Проверить ограничения экспорта перед пилотом. Сохранить результат проверки и согласовать обновлённые условия.").lineSpacing(5).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(quiet, in: RoundedRectangle(cornerRadius: 7))
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) { Text("Статус").font(.system(size: 12)).foregroundStyle(.secondary); Picker("Статус", selection: .constant(1)) { Text("Открыта").tag(0); Text("В работе").tag(1) }.labelsHidden() }
            VStack(alignment: .leading, spacing: 10) { Text("Ответственный").font(.system(size: 12)).foregroundStyle(.secondary); TextField("Ответственный", text: .constant("Анна")).textFieldStyle(.roundedBorder) }
        }
        SectionTitle(title: "Подзадачи")
        Label("Собрать требования безопасности", systemImage: "checkmark.circle")
        TextField("Название подзадачи", text: .constant("Подтвердить условия экспорта")).textFieldStyle(.roundedBorder)
        Button("Добавить подзадачу") {}
        Divider().padding(.vertical, 10)
        SourceButton(title: "Связь с источником · встреча · 15:06", scene: .meeting)
        HStack { Button("Отменить") { f.scene = .tasks }; Spacer(); Button("Сохранить в Constance") {}.disabled(true) }
        Text("Отправка отключена в макете. В продукте: сохранить черновик → отправить → получить подтверждение; при сбое правки остаются видны.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
    }
}
struct StateTile: View {
    let icon: String, title: String, text: String, action: String
    var color: Color = .secondary
    var body: some View {
        VStack(alignment: .leading, spacing: 15) { Image(systemName: icon).font(.system(size: 24)).foregroundStyle(color); Text(title).font(.system(size: 18, weight: .semibold)); Text(text).font(.system(size: 14)).lineSpacing(5).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 12); Button(action) {} }.padding(24).frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading).background(quiet, in: RoundedRectangle(cornerRadius: 10))
    }
}
struct StatesBoard: View {
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Text("Состояния — общие для A и B").font(.system(size: 27, weight: .semibold))
            Text("Сохраняют положение панели и предлагают конкретное восстановление.").foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                StateTile(icon: "tray", title: "В проекте пока пусто", text: "Добавьте документы или назначьте существующую встречу этому проекту.", action: "Добавить материалы")
                StateTile(icon: "hourglass", title: "Индексируем 3 из 12", text: "Файлы остаются на Mac. Запись встречи продолжает работать независимо.", action: "Отменить индексацию")
                StateTile(icon: "exclamationmark.triangle", title: "Не удалось прочитать PDF", text: "Файл защищён паролем. Оригинал сохранён, остальные материалы доступны.", action: "Выбрать другой файл", color: .orange)
                StateTile(icon: "lock", title: "Облако не разрешено", text: "Локальный поиск доступен. Для ответа проверьте разрешения всех владельцев источника.", action: "Разрешения проекта")
                StateTile(icon: "arrow.triangle.branch", title: "Версии расходятся", text: "Встреча: только чтение. Документ: экспорт после проверки. Оба источника сохранены.", action: "Сравнить источники", color: .orange)
                StateTile(icon: "wifi.slash", title: "Constance недоступен", text: "Последние данные — 10:48. Черновик правок сохранён локально, отправка не подтверждена.", action: "Повторить соединение", color: .orange)
            }
        }.padding(30) }.background(paper)
    }
}
struct HealthBoard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 38) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Состояние записи").font(.system(size: 27, weight: .semibold))
                Text("Видно из любого проекта и во fullscreen.").foregroundStyle(.secondary)
                Label("Запись 18:42 · обе дорожки готовы", systemImage: "record.circle.fill").foregroundStyle(.red).font(.system(size: 16, weight: .medium))
                Text("Микрофон: тишина / mute\nТолк: сигнал поступает").lineSpacing(9)
                Divider()
                Text("При потере дорожки").font(.system(size: 18, weight: .semibold))
                Label("Не получаем звук Толка", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Запись микрофона продолжается. Проверьте источник и разрешения захвата. Тишина сама по себе не считается ошибкой.").lineSpacing(6)
                Button("Открыть диагностику записи") {}
                Spacer()
                Text("Это макет menu bar popover. Реальный статус-элемент и аудиозахват не создаются.").font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 20) {
                HStack { Image(systemName: "waveform"); Text("18:42").monospacedDigit(); Spacer(); Text("Строка меню").foregroundStyle(.secondary) }.font(.system(size: 12))
                Divider()
                HStack { Image(systemName: "record.circle.fill").foregroundStyle(.red); Text("Идёт запись").fontWeight(.semibold); Spacer(); Text("18:42").monospacedDigit() }
                Text("Клиентский портал\nТолк · две дорожки").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(6)
                Label("Микрофон готов · тишина", systemImage: "mic")
                Label("Звук Толка поступает", systemImage: "speaker.wave.2")
                Divider()
                Button("Открыть встречу") {}
                Button("Остановить и сохранить") {}
                Divider()
                Text("API Толка: доступен\nНикакие реальные проверки не выполнялись").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(5)
            }.padding(24).frame(width: 320).background(quiet, in: RoundedRectangle(cornerRadius: 16))
        }.padding(38).frame(maxWidth: .infinity, maxHeight: .infinity).background(paper)
    }
}
struct SettingsMock: View {
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Text("Разрешения и подключения").font(.system(size: 27, weight: .semibold))
            Text("Макет настроек · секреты и реальные значения не используются").foregroundStyle(.secondary)
            SectionTitle(title: "Клиентский портал")
            Toggle("Разрешить облачную генерацию для проекта", isOn: .constant(true))
            Text("Отправляются только выбранные фрагменты. Для общего источника нужно разрешение каждого проекта-владельца.").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(5)
            Divider()
            SectionTitle(title: "На этом Mac")
            Label("Локальная модель поиска · готова (макет)", systemImage: "internaldrive")
            Label("Микрофон · состояние не запрашивалось", systemImage: "mic")
            Label("Захват звука · состояние не запрашивалось", systemImage: "speaker.wave.2")
            Divider()
            SectionTitle(title: "Подключения")
            Text("Толк · настроить пространство и ключ")
            Text("OpenRouter · настроить генерацию")
            Text("Constance · сопоставить проект")
            Text("Проверка соединения выполняется отдельным явным действием в будущем приложении.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(maxWidth: 750, alignment: .leading).padding(40).frame(maxWidth: .infinity, alignment: .leading) }.background(paper)
    }
}

@main struct MockHost {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        guard args.count == 3, args[1] == "--export" else {
            print("Research-only native render host. Usage: MockHost --export <output-directory>")
            return
        }
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("golos-ui18-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        // Only fixed synthetic inputs. No UserDefaults, Keychain, networking or audio.
        for variant in ["A", "B"] {
            for scene in [Scene.overview, .search, .meeting, .document, .memory, .tasks, .taskEdit] {
                try capture(Fixture(variant, scene), width: 1440, height: 900, name: "\(variant)-\(scene.rawValue)-wide-light", output: output)
            }
            try capture(Fixture(variant, .meeting, dark: true, fullscreen: true), width: 1920, height: 1080, name: "\(variant)-meeting-fullscreen-dark", output: output)
            try capture(Fixture(variant, .overview, opaque: true), width: 1440, height: 900, name: "\(variant)-overview-reduced", output: output)
        }
        try capture(Fixture("A", .states), width: 1440, height: 1000, name: "shared-states", output: output)
        try capture(Fixture("A", .health), width: 1440, height: 900, name: "shared-recording", output: output)
        try capture(Fixture("A", .settings), width: 1440, height: 900, name: "shared-settings", output: output)
        print("Exported 21 native conceptual renders to \(output.path)")
    }
    @MainActor static func capture(_ fixture: Fixture, width: CGFloat, height: CGFloat, name: String, output: URL) throws {
        let view = NSHostingView(rootView: Workspace().environmentObject(fixture).frame(width: width, height: height))
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: fixture.dark ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "UI18", code: 1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "UI18", code: 2) }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        window.contentView = nil
        window.close()
    }
}
