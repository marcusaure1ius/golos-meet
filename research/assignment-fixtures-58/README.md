# #58: lifecycle `MeetingAssignmentTests.Fixture`

Адресная третья часть #58. База — принятый preview `fc2a92956fd50bd791e4926d5b388c8fe39f84d4` (PR60 checked `ceeb98b5dd1c39dc774c810c82e834ae38fdfc72`). Перед созданием managed worktree выполнен fetch; GitHub подтвердил merge60, ancestry и полный diff checked60→preview пустые. Main `bd6191c7960ae017e8063795f19e2348cdc35bd9` не менялся.

## Причина и actual before/control/after

`Fixture` прямо удерживает `ProjectStore`; его также используют importer, assignment service и indexer. Старый `cleanup()` ждал `indexer.stop()`, затем удалял root, пока fixture ещё находился в теле теста. Остановка worker не освобождает сам store. Reopened stores и прямые native connections — дополнительные, отдельно наблюдаемые ресурсы.

Свежие временные копии **принятого** дерева создаёт [prepare_control.py](prepare_control.py). Только test-side observer использует уже принятый DEBUG callback после настоящих `sqlite3_open_v2`/`sqlite3_close`. Production-файлы в copies не патчатся. События сохраняются на диск сразу, включая close после возврата тела. Instrumentation не сохраняет SQL/тексты источников.

Оба контроля выполнили исходные 13 функций /23 параметризованных запуска, 0 failed/skipped/runtime warnings:

| Наблюдение | Before | Retain-root causal control | Final targeted, только исходные случаи |
|---|---:|---:|---:|
| Каталоги |23|23|23|
| Native opens / успешные close |40/40|40/40|40/40|
| Unlink при живом native handle |23|0 (root ещё сохранён)|0|
| `vnode unlinked` в stdout |22|0|0|
| `extended=6922` |0|0|0|
| Intentional migration `prepare/create`, 1/1 |1|1|1|

Before у каждого root осталось одно живое соединение в момент unlink; indexer-stop уже вернулся. Другие reopened/direct соединения закрывались раньше. В этих трассах нет новых native opens после stop-returned; отдельного deinit-task в этом семействе fixture нет. Причина этой части — преждевременный unlink живого store, без предположения о holder из других семейств или OCR.

Retain-root служит только причинным контролем. После **завершения host** все23 перечисленных каталога действительно удалены; [receipt](results/retain-parent-cleanup.json). Это не предлагаемый cleanup patch. Ошибка6922 в данном before не воспроизвелась: устранение22 vnode diagnostics не выдаётся за воспроизведение/устранение всех исторических SQLite ошибок.

[Scope audit](results/scope-audit.json) содержит mapping case→root→connection UUID→close/unlink. В `*-events.json.gz` лежит map filename→**точный исходный UTF-8 trace**, включая timestamps; SHA каждой записи — в соседнем `*-trace-hashes.json`. [Before receipt](results/before-receipt.json) и [retain receipt](results/retain-receipt.json) содержат все patches и хеш исходника. Полные redacted stdout/build logs также сохранены, никакие строки SQLite из них не вырезались.

## Исправление и native negative controls

- Suite получает принятый `SQLiteFixtureTrait`; root и primary store регистрируются до использования. `reopenedStore()` регистрирует каждый дополнительный lazy store, включая неудачную миграцию. Прямые `ProjectDatabase` и migration helper наследуют scope callback; все40 native handles исходных случаев присутствуют в ledger.
- Fixture cleanup делает stop + waitUntilIdle, без unlink. После возврата тела weak cleanup request останавливает оставшийся indexer. Только затем scope ждёт освобождения слабых store и всех actual close, после чего удаляет root. Production stop/close/schema/timeout не изменены.
- Два новых случая используют **этот же fixture** и реально подвешенный indexer inspector. Тело бросает sentinel либо отменяет собственный child task. Перед release worker root существует, reopened connection уже закрыто, primary ещё открыто. `body-finished → stop-requested → stop-returned → последний native close=0 → unlink`; исходная ошибка тела сохраняется. Cleanup выполняет родительская задача; отмена самого родителя во время teardown отдельно не моделируется.
- Миграционный тест намеренно создаёт конфликт `meeting_decisions_v5`. Исходные assertions на `ProjectStoreError`, user_version=4, sentinel='keep', owners/Inbox/FK сохранены. Его единственный `prepare/create/result1/extended1` разрешается строго внутри asserted async операции.
- Новый test-only `expectingFailureOnNewConnection` наблюдает одно **новое** native connection на точном URL и использует общий single-use matcher. Ноль/несколько opens, ноль/два matching faults, foreign/late/extra faults отвергаются. Все события направляются в ledger без фильтрации. Повторное принятие уже consumed fault запрещено и в nested async случаях.
- Синхронный matcher вынесен в общий private метод без изменения его условий; прежние P2 native controls выполняются вместе с новыми. Ожидаемые negative issues принимаются только из assertion helper в `SQLiteFixtureScope.swift`, confirmation требует ровно одну. SQL/body assertions и ошибки teardown не входят в matcher. Сохранение body error и необработанных native failures проверяется отдельно.

[Source check](results/source-check.json):76 исходных строк `#expect`/`#require` совпадают после нормализации spelling конструктора reopened store; новая проверка наличия scope сравнивается отдельно. Проверен также фактический diff: production/Rust пустой, исходные тела assertions/SQL/таймауты не ослаблены.

## Проверки окончательного diff

[Счётчики](results/checks.json), [stdout audit](results/stdout-audit.json).

