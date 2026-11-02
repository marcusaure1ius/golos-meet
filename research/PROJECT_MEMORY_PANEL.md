# Панель памяти проекта · #37

Результат подготовлен для независимого ревью в `codex/product-preview`. Это часть #37 и этапа #5, не завершение всего этапа. Интерактивный проход автора заблокирован экраном блокировки Mac. После включения принятого PR #57 последний полный `make check` остаётся красным: timeout ожидания synthetic metadata worker; OCR и все тесты панели прошли. Прежние OCR-отказы сохранены, их конкретная причина не объявляется установленной.

## Основа и включение в приложение

Рабочая ветка `codex/37-project-memory-panel` создана в отдельном управляемом worktree от принятого preview `24b75f63bad8429aec00331c4968d6963a09bc09`. Перед реализацией проверены merge/ancestry и наличие результатов PR #48, #49, #50, #52, #54 в preview. Для #54 проверенный SHA `81efc1a4bacc769ff1edf4aeac7008d10010c335`, дерево merge preview совпадало с проверенным деревом. Исходная ветка очереди не изменена.

2 ноября включён принятый OCR PR #57: checked `bc28cf7ff9f458e9f01219b8d27c38ce7750e660`, merged preview `885b41e10d3caaed42d91d935776fc79e2b5044e`. Fresh GitHub API подтвердил merged/head/merge SHA; после fetch проверены ancestry и пустой полный tree diff checked57→preview. Обычный merge `9b29e7fb500624b3b3f78476533ab733d1525093` имеет родителей `ee48e1d…` и `885b41e…`, без конфликтов и переписывания истории. Фактический код панели, её worker guards и тесты не изменились. Старые артефакты сверены по хэшам и оставлены побайтово прежними. Непринятый #58 не включён. [Integration receipt](memory-panel-37/after57/integration-receipt.json).

В проекте доступна кнопка «Память». В деталях встречи кнопка «Контекст проекта» открывает inspector рядом с текущей встречей; его ширина 380–600 pt. Существующая запись, очередь ASR и плеер остаются владельцами своих lifecycle. Переход к источнику памяти не вызывает player/seek/play.

`ProjectMemoryEntry` создаёт модель один раз и управляет `start/close`. `ProductionMemoryPanel` использует принятый `ProductionMemoryQueue.shared.worker`, `ProjectLibrary.shared.store`, реальные roots и настройки модели. Нового клиента/ключа нет. Проверка `AppRuntime.isTestHost` стоит до обращения к production singletons, settings и путям. TestHostIsolationTests проверяет nil factory. Реальные маршруты MeetingDetail/MeetingsScreen входят в сборку полного приложения; интерактивно эти маршруты пока не проверены.

## Поведение и актуальность

- Обзор группирует решения, договорённости, сроки, открытые вопросы и заявления о выполнении. Конфликт, ручная отмена, неполнота и неподтверждённый источник видны явно. Заявление о выполнении не считается проверенным статусом внешней задачи.
- Разделены дата решения, дата источника, импорт и момент модельной/ручной записи. Неизвестная дата остаётся неизвестной. Deadline/decision DatePicker редактируют гражданский день в UTC, как ISO-дни принятого extractor; часы импорта/извлечения не подставляются. Отдельный тест проверяет нормализацию входа с ненулевым временем в полночь UTC.
- Обзор показывает до 50 head-позиций и предупреждает об ограничении. История доступна страницами по 50 с курсором назад и переходом к новым событиям; фильтр локален к показанной странице. Очередь ограничена 256 строками выбранного проекта, SQL-фильтр проекта применяется до LIMIT. Overflow не называется полной обработкой архива.
- UI чтение не резервирует generation/lease. Read-only metadata stamp консервативен для всех проектов; изменение другого проекта может сбросить локальный preview, но не перезапускает глобально задания. Подписка на события и polling раз в 2 секунды проверяют SQLite metadata и identity файлов, пока панель открыта.
- Ancestry проверяется read-only по принятому правилу retirement, с максимумом 256 immutable событий. Raw provenance проверяет принятый history service. File identity фиксируется до публикации строк; мутация между чтением и регистрацией watch не поглощается как новый «текущий» baseline.
- Смена проекта/владельца встречи, фильтра, конфигурации, источника или модели сбрасывает подготовленные действия. Generation fence после await не допускает публикации старых деталей в новой области. При закрытии панели отменяется её операция и её согласие; общий worker продолжает работу.

## Просмотр перед отправкой и ручные изменения

