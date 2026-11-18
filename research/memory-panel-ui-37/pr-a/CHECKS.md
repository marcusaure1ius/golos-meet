# #37 · PR-A · Панель чтения памяти проекта — проверки

Дата: 13 ноября 2026. Ветка `codex/37-project-memory-panel-ui`, база `codex/product-preview` `22011074c2e6ae3a48e4d774a00196751c0bc103`.

## Объём

UI-слой чтения панели контекста проекта (первая из трёх частей #37):

- `Core/Knowledge/MemoryPanelReadStore.swift` — read-only ограждения: `memoryPanelStamp()` (fence снапшота панели), `validateMemoryPanelSource`, `memoryPanelAncestryState` (правило retirement предков без lease/генерации).
- `UI/Projects/ProjectMemoryPanelModel.swift` — модель чтения: выбор проекта (с ограничением встречи и автопределением единственного проекта), обзор (heads с ancestry-статусом), постраничная история (50/стр), фильтр, провенанс (события+связанные+retired), открытие проверенного источника (двойная валидация), stale/unconfirmed-маркировка при изменении источников, read-only очередь проекта (клиентский фильтр снапшота worker), конфигурация `llmEnabled`/`generationModel` (#86).
- `UI/Projects/ProjectMemoryPanel.swift` — разделы Обзор/История/Очередь, честные состояния: загрузка, пусто, ошибка, stale, «не все материалы обработаны», «обзор ограничен», конфликты, completion claim без закрытия задач, unknown-даты.
- `UI/Projects/ProjectMemoryEntry.swift`, `ProductionMemoryPanel.swift`, `ProjectMemoryNavigation.swift` — вход, guarded production-фабрика (test host → nil), кнопка/inspector-маршрут.
- Точки входа: кнопка «Память» в проекте (MeetingsScreen, inline route) и «Контекст проекта» в деталях встречи (MeetingDetailView, inspector 380–600pt).
- Тесты `ProjectMemoryPanelTests` (6) + изоляция test host (`ProductionMemoryPanel.makeModel() == nil`).

Согласие/отправка, ручные исправления/отмена и действия очереди — следующие части (#37 не закрывается).

## Проверки

- `make check` (финальное дерево): **Passed — 493 passed / 0 failed / 7 skipped / 4 expected / 0 runtime warnings**. xcresult: `.build/xcode/Logs/Test/Test-golos-meet-2026.11.13_20-5*.xcresult` (в worktree).
- Render реального UI (env-gated `GOLOS_MEET_RENDER_MEMORY_PANEL`, synthetic/fake transport, temp SQLite): 7 состояний × light/dark = 14 PNG + `render-manifest.json` (sha256) в этой папке: loading, overview, queue, provenance, checked-source, history, empty. Проверены визуально: дизайн-язык golos, честные unknown-даты, тёмная тема.
- Транспорт: во всех чтениях панель не делает сетевых вызовов (spy.calls == baseline).

## Ограничения

- Очередь в панели read-only (клиентский фильтр полного снапшота; store-фильтр по проекту придёт с действиями очереди).
- Живой интерактив пользователя — общая ручная QA в изолированной копии (#67), не в этом PR.
- Старый draft PR #55 использован только как справочник решений; код написан заново на базе `2201107` (адаптация под `UISettings.generationModel` из #86).
