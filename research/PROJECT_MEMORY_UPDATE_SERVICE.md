# Guarded извлечение и обновление памяти — первая часть #37

База — preview `75b17ace1d44b712bca9dbb7ffa51fc1eb45311d`, принятый PR #50
checked `c9ba025ec72b8dc6a23254d3cd6526145308e8a4` и ранее принятый PR #49
checked `23a9bd2b298514b4e55acccdd0d1b4f332c4f3ee`. Перед новой веткой
`codex/37-project-memory-worker` выполнены fresh fetch, merged metadata,
ancestry и пустой diff checked50 → preview. Managed worktree:
`/Users/alfa/.codex/worktrees/project-memory-worker/golos-meet`.

Это первый небольшой service PR внутри #37: явно выбранные готовые фрагменты,
контекст/разовое согласие, guarded ChatCompleter, проверенный структурированный
вывод и запись в принятый журнал. **Durable queue, incremental worker, production
hooks и панель ещё не реализованы**. Они идут отдельными PR от принятой основы;
#37 и родитель #5 этим результатом не закрываются. UI/CUA не запускались.
Схема SQLite остаётся v7, миграции не меняются.

## Контракт и потреблённый контекст

`ProjectMemoryUpdateService` получает только явно переданные store/roots,
ChatCompleter/model и clock. Не имеет shared instance, production defaults,
Keychain, settings, capture/ASR или автоматического запуска. Все сетевые действия
возможны только при явном вызове `update`; `prepare` выполняет локальные проверки.

`prepare(projectID:hits:parentEventIDs:)` принимает до 12 уникальных локальных
retrieval hits выбранного проекта и до 8 явно выбранных корневых событий памяти.
Можно выбрать только производный контекст без новых hits. Используются принятые
ProjectStore/catalog/SourceReader, без нового индекса или транспорта.
Потреблённые источники всех родителей наследуются по контракту #36; canonical
index snapshot строится только для этих источников, без сканирования архива.
Для каждого нужны текущий epoch/revision, готовый job актуальной модели, точные
chunks, документная версия/hash/path и совпадающий физический file stamp.

В payload идут **только выбранные raw fragments** (S1…) и **только явно выбранные
корневые derived statements** (M1…). Исторические исходные raw тексты не добавляются
в payload скрыто. При этом полная ancestry, все потреблённые source refs и все
первоначальные/промежуточные владельцы сохраняются для локальной проверки и журнала.
`MemoryUpdateRequest` содержит точный payload, выбранные fragments/parents,
полный consumedSources и checkpoint всех политик для будущего preview UI.
Подмена полей чужим request не используется: approve/update берут canonical
pending request сервиса по ID.

Явные пределы: 12 hits, 8 родителей, 16 000 символов текста/названий raw fragments,
24 000 символов и 64 000 UTF-8 байтов всего JSON payload, до 128 владельцев.
Действуют прежние journal limits 128 sources/128 000 символов источников,
256 ancestry events; выборка ревизий/источников ограничена этой цепочкой.
Reply не более 128 000 UTF-8 байтов, 16 фактов, 20 evidence и 8 links на факт.
Превышение отклоняется, не обрезает результат до уверенного подмножества.

## Разрешения, версии и отмена

LocalOnly любого владельца даёт denied и ноль transport calls. AskEveryTime
требует токен явного approve точного request/сервиса; токен не меняет политику,
потребляется до await и не переживает ошибку, новый prepare, cancel или restart.
Для retry нужен новый prepare и новое согласие. AllowSelectedContext допускает
только данный bounded выбранный контекст, а не весь архив.

Перед **каждой попыткой сети**, а также после ответа:

1. Проверяются файлы/hash/chunks через существующий SourceReader; ранние file
   identities повторно сверяются после последующих await.
2. Одна SQLite-транзакция сверяет canonical index hits/model/job identity,
   lease CAS/revision, assignment epoch, все политики/владельцев и поколения
   всех проектов **полной родительской цепочки**.
3. Проверяются session ID и Task cancellation.

Используется тот же `ChatCompleter.complete(...beforeSending:)`, что в #35;
повторяющий транспорт обязан выполнять gate на каждой попытке. Конкретный
OpenRouterClient не дублируется и не меняется.