Подготовка показывает все выбранные сырые фрагменты и выбранные события производной памяти: полный текст, условия, сроки, локации, владельцев и политики, полное исходное происхождение, количество символов/UTF-8 байт и точный JSON. Тексты скрытых raw-предков не добавляются к выбранному payload; все их владельцы всё равно участвуют в проверке. Получатель и модель указаны в UI.

Только отдельная кнопка «Разрешить отправку этой части» вызывает принятую выдачу single-use consent и approve worker. Следующая часть требует нового preview/согласия. `localOnly` любого первоначального или текущего владельца блокирует передачу, разовое согласие его не отменяет. Контекст не ставится автоматически на отправку после ожидания другой операции. Тесты проверяют payload equality, отсутствие запроса до согласия, повторное нажатие, отзыв разрешения и владельцев производной памяти. В тестах транспорт синтетический.

Ручное исправление/отмена проходит accepted `beginCorrection → local preview → publish` с неизменяемым полным происхождением и финальным CAS/files check. Тип, предмет и условия сохраняются; ручной приоритет и исходная история остаются. Отмена требует причины и создаёт явное событие, а не удаляет предка. Ручная операция локальна, не выдаёт облачное разрешение и не закрывает внешние задачи. Событие отмены не имеет кнопки неявного восстановления.

В деталях доступны полная цепочка, отметки заменённых предков и переходы к связанным изменениям/конфликтам (до 32 с явным предупреждением; остальные в истории проекта). События другого проекта просматриваются локально без возможности редактирования в чужой области. Открытие exact source reference проверяет canonical source до и после accepted reader; старая версия PDF/документа не открывается как текущая. PDF показывает проверенные bytes и нужную страницу; transcript показывает соответствующую реплику без управления аудио.

### Устаревший промежуточный контекст

Сценарий: A → D → B; внешний retirement A делает D и производный B устаревшими. Обычный retry B это не исправляет. UI показывает цепочку и связанное retiring-событие; пользователь явно исправляет/отменяет D. После локального publish вызывается `worker.changed()`, и принятая очередь восстанавливает B по актуальному raw-контексту. Существующие event/batch bytes не переписываются. В тесте выполнен именно этот путь через модель панели, history, store, worker и fake transport. Автоматической отмены предков нет. Если raw-файл исчез, заменён или его происхождение невозможно подтвердить, accepted correction может отказать; панель не обходится без доказательств.

### Регрессия отмены между двумя панелями

Самопроверка выявила дефект: A отправляет одобренную часть; B отменяет и повторяет тот же source sequence с новой generation; закрытие A по sequence отменяло новый retry B. Сохранён красный before: [scoped-cancel-before.json](memory-panel-37/scoped-cancel-before.json).

Модель теперь хранит request UUID. `cancelApproval(requestID)` привязан к исходным request/service/lease, а durable state меняет с CAS исходного lease. Более новая generation остаётся. `discardPreview(requestID)` не сбрасывает чужой pending preview. После production fix первый повтор прошёл assertion о новой generation, но тест слишком рано читал needsConsent: `waitUntilIdle` не дожидается caller-owned approve. Fixture теперь после release gate ожидает фактическое durable состояние до 8 секунд; production/test timeouts не расширены. Before, intermediate и зелёный after логи сохранены. Финальный 50/64 включает этот сценарий и закрытие одной панели без отмены preview другой.

## Проверки и артефакты

Текущая проверенная комбинация — панель `ee48e1d` плюс принятый OCR57/preview885b41e. Команды, результаты, полные source hashes нового host: [after57/checks.json](memory-panel-37/after57/checks.json).

| Проверка после принятого PR57 | Фактический результат |
|---|---|
| Полный make check + existing publicE5/settings/menu/panel renders/traces | **Failed: 449 tests / 623 runs; 448 passed / 622 passed runs, 1 failed, 0 skipped, 0 runtime warnings** |
| Все ProjectMemoryPanelTests и LocalDocumentExtractorTests внутри этого full | Passed, включая actual PDF page2 и real OCR concurrent32 |
| Новый safehost build | Passed, build-only, не запускался |
| Свежие native renders / migration traces | 44 PNG + 4 manifest / 9 JSONL |
| Exact OCR input/output/error attachments | 82 файла / 41 invocation: 40 returned + 1 expected invalidDocument; все input SHA/bytes проверены |
| Actual interactive | Не выполнялся; ожидается сообщение пользователя об unlock |

