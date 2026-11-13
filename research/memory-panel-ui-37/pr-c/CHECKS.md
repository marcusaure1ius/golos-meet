# #37 · PR-C · Разовое согласие, действия очереди, удержание при смене проекта — проверки

Дата: 13 ноября 2026. Ветка `codex/37-panel-consent`, база `codex/product-preview` `eb412d0296053260e4794b8a25d1d16b0817e6cc` (принятые части A и B).

## Объём

Завершающая часть UI #37:

- **Разовое согласие:** «Просмотреть контекст» (`worker.preparePreview`, job переходит в durable `needsConsent`) → показ **полного raw+derived контекста точной части** (фрагменты с владельцами/политиками, события памяти с владельцами производного контекста, consumed sources, точный JSON, размер) → «Разрешить отправку этой части» (`approvePreview`) / «Отменить подготовку». Single-use обеспечен принятым worker (токен не пишется в SQLite, preview максимум один); каждый новый batch/изменённый контекст/перезапуск требуют нового согласия; для denied-запроса кнопка отправки не показывается.
- **Действия очереди:** повторить (failed/limited/cancelled/waiting), отменить (queued/running/partial/backpressured/needsConsent/waiting), denied → «Разрешения владельцев» (открывает принятый `ProjectCloudSettings`).
- **Удержание/отмена при смене проекта:** смена проекта/настройки/назначения отменяет подготовку и отправку; узкие дополнения из рецензированного справочника закрытого #55: `ProjectMemoryQueueWorker.hasPreview/canApprovePreview/cancelApproval` (CAS по attempt, старый sender не отменяет newer retry того же источника), per-request `discardPreview(requestID)`, `MemoryQueueStore.memoryQueueSnapshot(projectID:)`.
- **P3 из свода двух ревью:** формулировка очереди (cap 256 глобальный, показан проект); watcher-guard на `loading` (не перезаписывает свежий reload); подсказка кнопки «Разрешения» (локальная запись политики, память/источники не меняет); store-уровень запрет retraction-на-retraction (`publishMemory`: `.retracts` на событие с `action == .retraction` → `invalid`); сохранение подготовленного черновика при фоновом stale (`changedIfNeeded` не сбрасывает request/correction молча — помечает stale с явным notice, CAS проверит при применении).

## Проверки

- `make check` (финальное дерево): **Passed — 505 passed / 0 failed / 7 skipped / 4 expected / 0 runtime warnings**.
- Новые тесты панели (8): exact consent через реальную очередь (payload == request.payload, повторный send без вызова), all-owner denial нельзя обойти + fresh consent после смены политики, фильтр/проект/изменение файла ограждают подготовку без транспорта, late noncooperative send не публикует после смены проекта, старый sender не отменяет newer retry и consent одноразовый, чужая панель не сбрасывает точный preview другой панели, смена назначения/настроек инвалидает consent, очередь: partial 12/25 → failed → retry → insufficient → cancel → waiting → limited (25 fragments → 12/12/1 batching).
- Store-тест: retraction-на-retraction отклоняется (`ProjectMemoryError.invalid`).
- Render реального UI: 34 PNG (17 состояний × light/dark, новые `exact-context`, `partial-consent`, `working`, `network-error`, `insufficient`, `cancelled-job`, `waiting-index`, `limited`) + 2 манифеста (sha256) в этой папке. Проверены визуально.
- **Атрибуция однократного отказа:** первый полный прогон — 1 отказ `QuestionUIFixtureLifecycleTests.heldNoncooperative…(question-ui-late-write-finished)` (3-с ожидание под нагрузкой; в изоляции 3/3 зелёный; база `eb412d0` полным прогоном зелёная 496/0; повтор на этом дереве зелёный). Причина — нагрузко-чувствительный бюджет ожидания, не покрытый фиксом #88. Исправление отдельным test-only коммитом (3с→60с, паттерн #61/#88, семантика ассертов не ослаблена); это не «зелёный перерун вместо диагноза»: зафиксированы base-run, изоляция, повтор и узкая правка бюджета.

## Ограничения

- Живой интерактив пользователя — общая ручная QA в изолированной копии (#67); held-ответ при смене проекта проверен причинно (durable cancel <30s, no publication) в тестах, не через клики.
- Реальные облако/материалы/Keychain не использовались; всё synthetic/fake transport/temp SQLite.