Final targeted: **50 функций:46 ordinary passed +4 с expected negative outcomes;105 запусков:93 passed +12 expected negatives;0 unexpected failed/skipped/runtime warnings**. Включены assignment, новые async guards, прежние sync P2 и lifecycle guards, вопросы и история — все потребители изменённого matcher.115 roots/207 opens/207 successful native closes/115 removals;117 scope attachments побайтно сверены с direct evidence. Два внешних scope пусты, потому что отдельный контролируемый scope проверяется внутри теста throw/cancel.

Первый targeted до расширения controls тоже сохранён как `after`:26 функций/45 запусков,0 unexpected failures; это предыдущая версия новых controls, не финальная проверка source SHA.

### Один обязательный full: FAILED

Выполнен **один** `make check DERIVED_DATA=/private/tmp/golos58assignment-derived` после окончательных Swift-правок. [run_full.py](run_full.py) сохраняет source SHA и env, отказывается перезаписывать результаты и снимает disk/log-stage telemetry каждые5s. У DerivedData свои Build/Logs/Module/Index; `SourcePackages` ссылается на ранее существующий cache `/private/tmp/golos-51-derived/SourcePackages`, новых весов не скачивалось. Использована ранее разрешённая public E5 `/tmp/golos-embedding-native/e5-small`, synthetic Talk/Menu opts и safe test host. Реальный ASR исключён стандартным make target.

Фактический результат:

- **449 функций:444 passed,1 failed,4 с expected negative outcomes.**
- **636 запусков:623 passed,1 failed,12 expected negative outcomes.**
-0 skipped,0 runtime warnings. Compile warnings существующего Swift-кода не выдаются за отсутствие warnings вообще.
- Единственный отказ: `ProjectMemoryQueueTests.concreteMetadataBridgeReceivesReadyEventWithoutLaunchingApplication` — **metadata bridge ready-source coverage**, прежний5s deadline. Scope trace дошёл до `metadata-bridge-initial-snapshot`; complete marker отсутствует. [Original activities](results/full-bridge-activities.json). Это открытый #61, причина здесь не исследовалась и timeout не менялся.

Native ledger красного full: **211 roots/364 opens/364 actual close=0/211 removals**,0 teardown timeouts.213 scope attachments побайтно сверены; все accepted markers ссылаются на разные исходные events. [Attachment audit](results/full-attachment-audit.json).

В full сохранились22 vnode сообщения других семейств: questions-ui15, knowledge-search5, index-service2. У assignment-fixture0; extended6922=0. Это не закрытый #58 и не «тихий stderr» всего приложения.

OCR в этом конкретном full прошёл:40 successful extraction streams и один предусмотренный invalidDocument error. Все82 OCR attachments/41 invocation проверены по точным input bytes/SHA; [audit](results/full-ocr-audit.json), [synthetic assets](results/ocr-assets). Прежние e5rt10/e5rt13/mixedPDF отказы остаются сохранённым evidence предыдущих PR и этим прогоном не отменяются. Никаких новых OCR probes/cache settings/системных изменений не было.

Disk telemetry:20 samples, минимум **7,415,693,312 bytes (~6.91 GiB)**, без ENOSPC/write failures в сохранённом запуске. [Telemetry](results/full-telemetry.jsonl), [receipt](results/full-receipt.json). Этот замер относится только к новому full; он не устанавливает причину старых отказов. Green rerun не выполнялся.

Whole failed bundle сохранён локально: `/private/tmp/golos58assignment-preserved-full.xcresult`; original DerivedData bundle и exports также остаются. В git только scoped synthetic evidence, redacted test stdout/logs и JSON diagnostics; system logarchive/модели/бинарники не добавлены.

## Воспроизводимость и границы

Для controls используйте свежие `/private/tmp` paths:

```sh
python3 -B research/assignment-fixtures-58/prepare_control.py --output /private/tmp/assignment-before
python3 -B research/assignment-fixtures-58/prepare_control.py --output /private/tmp/assignment-retain --retain-roots
```

Команда до/контроля (поменять project/evidence path для retain):

```sh
TEST_RUNNER_GOLOS_ASSIGNMENT58_CONTROL=/private/tmp/assignment-before-events \
 xcodebuild test -project /private/tmp/assignment-before/golos-meet.xcodeproj \
 -scheme golos-meet -destination 'platform=macOS' \
 -derivedDataPath /private/tmp/assignment-control-derived \
 -clonedSourcePackagesDirPath /private/tmp/golos-51-derived/SourcePackages \
 -disableAutomaticPackageResolution -skipPackageUpdates \
 -only-testing:golos-meetTests/MeetingAssignmentTests CODE_SIGNING_ALLOWED=NO
```

Final targeted использует те же flags и собственный DerivedData; suites: MeetingAssignmentTests, SQLiteAsyncFaultExpectationTests, SQLiteFaultExpectationTests, SQLiteFixtureLifecycleTests, KnowledgeQuestionServiceTests, ProjectMemoryHistoryTests. Полная actual команда сохранена в final-targeted-xcodebuild log.

[export_results.py](export_results.py) только экспортирует завершённые xcresults; [collect.py](collect.py) сохраняет исходные traces и сверяет attachments; [validate.py](validate.py) повторно проверяет evidence без тестов/OCR. Старые `after` trace соответствуют предыдущей версии controls; final source hashes проверяются против full receipt и final-targeted состояния.

Нет production lifecycle/close, retry, global serialization, retain-all-roots patch, suppression stderr, изменения schema/timeout. Questions UI/search не правились. Работа synthetic/temp; без пользовательских документов, Keychain, облачного транспорта, capture/ASR и новых моделей. UI не менялся и не запускался. Авторская самопроверка не заменяет независимое ревью точного SHA. Это частичный Refs#58; full gate красный, PR55/готовность продукта не объявляются принятыми, main/PR8draft неизменны.