Первый preflight запуск остановился до тестов: sandbox запретил запись SwiftPM/Clang cache, exit74. Исходный лог сохранён. Повтор с необходимыми tool permissions запустил full; это устранение ограничения окружения, не зелёный rerun тестов.

Новый отказ — `ProjectMemoryQueueTests.concreteMetadataBridgeReceivesReadyEventWithoutLaunchingApplication()`: `until` с дедлайном5s записал `Timed out waiting for synthetic worker state`, затем пойман `.busy`; тест завершился через10.297s. Он вызывает helper дважды (revision>0 до добавления источника и completeCoverage после ready event); в существующем failure evidence нет различения, какое ожидание истекло. Нельзя по длительности доказать причину или конкретный момент состояния. Сохранены [summary](memory-panel-37/after57/full-summary.json), [activities](memory-panel-37/after57/failure-activities.json), exact stdout/runner logs. Timeout/production logic не менялись, full ради случайного зелёного результата не повторялся. Нужен отдельный диагноз через координатора; связь timeout с lifecycle #58 пока не установлена. OCR57 не объявляется его объяснением.

RuntimeWarnings пуст, но stdout содержит33 строки SQLite failure и181 unlink-warning для test temp DB, а также6 e5rt diagnostic lines при успешных OCR assertions. Их counts/полный stdout и excerpt сохранены; это не «чистый stdout». Lifecycle #58 остаётся отдельно; новые строки не приписываются исходным историческим эпизодам задним числом. System logarchive не публикуется.

Новые доказательства — в [after57](memory-panel-37/after57), старые ниже сохранены как история. Свежие derived-context-light/conflicts-claims-dark PNG просмотрены: условия/unknown даты/владельцы/разовое согласие/конфликт/claim caveat видимы. Production inspector interaction по-прежнему не проверен. Новый host содержит принятый executor57; source allowlist/hash и binary hash сохранены. В этом продолжении CUA не вызывался и host не запускался.

### Проверки до принятого PR57

Сырые runner/stdout/native build логи сохранены как gzip без изменения байтов; хэши исходных распакованных логов записаны в checks.json. Машиночитаемые команды, counts, SHA-256 исходников и ссылки на сырые результаты: [checks.json](memory-panel-37/checks.json).

| Проверка | Фактический результат |
|---|---|
| Исторический полный `make check` до PR57, installed E5 + явные opt-in UI renders/traces | **Failed:** 447 тестов / 621 запуск; 446 passed, 1 failed, 0 skipped, 0 runtime warnings |
| Финальные Panel + Queue + EmbeddingMigrationRace | **Passed:** 50 тестов / 64 запуска; 0 failures/skips/runtime warnings |
| Изолированный native preview build, финальные исходники | Passed, build-only, приложение не запускалось |
| Native SwiftUI/AppKit render fixtures | 44 PNG, 4 manifest, светлая/тёмная темы |
| SQLite migration race evidence | 9 raw JSONL trace файлов |
| Интерактивный CUA проход | **Не выполнен:** Mac locked |
| Rust | Не изменён, `make check-rust` не требуется |

Full run использует уже установленные публичные `e5-small` по явному пути `/tmp/golos-embedding-native/e5-small`; веса не скачивались. Native E5 тесты полного набора действительно работают с ними. Panel fixtures и preview host используют синтетические 2D vectors. Fake LLM означает проверку accepted service/queue/model потока с подменённым транспортом, а не живой OpenRouter.

Рендеры получены фактическим `NSHostingView` в изолированном test host. Состояния реализованы через реальный временный ProjectStore/history/worker/service: loading, empty, consent, exact raw/derived context, provenance, PDF page 2, conflicts/claims, manual preview, cancellation, working, partial 12/25, network failure, retry/fresh consent, insufficient, cap, waiting index, denied, stale. Это не автоматические клики и не доказательство interactive routing. При визуальной проверке узкая кнопка контекста обрезалась в раннем рендере; действия перенесены в вертикальную группу. Финальный partial-consent render показывает подписи полностью. Проверены также свежие raw PNG exact/derived context, provenance, manual preview, errors/conflicts/source. Перечень/хэши — manifests в [renders](memory-panel-37/renders).

## Два отказа OCR, не скрытые повтором