Корневые derived события должны быть выбранными, положительными, подтверждёнными
и без текущего конфликта. Внутри ancestry допускается событие, явно заменённое
другим событием той же потреблённой цепочки: ручная правка сохраняет исходный
модельный факт. Замена предка **вне цепочки** делает производный контекст stale.
Поздняя ручная правка другого проекта проверяется по всей цепочке, а не только
по ближайшему родителю. Старый, отменённый или конфликтный корень не отправляется
как текущий обзор. История такого корня по-прежнему доступна через #36.

После повторной проверки файлов `history.publish(...updateGuard:)` дополнительно
проверяет model/job/parent-memory checkpoint в **той же транзакции**, что и
lease/CAS + append событий/links/heads/batch. Опциональный guard не меняет прежних
локальных/manual callers #36. Все факты публикуются одной транзакцией, без partial
publish. FS, SQLite и удалённый сервер не атомарны; мутации после последнего
локального cutoff не отзывают отправленные bytes. Чтение журнала заново проверяет
доказательства по принятому контракту #36.

Сервис владеет Task операции. Session cancel отменяет его, а не только скрывает
ответ; отмена caller также передаётся в этот Task. Даже noncooperative provider
после release не может дописать старый результат: действуют session fence,
Task cancellation и финальный SQLite cancellation check. Уже совершённый до
cancel COMMIT не отменяется задним числом.

Состояния сервиса: idle/preparing/waiting/denied/needsConsent/ready/running/updated/
insufficientEvidence/cancelled/stale/limited/failed. Они не выдаются за persistent
очередь: queued и восстановление незавершённой работы относятся к следующему PR.

## Структурированный вывод и журнал

`MemoryFactExtractor` даёт JSON schema и проверяет фактический JSON локально:
точный набор ключей, enum, обязательные поля, ограничения, существующие метки и
непустые **дословные** quote из выбранного S/M текста. Unknown keys, выдуманные
цитаты/links, неполный JSON и invalid второй факт отклоняют весь результат.
Links могут ссылаться только на выбранные M labels; model не может отменить
manual event. Окончательные subject/conditions/range/slot/links ограничения
повторно проверяет сам журнал.

Источник — данные в JSON user payload, не новая system/tool-инструкция.
Instructions запрещают выполнять команды из fragments/memories и добавлять
знания извне. Структурная проверка и fake transport не доказывают устойчивость
реального LLM к prompt injection или истинность его вывода.

Срок и decisionDate принимаются только как валидные YYYY-MM-DD с явно указанным
годом, дословно присутствующие в evidence quote. Это намеренно консервативно:
«26 ноября» без года не превращается в выдуманную полную дату; остаётся текстовой
договорённостью/вопросом. Дата импорта не отправляется как основание даты решения.
SourceDate неизвестна и остаётся nil; extractor не может записать выдуманный
sourceDate отдельным полем. ExtractedAt задаёт injected clock локально.

События — assertion/retraction и decision/agreement/deadline/openQuestion/
completionClaim. «Сделал» сохраняется заявлением источника, без закрытия внешних
задач. Реальное сравнение структурированных диапазонов и условий выполняет #36:
несовместимые сроки сохраняются как конфликтующие события. Subject/conditions
всё ещё являются выводом extractor; сервис не доказывает их семантическое
тождество между встречами. Полная ancestry сохраняется независимо от того,
какое подмножество evidence labels назвал ответ.

InsufficientEvidence=true допускает только facts=[]; результат имеет явное
состояние, ничего не публикуется. Empty facts с false — ошибка. Для empty/
insufficient результата journal batch не создаётся; его durable disposition
должна хранить следующая очередь, автоматического retry здесь нет.

Идемпотентность разделяет полное provenance и фактически выбранный вход генерации.
Legacy journal fingerprint полного closure/parents сохраняется, а producer key
сервиса — `memory-update-input-v2:` + SHA256 канонического JSON: extractor version,
модель генерации, фактические system/user messages, полный responseFormat/schema,
упорядоченные S-label → source/revision/chunk bindings и M-label → parent event IDs.
Текст/название/location/метки и порядок выбранных fragments/derived statements
находятся в фактическом user payload; для сообщений используется одна функция
как при вычислении ключа, так и при вызове ChatCompleter. Одного payload недостаточно:
у разных sources могут совпасть title/text/location, но S1 должен вести к другому
chunk. Source epoch/file identity и полный inherited ownership остаются в прежнем
journal fingerprint и актуальных guards, не заменяются новым ключом.

