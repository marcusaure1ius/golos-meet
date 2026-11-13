import SwiftUI

/// Panel: overview, paged history, queue states, provenance and manual
/// corrections/retractions. Consent and queue actions arrive in a follow-up
/// part of #37.
struct ProjectMemoryPanel: View {
    @ObservedObject var model: ProjectMemoryPanelModel
    @EnvironmentObject private var projects: ProjectLibrary
    @Environment(\.palette) private var p
    var onBack: (() -> Void)?
    var onSettings: (() -> Void)?
    @State private var tab = "Обзор"
    @State private var policies = false
    @State private var owners: Set<UUID> = []
    @State private var editing: MemoryEvent?
    @State private var retracting = false
    @State private var text = ""
    @State private var earliest = Date()
    @State private var latest = Date()
    @State private var hasDecisionDate = false
    @State private var decisionDate = Date()

    init(model: ProjectMemoryPanelModel, onBack: (() -> Void)? = nil, onSettings: (() -> Void)? = nil, initialTab: String = "Обзор") {
        self.model = model; self.onBack = onBack; self.onSettings = onSettings; _tab = State(initialValue:initialTab)
    }
    var body: some View {
        Group {
            if let destination = model.destination {
                KnowledgeSourceView(destination:destination,onBack:model.back,backTitle:"К памяти проекта")
            } else {
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        heading
                        if model.loading { ProgressView("Проверяем память и источники…").controlSize(.small) }
                        if let notice = model.notice { status("Требуется внимание",notice) }
                        if !model.loading {
                            if let preview = model.request { context(preview) }
                            else if let preview = model.correction { correctionPreview(preview) }
                            else if let event = editing { editor(event) }
                            else if let proof = model.inspected { details(proof) }
                            else if model.projectID != nil {
                                controls
                                if tab == "Очередь" { jobs }
                                else if tab == "История" { history }
                                else { overview }
                            } else {
                                status("Выберите проект",model.allowedProjects?.isEmpty == true ? "У этой встречи нет проекта. Назначьте его кнопкой «Проекты» в деталях встречи." : "Память и очередь ограничены выбранным проектом.")
                            }
                        }
                        if model.busy {
                            HStack { ProgressView("Выполняем действие…").controlSize(.small); Button("Отменить действие") { model.cancelAction() }.buttonStyle(GhostButton()) }
                        }
                    }.padding(24).frame(maxWidth:900,alignment:.leading).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }
        .background(p.bg)
        .onChange(of:model.projectID) { _,_ in editing = nil }
        .sheet(isPresented:$policies) { ProjectCloudSettings(projectIDs:owners,initialID:model.projectID).environmentObject(projects) }
    }
    private var heading: some View {
        VStack(alignment:.leading,spacing:10) {
            if let onBack { Button("К проекту",action:onBack).buttonStyle(.plain).foregroundStyle(p.link) }
            HStack {
                Text("Память проекта").font(.system(size:22,weight:.semibold)).foregroundStyle(p.ink)
                Spacer()
                Button { model.reload() } label: { Image(systemName:"arrow.clockwise") }
                    .buttonStyle(GhostButton()).help("Обновить память и проверить источники").accessibilityLabel("Обновить память").disabled(model.busy)
            }
            Picker("Проект",selection:$model.projectID) {
                Text("Выберите проект").tag(Optional<UUID>.none)
                ForEach(model.projects.filter { model.allowedProjects?.contains($0.id) != false }) { project in
                    Text(projects.path(for:project.id).isEmpty ? project.name : projects.path(for:project.id)).tag(Optional(project.id))
                }
            }.accessibilityIdentifier("memory.project")
            HStack {
                Button("Разрешения") { openPolicies() }.buttonStyle(GhostButton()).disabled(model.projectID == nil || model.loading || model.busy)
                    .help("Локальная политика облака проекта: разрешение отправки материалов и памяти внешнему сервису. Записывается на этом Mac, память и источники не меняет.")
                if let onSettings { Button("Настройки",action:onSettings).buttonStyle(GhostButton()) }
            }
            Text("Утверждения из готовых материалов. Запись и расшифровка работают независимо.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
            if !model.enabled { status("Облачное извлечение выключено","История доступна локально. Для новых обновлений включите LLM в настройках.") }
        }
    }
    private var controls: some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("Раздел памяти",selection:$tab) { ForEach(["Обзор","История","Очередь"],id:\.self) { Text($0) } }
                .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("memory.tab")
            if tab != "Очередь" {
                TextField("Фильтр показанных утверждений",text:$model.filter).textFieldStyle(.roundedBorder).accessibilityIdentifier("memory.filter")
            }
            if model.stale { status("Снимок требует обновления","Текущий контекст не подтверждён. Обновите панель перед действием.") }
        }
    }
    private var overview: some View {
        VStack(alignment:.leading,spacing:16) {
            if model.heads.isEmpty { status("Память пока пуста","Проверьте очередь: готовность источников, разрешения и недостаток данных. Пустой обзор не подтверждает полноту обработки.") }
            if model.queue.jobs.contains(where:{ $0.state == .insufficient }) { status("Для части материалов недостаточно оснований","Фрагменты посещены, но уверенные выводы получены не по всему контексту. Проверьте источники и историю.") }
            if model.headsLimited { status("Обзор ограничен 50 текущими позициями","Остальные события доступны постранично в истории. Этот обзор не охватывает весь проект.") }
            if model.queue.jobs.contains(where:{ !$0.completeCoverage }) || model.queue.backpressured {
                status("Не все материалы обработаны","Обзор может быть неполным. В очереди показаны прогресс, недостаток данных и причины остановки.")
                Button("Открыть очередь") { tab = "Очередь" }.buttonStyle(GhostButton())
            }
            ForEach(MemoryFactKind.panelKinds,id:\.rawValue) { kind in
                let values = model.visibleHeads.filter { $0.entry.event.statement.kind == kind }
                if !values.isEmpty {
                    GSectionHeader(kind.panelTitle)
                    ForEach(values) { row in event(row) }
                }
            }
            if !model.heads.isEmpty && model.visibleHeads.isEmpty { status("Совпадений нет","Фильтр применяется только к показанным позициям.") }
        }
    }
    private var history: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("История сохранена. Показано до 50 событий; фильтр действует на этой странице.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
            if model.history.isEmpty { status("Событий пока нет","Новые извлечения и ручные изменения появятся здесь со своим происхождением.") }
            ForEach(model.visibleHistory) { row in event(row) }
            HStack {
                if model.page != nil { Button("К новым событиям") { model.reload() }.buttonStyle(GhostButton()) }
                if let older = model.older { Button("Более ранние события") { model.reload(before:older) }.buttonStyle(GhostButton()) }
            }
        }
    }
    private func event(_ row: MemoryPanelEntry) -> some View {
        let e = row.entry.event
        return GCard {
            VStack(alignment:.leading,spacing:8) {
                Text(e.action == .retraction ? "Отменено" : row.usable ? "Текущее утверждение" : row.head == nil ? "Событие истории" : "Требует проверки")
                    .font(.system(size:12,weight:.semibold)).foregroundStyle(row.usable ? p.link : p.ink)
                Text(e.statement.text).font(.system(size:14)).textSelection(.enabled)
                if let range = e.statement.deadline { Text("Срок: \(day(range.earliest)) — \(day(range.latest))").font(.system(size:13,weight:.semibold)) }
                conditions(e.statement)
                dates(e)
                if e.statement.kind == .completionClaim { Text("Заявление о выполнении. Внешний статус задачи не проверен и не изменён.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72)) }
                if let head = row.head, !head.conflictingEventIDs.isEmpty { Text("Есть противоречивые сведения: \(head.conflictingEventIDs.count). Откройте зависимости и историю.").font(.system(size:12)).foregroundStyle(p.danger) }
                if row.ancestry != .current || row.entry.evidenceState != .current { Text("Источник или цепочка зависимостей устарели либо недоступны. Это не текущий подтверждённый контекст.").font(.system(size:12)).foregroundStyle(p.danger) }
                if !row.entry.supersededBy.isEmpty { Text("Сохранено в истории: заменено или отменено другим событием.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72)) }
                VStack(alignment:.leading,spacing:8) {
                    Button("Источники и зависимости") { model.inspect(e) }.buttonStyle(GhostButton()).accessibilityIdentifier("memory.inspect.\(e.id)")
                    if e.projectID == model.projectID && e.action != .retraction {
                        Button("Изменить") { edit(e,false) }.buttonStyle(GhostButton()).accessibilityIdentifier("memory.edit.\(e.id)")
                        Button("Отменить факт") { edit(e,true) }.buttonStyle(GhostButton())
                    }
                }.disabled(model.busy)
            }.frame(maxWidth:.infinity,alignment:.leading).padding(14)
        }
    }
    private var jobs: some View {
        VStack(alignment:.leading,spacing:14) {
            if let message = model.queue.message { status("Очередь",message) }
            if model.queue.backpressured { status("Список ограничен","Показано до 256 источников по всему хранилищу; в списке — задания выбранного проекта. Отложенные задания продолжают обрабатываться; этот список не является полным покрытием архива.") }
            if model.queue.jobs.isEmpty { status("Заданий пока нет","Дождитесь готовности локального индекса и назначения источников проекту. Пустая очередь сама по себе не подтверждает полноту памяти.") }
            ForEach(model.queue.jobs) { job in
                GCard {
                    VStack(alignment:.leading,spacing:9) {
                        Text(sourceTitle(job.source)).font(.system(size:14,weight:.semibold))
                        Text(job.state.panelTitle).font(.system(size:13,weight:.semibold))
                        Text("Просмотрено фрагментов: \(job.completedChunks) из \(job.totalChunks) · \(job.completeCoverage ? "все посещены" : "частичное покрытие")").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
                        if !job.message.isEmpty { Text(job.message.replacingOccurrences(of:"batch",with:"набор фрагментов")).font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72)) }
                        if job.state == .insufficient { Text("Все части посещены, но достаточных оснований для уверенного обзора нет.").font(.system(size:12)) }
                        if job.state == .stale {
                            Text("Повтор не исправляет устаревшую цепочку. Проверьте зависимость и явно отмените или исправьте неверное утверждение, сохранив историю.").font(.system(size:12))
                            Button("Проверить утверждения") { tab = "Обзор"; model.reload() }.buttonStyle(GhostButton())
                        }
                        VStack(alignment:.leading,spacing:8) {
                            if job.state == .needsConsent {
                                Button("Просмотреть контекст") { model.prepare(job) }.buttonStyle(PrimaryButton()).disabled(!model.enabled || model.busy)
                                    .accessibilityIdentifier("memory.prepare.\(job.sequence)")
                            }
                            if [.failed,.limited,.cancelled,.waiting].contains(job.state) { Button("Повторить обработку") { model.retry(job) }.buttonStyle(GhostButton()).disabled(model.busy) }
                            if [.queued,.running,.partial,.backpressured,.needsConsent,.waiting].contains(job.state) { Button("Отменить обработку") { model.cancel(job) }.buttonStyle(GhostButton()).disabled(model.busy) }
                            if job.state == .denied { Button("Разрешения владельцев") { openPolicies(job) }.buttonStyle(GhostButton()).disabled(model.busy) }
                        }
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                }
            }
        }
    }
    /// Full raw + derived context of this exact batch, shown before a one-time
    /// consent. Nothing is sent until the explicit per-part approval below.
    private func context(_ request: MemoryUpdateRequest) -> some View {
        VStack(alignment:.leading,spacing:16) {
            GSectionHeader("Выбранный контекст одной части")
            Text("Получатель: \(model.provider). \(request.fragments.count) сырых фрагментов и \(request.parents.count) событий памяти. JSON: \(request.payload.count) символов / \(request.payload.utf8.count) байт.").font(.system(size:13))
            Text("Передадим имя проекта, выбранные тексты, заголовки, локации и метаданные ниже. Скрытые исходные зависимости производной памяти не добавляются как сырой текст.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
            ForEach(request.checkpoint.projects) { owner in
                Text("\(owner.name) — \(owner.cloudPolicy.questionLabel)").font(.system(size:13,weight:.semibold))
            }
            ForEach(Array(request.fragments.enumerated()),id:\.element.id) { i,hit in
                VStack(alignment:.leading,spacing:6) {
                    Text("S\(i+1) · \(hit.source.title) · \(KnowledgeSearchLocation.label(hit.chunk))").font(.system(size:13,weight:.semibold))
                    Text("Дата источника неизвестна").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
                    if let doc = hit.source.document { Text("Импорт: \(importDay(doc.importedAt)) — не дата решения").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72)) }
                    Text("Владельцы: " + owners(hit.source.owners,in:request)).font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
                    Text(hit.chunk.text).font(.system(size:14)).textSelection(.enabled)
                }
                Divider()
            }
            ForEach(Array(request.parents.enumerated()),id:\.element.id) { i,e in
                VStack(alignment:.leading,spacing:6) {
                    Text("M\(i+1) · \(e.statement.kind.panelTitle)").font(.system(size:13,weight:.semibold))
                    Text(e.statement.text).font(.system(size:14)).textSelection(.enabled)
                    Text("Условия: " + e.statement.conditions.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator:", ")).font(.system(size:12))
                    if let range = e.statement.deadline { Text("Срок: \(day(range.earliest)) — \(day(range.latest))").font(.system(size:13,weight:.semibold)) }
                    Text("Владельцы производного контекста: " + owners(Set(e.ownerProjectIDs),in:request)).font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
                    dates(e)
                }
                Divider()
            }
            Text("Полное происхождение: \(request.consumedSources.count) опорных фрагментов. Разрешения всех их первоначальных и текущих владельцев проверяются перед каждой отправкой.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
            ForEach(Array(request.consumedSources.enumerated()),id:\.offset) { _,ref in Text(ref.title + " · " + KnowledgeSearchLocation.label(ref.chunk)).font(.system(size:12)) }
            DisclosureGroup("Точный JSON запроса") { Text(request.payload).font(.system(size:11,design:.monospaced)).textSelection(.enabled) }
            if request.denied { status("Отправка запрещена","Один из владельцев выбрал локальную обработку. Разовое согласие не отменяет запрет.") }
            else {
                Text("Отмена остановит дальнейшую работу, но не отзывает уже отправленные данные.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
                Text("Разрешение действует только для этой точной части. Следующая часть, изменённый контекст и перезапуск потребуют нового согласия.").font(.system(size:13,weight:.semibold))
                if !model.canSend { Text("Очередь завершает другую операцию либо контекст изменился. Отправка сейчас недоступна.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72)) }
                Button("Разрешить отправку этой части") { model.send() }.buttonStyle(PrimaryButton()).disabled(!model.canSend)
                    .accessibilityIdentifier("memory.send")
            }
            Button("Отменить подготовку") { model.cancelAction() }.buttonStyle(GhostButton())
        }
    }
    private func details(_ proof: MemoryProvenance) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Button("К обзору") { model.dismissDetails() }.buttonStyle(GhostButton())
            GSectionHeader("Источники и цепочка зависимостей")
            if model.inspectedState != .current || proof.evidenceState != .current { status("Цепочка требует проверки","Откройте исходные утверждения ниже. Если промежуточный факт больше не подходит, его можно явно отменить или исправить; история останется.") }
            ForEach(proof.events) { e in
                VStack(alignment:.leading,spacing:8) {
                    Text(e.statement.text).font(.system(size:14,weight:.medium)).textSelection(.enabled)
                    dates(e)
                    if model.retiredEvents.contains(e.id) { Text("Это утверждение было заменено или отменено. Производный контекст, который использует его, требует пересмотра.").font(.system(size:12)).foregroundStyle(p.danger) }
                    Text("Проект: \(model.projects.first { $0.id == e.projectID }?.name ?? "Недоступен")").font(.system(size:12))
                    if e.projectID == model.projectID && e.action != .retraction {
                        VStack(alignment:.leading,spacing:8) {
                            Button("Исправить утверждение") { edit(e,false) }.buttonStyle(GhostButton())
                            Button("Отменить утверждение") { edit(e,true) }.buttonStyle(GhostButton())
                        }.disabled(model.busy)
                    }
                    Divider()
                }
            }
            if !model.relatedEvents.isEmpty {
                GSectionHeader("Связанные изменения и противоречия")
                ForEach(model.relatedEvents) { related in
                    Button { model.inspectRelated(related) } label: { Label(related.statement.text,systemImage:"arrow.up.right") }
                        .buttonStyle(.plain).foregroundStyle(p.link).multilineTextAlignment(.leading).disabled(model.busy)
                }
            }
            if model.linksLimited { Text("Показано до 32 связанных событий. Остальные доступны в постраничной истории соответствующего проекта.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72)) }
            ForEach(Array(proof.sources.enumerated()),id:\.offset) { _,ref in
                VStack(alignment:.leading,spacing:5) {
                    Button { model.open(ref) } label: { Label(ref.title + " · " + KnowledgeSearchLocation.label(ref.chunk),systemImage:"arrow.up.right") }.buttonStyle(.plain).foregroundStyle(p.link).disabled(model.busy)
                        .accessibilityIdentifier("memory.source.\(ref.chunk.id)")
                    Text(ref.sourceDate.map { "Дата источника: " + day($0) } ?? "Дата источника неизвестна").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
                    if let doc = ref.document { Text("Импорт: \(importDay(doc.importedAt)) — не дата решения").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72)) }
                }
            }
        }
    }
    private func edit(_ event: MemoryEvent,_ retract: Bool) {
        model.dismissDetails(); editing = event; retracting = retract; text = retract ? "" : event.statement.text
        earliest = event.statement.deadline?.earliest ?? todayCivilDay; latest = event.statement.deadline?.latest ?? todayCivilDay
        hasDecisionDate = event.decisionDate != nil; decisionDate = event.decisionDate ?? todayCivilDay
    }
    private func editor(_ event: MemoryEvent) -> some View {
        VStack(alignment:.leading,spacing:14) {
            GSectionHeader(retracting ? "Ручная отмена утверждения" : "Ручное исправление")
            Text("Исходное: " + event.statement.text).font(.system(size:14)).textSelection(.enabled)
            conditions(event.statement)
            Text("Тип, предмет и условия сохранятся. Изменение останется в истории и не будет автоматически заменено моделью.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
            TextField(retracting ? "Причина отмены" : "Исправленный текст",text:$text,axis:.vertical).lineLimit(3...10).textFieldStyle(.roundedBorder).accessibilityIdentifier("memory.edit.text")
            if event.statement.kind == .deadline && !retracting {
                DatePicker("Срок с",selection:$earliest,displayedComponents:.date).environment(\.timeZone,TimeZone(secondsFromGMT:0)!)
                DatePicker("Срок по",selection:$latest,displayedComponents:.date).environment(\.timeZone,TimeZone(secondsFromGMT:0)!)
                if earliest > latest { Text("Конец периода должен быть не раньше начала.").foregroundStyle(p.danger) }
            }
            if !retracting {
                Toggle("Дата решения известна",isOn:$hasDecisionDate)
                if hasDecisionDate { DatePicker("Дата решения",selection:$decisionDate,displayedComponents:.date).environment(\.timeZone,TimeZone(secondsFromGMT:0)!) }
            }
            Button("Проверить и показать изменение") {
                model.prepareCorrection(event,text:text,retract:retracting,earliest:earliest,latest:latest,decision:hasDecisionDate && !retracting ? decisionDate : nil)
            }.buttonStyle(PrimaryButton()).disabled(model.busy || text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || (!retracting && event.statement.kind == .deadline && earliest > latest))
                .accessibilityIdentifier("memory.edit.prepare")
            Button("Закрыть редактор") { editing = nil; model.cancelAction() }.buttonStyle(GhostButton())
        }
    }
    private func correctionPreview(_ preview: MemoryCorrectionPreview) -> some View {
        VStack(alignment:.leading,spacing:14) {
            GSectionHeader("Проверенное изменение · только на этом Mac")
            Text("Было: " + preview.event.statement.text).font(.system(size:14))
            Text((preview.draft.action == .retraction ? "Отмена: " : "Станет: ") + preview.draft.statement.text).font(.system(size:14,weight:.semibold)).textSelection(.enabled)
            conditions(preview.draft.statement)
            if let range = preview.draft.statement.deadline { Text("Срок: \(day(range.earliest)) — \(day(range.latest))") }
            Text(preview.draft.decisionDate.map { "Дата решения: " + day($0) } ?? "Дата решения неизвестна")
            Text("Сохраняем исходное событие, происхождение и все \(preview.lease.sources.count) опорных фрагментов. Перед записью повторно проверим файлы и версию памяти. Это действие не закрывает внешние задачи.").font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
            ForEach(Array(preview.lease.sources.enumerated()),id:\.offset) { _,ref in Text(ref.title + " · " + KnowledgeSearchLocation.label(ref.chunk)).font(.system(size:12)) }
            Button(preview.draft.action == .retraction ? "Подтвердить ручную отмену" : "Сохранить ручное исправление") { editing = nil; model.publishCorrection() }.buttonStyle(PrimaryButton()).disabled(model.busy).accessibilityIdentifier("memory.edit.commit")
            Button("Отменить изменение") { editing = nil; model.cancelAction() }.buttonStyle(GhostButton())
        }
    }
    @ViewBuilder private func conditions(_ statement: MemoryStatement) -> some View {
        if !statement.conditions.isEmpty {
            Text("Условия: " + statement.conditions.sorted { $0.key < $1.key }.map { $0.key + ": " + $0.value }.joined(separator:"; "))
                .font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
        }
    }
    private func dates(_ event: MemoryEvent) -> some View {
        VStack(alignment:.leading,spacing:3) {
            Text(event.decisionDate.map { "Дата решения: " + day($0) } ?? "Дата решения неизвестна")
            Text("\(event.origin == .manual ? "Ручная запись" : "Извлечено моделью"): \(event.extractedAt.formatted(Date.FormatStyle(date:.abbreviated,time:.shortened).locale(Locale(identifier:"ru_RU")))) — не дата источника")
        }.font(.system(size:12)).foregroundStyle(p.ink.opacity(0.72))
    }
    private func day(_ value: Date) -> String { value.formatted(Date.FormatStyle(date:.abbreviated,time:.omitted,locale:Locale(identifier:"ru_RU"),timeZone:TimeZone(secondsFromGMT:0)!)) }
    private func importDay(_ value: Date) -> String { value.formatted(Date.FormatStyle(date:.abbreviated,time:.omitted).locale(Locale(identifier:"ru_RU"))) }
    private var todayCivilDay: Date {
        let local = Calendar(identifier:.gregorian).dateComponents([.year,.month,.day],from:Date())
        var utc = Calendar(identifier:.gregorian); utc.timeZone = TimeZone(secondsFromGMT:0)!
        return utc.date(from:local) ?? utc.startOfDay(for:Date())
    }
    private func status(_ title: String,_ detail: String) -> some View {
        VStack(alignment:.leading,spacing:6) { Text(title).font(.system(size:15,weight:.semibold)); Text(detail).font(.system(size:13)).foregroundStyle(p.ink.opacity(0.72)) }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func sourceTitle(_ source: EmbeddingSourceKey) -> String { model.sourceTitles[source] ?? model.heads.flatMap { $0.entry.event.sources }.first { $0.key == source }?.title ?? (source.kind == .meeting ? "Встреча \(source.externalID)" : "Документ \(source.externalID.prefix(8))") }
    private func openPolicies(_ job: MemoryQueueJob? = nil) {
        let raw = job.map { model.sourceOwners[$0.source] ?? [] } ?? Set(model.sourceOwners.values.flatMap { $0 })
        owners = model.request?.ownerProjectIDs ?? Set(model.heads.flatMap { $0.entry.event.ownerProjectIDs }).union(raw).union(model.projectID.map { [$0] } ?? [])
        model.cancelAction(); policies = true
    }
    private func owners(_ ids: Set<UUID>,in request: MemoryUpdateRequest) -> String { request.checkpoint.projects.filter { ids.contains($0.id) }.map { $0.name + " — " + $0.cloudPolicy.questionLabel }.joined(separator:"; ") }
}

extension MemoryFactKind {
    static var panelKinds: [Self] { [.decision,.agreement,.deadline,.openQuestion,.completionClaim] }
    var panelTitle: String { switch self { case .decision:"Решения"; case .agreement:"Договорённости"; case .deadline:"Сроки и изменения"; case .openQuestion:"Открытые вопросы"; case .completionClaim:"Заявления о выполнении" } }
}
extension MemoryQueueState {
    var panelTitle: String {
        switch self {
        case .queued:"В очереди"; case .running:"Обрабатывается"; case .partial:"Частично обработан"; case .backpressured:"Ждёт свободного места"
        case .waiting:"Ждёт источник или индекс"; case .denied:"Облако запрещено владельцем"; case .needsConsent:"Нужно разовое согласие"
        case .completed:"Все фрагменты обработаны"; case .insufficient:"Недостаточно оснований"; case .failed:"Ошибка обработки"
        case .limited:"Достигнут безопасный лимит"; case .cancelled:"Отменено"; case .stale:"Устаревший контекст"
        }
    }
}