Предыдущий full run (`02-30-39`) — 445/446 тестов, 619/620 запусков, один runtime QoS warning. Параметр PNG OCR `"Решение: запуск проекта в ноябре"` выбросил `.e5rtError("e5rt_stream_completion_handler call failed", 10)`; английский PNG прошёл. Это framework error, а не timeout assertion. Сохранены точные summary/activities/runner log. Xcode удалил старый xcresult при retention следующего прогона; summary и activities экспортированы до удаления, полный diagnostics stdout того запуска не успели экспортировать. Нельзя утверждать, что warning исправлен.

Исторический full (`02-39-00`) — mixed PDF, параметры native=`"Page 1"`, scanned=`"Decision: launch postponed to December"`, duplicateNative=`false`. Проверка строки `lines.filter { $0 == scanned }.count == 1` получила 0 в LocalDocumentExtractorTests.swift:144. Остальные четыре параметра прошли. Функция извлечения завершилась, но результат не удовлетворил assertion; это не timeout. Полный OCR output тест не прикрепляет, временный fixture удаляется, поэтому фактическую распознанную строку/байты именно того изображения восстановить нельзя. Вход и способ генерации зафиксированы неизменённым параметризованным тестом (1200×600 raster, font40, PDF600×800).

Из diagnostics экспортирован stdout именно тестового процесса. В нём рядом есть сообщения Vision `CRImageReaderError error 1`, `Unable to find a valid E5` в системном TextRecognition.framework. Это **системный OCR E5**, он не является нашим ONNX embedding `e5-small`. Корреляция по времени не доказывает корневую причину потери строки. Также stdout содержит `vnode unlinked while in use` для временных test SQLite и SQLite failure extended6922; фикстуры удаляют каталог, пока объекты store ещё живут. Эти сообщения не отражены в xcresult runtimeWarnings, не означают «чистый stdout» и требуют отдельной диагностики жизненного цикла fixture. Нельзя по этому логу приписать их конкретной новой панели или игнорировать риск. Они сохранены в полном stdout и diagnostic excerpt. Панельный cleanup перед удалением останавливает свой worker, но явного close API store здесь не добавлено.

Файлы extractor и его тестов в diff отсутствуют. Это не доказательство безвредности отказа. В эту задачу не внесены случайные OCR/retry/timeout исправления. Отдельная диагностика #56 привела к принятому PR57 (executor isolation и exact OCR input/output/error attachments). Доказан executor defect; причины именно старых e5rt10/mixedPDFcount0 не объявлены установленными. Новый timeout full после57 требует отдельной диагностики, #58 ещё не принят. Полный набор не перезапускался до случайного зелёного результата. Более ранний full 441/615 был зелёным с QoS warning; он не покрывает финальные изменения.

## Интерактивная проверка и передача

CUA дважды вернул ровно:

> The Mac is locked and automatic unlock could not unlock it. Ask the user to unlock the Mac manually before continuing.

Требуется ручная разблокировка пользователем. Запрос уже показан в чате. Отказ не обходился; app не запускался вслепую, GUI-вызовы не повторялись бессрочно. [cua-blocked.json](memory-panel-37/checks/cua-blocked.json) не содержит inventory браузеров или пользовательских окон.

Изолированный host собран: его путь/bundle/temp root сохранены в checks.json. Он использует source allowlist, свежие SQLite/temp root и bundle, actual panel/model/worker/service, синтетические meeting/PDF, fake client с локальным payload trace, gate задержки и режимами ошибки/недостатка данных. В source list нет OpenRouterClient, Keychain, production app/coordinator, recorder или ASR. Слева синтетическая текущая встреча, справа actual panel; actual MeetingDetail inspector host не поднимает, его production wiring отдельно собрано полным приложением.

После unlock нужно реально пройти: переключение проекта рядом со встречей; history/filter/pagination; source jump/pdfpage2 без audio playback; raw/derived all-owner preview и разовый send; отмена/ошибка/retry/новое согласие; ручной local preview/commit; stale intermediate recovery; изменение проекта/источника во время задержанного fake send; светлая/тёмная темы и narrow inspector. Записать AX/скриншоты и сверить durable history/fake calls. Затем независимый reviewer проверяет конкретный SHA. Самопроверка автора этого не заменяет.

Ограничения: polling2s и FS/SQLite неатомарны; на очень большом архиве стоимость read-only обхода metadata/ancestry не измерена. Bounded страницы/heads/links видимы честно; полный экран архива не заявляется. Облачные вызовы, Keychain, пользовательские документы/аудио, запись/ASR в этой проверке не использовались. Constance и календарная интеграция не запускались. `main` и draft PR #8 не изменялись. #37/#5 остаются открытыми; слияние автор не выполняет.