После restart такой же проверенный вход возвращает прежние IDs без нового облачного
вызова; fresh consent по-прежнему обязателен для askEveryTime. Changed selection
при том же full closure — другой batch. Другой generator model/version/messages/
schema также меняет identity. В stable key нет request/session/consent UUID, времени
prepare, CAS-generation или credential; durable parent/source IDs — это привязка
к доказательствам, не эфемерная сессия. Смена index job/model сама по себе проверяется
актуальными guards, но не требует нового извлечения при том же exact selected input.
Изменённый parent/context не пропускается под старым согласием.
Отдельная очередь должна учитывать завершённые source revisions и не планировать
обновление заново лишь из-за собственной публикации в журнал.

Cap 256 не повышается. После overflow журнал целиком откатывает публикацию;
сервис возвращает candidateLimit/limited с объяснением: явная ручная отмена либо
замена нескольких утверждений одним, сохранение истории, бессмысленность retry
без изменения набора. Автоматического удаления/выбора побеждающего факта нет.
Для ручного восстановления уже есть API #36; кнопки будут в будущей панели.

## Проверки и границы

`ProjectMemoryUpdateTests` выполняет реальный service → local retrieval/tempSQLite/
SourceReader → guarded fake transport → decoder → journal/read/provenance.
Готовность индекса создаётся настоящими claim/publish валидных синтетических 2D
векторов. Это проверка storage/контракта, **не native embedding inference** и не
живая генерация. Общий full отдельно включает принятые native E5-тесты с уже
установленной публичной моделью; веса не скачиваются.

Проверяются: две встречи/точная реплика/даты/конфликт/completionClaim; raw и derived
all-owner denied; bounded selected payload без скрытого raw предка; одноразовое
согласие/retry/restart/idempotent replay; policy/owners/model ABA, source deletion/
revision/file ABA/recreate/reindex/project recreate/manual edit/cancel перед
транспортом; отзыв между попытками; foreign/deep parent manual edit после await;
noncooperative reply; invalid JSON/fields/quotes/dates/refs/links/partial output;
not-ready/insufficient/budget/cap; replacement/retraction/manual precedence;
финальный атомарный guard model и чужой parent-memory после ранней проверки.

Финальный `make check`: **398 тестов / 557 запусков / 0 ошибок / 0 пропусков /
0 runtime warnings**. Финальный targeted: **12 / 33 / 0 / 0 / 0**. Первый full:
398 / 557, одна ошибка migration-race и один QoS warning LocalDocumentExtractorTests;
сохранён отдельно и не скрывается успешным повтором. Native preview build — Passed,
launch — нет.

Итоговые команды/counts/warnings, исходный failed full и отдельные trace-папки —
`memory-update-service-37/checks.json`. `make check` использует installed E5,
settings/menu preview и GOLOS_MEET_MIGRATION_TRACE_DIR. Rust не менялся.
Native search preview после обновления allowlist только компилируется, не
запускается. Worktree имеет собственный DerivedData.

Первый full сохранил известное наблюдение test-lock COMMIT BUSY, а не новый
подтверждённый дефект сервиса. Scenario F4CA3ED3-4AED-4237-9A41-4DB314F10648,
version=0: acquire0 (0.672 мс), оба SQLite entries 12.878/13.990 мс на разных
connections/executors; release target518.973, фактический start524.724;
COMMIT BUSY=5/extended=5 на524.890, cleanup rollback0 на525.294 и close0 на525.451;
second/first snapshot success613.368/705.202, joined3006.641. Нет entry timeout;
trace не устанавливает владельца мешавшей блокировки. Исходный xcresult сохранён
`/tmp/golos37-first-full.xcresult`, raw log `/tmp/golos37-service-check.log`, raw
JSONL в `memory-update-service-37/first-migration-traces/`. Новый сервис в этом
race не вызывается, SQLite fixture/timeout/retry не изменены. Успешный повтор
не объявляется исправлением этого наблюдения. Независимый reviewer должен
оценить failed trace наряду с delta и итоговыми проверками.

Production app/Keychain/OpenRouter/ASR/capture/пользовательские материалы и живой
звонок не использовались. Панель, production composition/test-host guard,
незавершённая durable очередь/restart и реальные end-to-end проверки ещё впереди.
#37/#5 остаются открыты, общий QA реальных проектов сохраняется; main и draft
PR #8 не меняются. Следующий шаг после независимого принятия этого SHA — отдельный
PR durable incremental worker, затем panel/runtime UI от принятой worker-основы.

## P2 independent review PR52: selected input против full closure

На `7981d450c8cd363051804cf9d52e2119c705674e` reviewer воспроизвёл actual service/
SQLite: M потребил A+B, первый запрос отправил A+M, следующий после restart B+M.
Full closure и родители совпали, но payload был другим. Прежний producer key
учитывал только extractor version/model, journal fingerprint — полный closure;
поэтому B молча получил unchanged IDs A и не вызвал генерацию. Старый SHA не принят.
Оригинальные `/tmp/Review52Driver.swift`, `/tmp/review52-driver.log` и DB
`/tmp/review52-38615DAF-9944-410D-8D57-317BFA8E8A9A/knowledge.sqlite` не изменяются.

Исправление привязывает producer key к exact bounded input только после получения
канонической ancestry и построения payload. Начальный `memory-update-preparing`
lease резервирует поколение; до привязки не выполняются batch lookup/publish.
`bindingUpdateInput` меняет только producerKey копии immutable lease: fingerprint,
полный provenance, поколения/revision/assignment epoch и все guards остаются теми же.
Existing lookup и final publish используют один связанный lease. DDL/схема v7,
legacy journal/manual callers, timeout/retry/fixture не меняются.

Новый namespace v2 намеренно не переиспользует неоднозначные service batches вида
`memory-facts-v1:<model hash>`: по ним нельзя восстановить, какой selected payload
был отправлен. Они остаются неизменяемой локальной историей. Первое допустимое
обновление нового контракта создаёт новый batch после обычного all-owner/consent
gate. Внутри нового exact key сохраняется durable first-wins: даже иной предлагаемый
ответ при том же входе после restart возвращает старые IDs без новой сети. Изменение
decoder-контракта, не отражённое в messages/schema, требует bump extractor version.

Actual service + temporary SQLite регрессии: A+M → B+M; [A,B]+M → [B,A]+M;
одинаковые title/text с разными таймкодами; полностью одинаковый wire payload с
разным S1 → source/chunk. Во всех случаях full closure/parents и journal fingerprint
одинаковы, producer keys/IDs различаются и новый факт действительно публикуется.
Затем exact B replay после нового store/service/request даёт 0 дополнительных
вызовов; смена extraction model при том же payload даёт новый batch. Проверены
точные evidence IDs, обе версии фактов, полный provenance и one-time consent.
Отдельный compatibility сценарий сохраняет старый service batch, не считает его
exact replay, создаёт v2 batch и затем переиспользует только этот v2 результат.

Отдельный native probe использует копию действительной reviewer DB с уже сохранённым
unsafe batch. В конце исходного driver index model намеренно заменён: синтетическая
готовность восстанавливается **только в копии**. Original source-файлы читаются
по прежнему пути, чтобы file stamps оставались достоверными; все DB записи идут
в копию. SHA256 original DB до/после проверяется. Probe/log и новые checks находятся
в `memory-update-service-37/input-key-fix/` и `input-key-fix-checks.json`.

Повторное независимое ревью нового SHA обязательно; очередь/hooks/UI пока не
запускаются. Независимый full предыдущего SHA: 398/557/0 ошибок/0 пропусков,
1 known QoS warning; это не вердикт на исправленный код. Все прежние all-owner,
ancestor-change, privacy/cancel и final atomic guard сценарии входят в новый прогон.

Финальный fix full `make check` с installed E5/settings/menu/traces:
**400 тестов / 562 запуска / 0 ошибок / 0 пропусков / 0 runtime warnings**.
Targeted: **14 / 38 / 0 / 0 / 0**. Все 7 migration traces сохранены, параметры
SQLite/fixture/retry прежние. Native copy probe: A+M и B+M — 2 вызова, разные
публикации; exact B после restart — 0 новых вызовов; old legacy row сохранён.
Original reviewer DB SHA256 до/после:
`78b3996d68e07eb184e8d4f233f8d0d3619668733952814ed1590704d95e1ee2`.
Первый targeted обнаружил ошибку fixture равных payloads: fallback titles были
«Встреча a»/«Встреча b». Метаданные обоих источников сделаны действительно равными;
production fix для этого не менялся. Прежние failed full/race артефакты PR52 и
независимый QoS warning сохранены, новый успешный прогон их не отменяет.
