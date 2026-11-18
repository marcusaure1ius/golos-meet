# #58 · Завершение SQLite fixtures перед удалением каталогов

## Предлагаемое изменение

Тесты пяти семейств fixtures теперь владеют временными каталогами до освобождения store и успешного `sqlite3_close`. Очистка выполняется после возврата тела каждого test case, включая выход с ошибкой. Production `stop()`, подписки, worker, schema, busy timeout и retry не меняются. В application source добавлено только DEBUG-наблюдение native open/close/error; в Release его нет.

Проверена фактическая очистка 94 roots и 153 закрытия соединений. Последний combined `make check`: **434 tests / 608 runs, 0 failed / 0 skipped / 0 runtime warnings**. В scoped трассах нет SQLite failures/teardown timeout; в полном stdout нет extended6922. Это минимальная проверяемая часть #58, а не устранение всех lifecycle diagnostics репозитория: в других fixtures остаются 83 vnode-unlink сообщения, перечисленные ниже. Поэтому PR использует `Refs #58`, задача остаётся открытой до решения координатора о продолжении.

Начальная принятая база — `24b75f63bad8429aec00331c4968d6963a09bc09`, PR54 checked `81efc1a4bacc769ff1edf4aeac7008d10010c335`. Historical before/control и первые проверки выполнены на ней. После независимого принятия PR57 checked `bc28cf7ff9f458e9f01219b8d27c38ce7750e660` ветка fast-forward обновлена до accepted preview **`885b41e10d3caaed42d91d935776fc79e2b5044e`**; final combined проверяет эту основу. Старые результаты не переименованы в проверки новой базы. Непроверенного кода55 нет; checkout55/57 не редактировались.

## Установленный механизм

[Новый before](results/before-events.json) наблюдает исходный accepted код в отдельной `/private/tmp` копии. [Скрипт](prepare_before.py), [receipt с точными patches](results/before-receipt.json) и [фактически скомпилированный observer](results/before-observer.swift.txt) сохранены. Прямое управление SQLite/VFS/кодами/таймаутом не добавлялось. Наблюдатель пишет события сразу, не удерживает store/worker; ObjectIdentifier при публикации заменён opaque owner labels с сохранением равенства. SHA исходного raw файла указан в JSON.

Трасса сопоставляет test → synthetic root → store/worker owner → native connection → stop/deinit task → unlink/error/close:

- `latestDisabledConfigurationWinsQueuedEnableAndBridgeStop`: root удалён в332677.972958; задача `KnowledgeMemoryQueue.deinit` входит в332677.973417, worker.stop — в332677.973516; `BEGIN IMMEDIATE` получает6922 в332677.975618, close=0 позже в332677.976152. Повторный stop после логической отмены всё ещё выполняет публикацию snapshot через store.
- `concreteMetadataBridgeReceivesReadyEventWithoutLaunchingApplication` и `metadataAndIndexSubscriptionsCoalesceAndSettingsCanStopThenResumeSameWorker`: тот же поздний bridge stop/deinit path. Их имена, root/connection и последовательности доступны в raw events.
- `defaultProducerHooksRunWithoutViewsAndTranscriptDoesNotWaitForLLMOrIndexing` и `actualFileMonitorReconcilesExternalAtomicAndInPlaceTranscriptChangesWithoutUI`: KnowledgeIndexing.stop/deinit запускают новые задачи service.stop. Явный `await service.stop()` внутри тела не присоединяет задачи, которые будут созданы позже из deinit.

В fresh before все **43 tests / 78 runs** прошли assertions, но зарегистрированы **14 ошибок6922 + 2 rollback=1**. Удалены78 roots, закрытия102 из134 открытых соединений наблюдались до выхода host; неполный deinit также связан с test callbacks, удерживавшими fixture. Это новый прогон, не прежние9+2 из #56. [Исходные #56 events](results/original56-sqlite-lifecycle.json), [control](results/original56-sqlite-retained.json) и [summary](results/original56-sqlite-control-summary.json) сохранены отдельно, без ретроспективной привязки исторических UUID к новым тестам.

`rootExists=true` при ошибке во время recursive unlink не доказывает наличие DB inode. По одной соседней строке stdout причину не назначаем. Ни SQLite lifecycle, ни новый executor hang не объявляются объяснением исторического OCR e5rt10/count0.

## Контроли

1. [Fresh retain-root control](results/retain-events.json): тот же accepted ref, selected workload43/78 и tracing, но78 roots сохраняются до выхода host. SQLite errors=0. Это только причинный контроль. После завершения xcodebuild родитель удалил **все78** перечисленных synthetic каталогов; [receipt](results/retain-parent-cleanup.json) подтверждает отсутствие каждого. В предлагаемом patch такого режима нет.
2. `cleanupWaitsForLateTaskWriteAndNativeCloseBeforeUnlink`: реальная Task удерживает ProjectStore за gate. Cleanup уже начат, каталог ещё существует и close не было. После release Task выполняет настоящую запись, читает2 проекта и заканчивается; затем native close=0 и root удалён. [Контрольные traces](results/controls/) и итоговый [экспорт94 attachments](results/attachment-audit.json) проверены побайтно.
3. `throwingBodyReleasesStoreAndPreservesOriginalFailure`: ошибка тела сохраняется; после освобождения store реальное соединение закрыто и каталог удалён.
4. `connectionObserverOwnsFailureEvenWhenCallerHasAnotherTaskContext`: реальный SQLite prepare-error при вызове в чужом task-local контексте получает observer создававшего соединения. Чужой observer не получает ни error, ни close. Это regression найденной ошибки диагностики, не подмена SQL результата.
5. [Native C control](native_unlink.c) без Swift/Testing/VFS replacement использует системную SQLite3.54.0. При раннем unlink поздний INSERT получает **READONLY_DBMOVED=1032** (BEGIN=0, rollback/close=0). При write→commit→close→unlink сохраняются2 строки, все коды0 и root отсутствует. [Actual results](results/native-unlink.json). Это отдельный механизм real SQLite API: код1032 не выдаётся за воспроизведение6922. Обычный и ASan/UBSan native процессы завершились успешно.

## Scoped cleanup

`SQLiteFixtureTrait` использует [Swift Testing TestScoping](https://developer.apple.com/documentation/testing/testscoping) только для **test case**, не дополнительной внешней области функции. Параллельность тестов не отключается. Область:

- получает только явно зарегистрированные synthetic roots и слабые ссылки на их основные store;
- после возврата тела запускает слабые cleanup requests, в том числе разрывает test callback cycles; QueueFixture сохраняет logical stop и явно ждёт worker idle;
- ждёт освобождения store **и** actual native close всех наблюдаемых connections, включая дополнительные прямые ProjectDatabase и задачи deinit. Weak references читаются без удержания event lock, чтобы последний temporary retain не вызвал reentrant deadlock на close;
- при незавершённых ресурсах за8 секунд фиксирует ошибку и сохраняет каталог для разбора. Каталог не удаляется через живые handles. Это предел тестового teardown, не изменение production timeout;
- удаляет roots только после drain, записывает проверку отсутствия и прикладывает trace к текущему test case. Все94 JSON из final xcresult экспортированы и совпали с сохранёнными traces побайтно.

Область не удерживает store/worker и не закрывает их принудительно. DEBUG observer захватывается соединением при открытии: callback NotificationCenter может исполняться в контексте отправителя другого теста. Существующий beginObserver fixture51, SQLite SQL/rollback/error, schema и busy_timeout=2000 сохранены. Release build успешен без запуска; [nm audit](results/release-audit.json) подтверждает отсутствие `lifecycleObserver`, `capturedLifecycleObserver`, `LifecycleEvent` в app Mach-O.

Применено к:

| Семейство | Final roots | Причина |
|---|---:|---|
| memory-update | 75 | Общий UpdateFixture, queue callbacks и поздние bridge stop/deinit |
| index-hooks | 3 | Контроллер/FSEvents и async service.stop из stop/deinit |
| assignment-runtime | 13 | Такой же KnowledgeAssignments stop/deinit, обнаружен полным stdout |
| native-index-queue | 1 | KnowledgeIndexing late stop на настоящем local E5 test runtime |
| fixture-lifecycle | 2 | Gate и throwing-body controls |

UI/recording/index semantics приложения не менялись. Основной граф ресурсов был полностью известен до выхода тела; helper не является универсальным способом присоединить произвольные незарегистрированные Task.

## Проверки, неудачные попытки и пределы

[Все summaries](results/checks.json), raw xcodebuild/stdout gzip и [source hashes](results/source-hashes.json) сохранены.

- Первоначальный prototype не собрался из-за `@concurrent` signature TestScoping. Следующий дал crash Xcode HarnessEventHandler: scope исполнялся и для функции, и для case, attachment записывался повторно после завершения case. Эти discarded attempts не считаются lifecycle before. [Crash stdout](results/prototype-crash-stdout.txt.gz) сохранён; guard `testCase != nil` устраняет внешнюю область.
- После исправления targeted43/78 прошёл;134 открытий/закрытий и78 удалений. Original targeted xcresult позже удалён retention; полный xcodebuild log/traces сохранены. Затем targeted45/80 с двумя native-resource controls прошёл без warnings.
- **Old-base full**, ещё без accepted57:427 passed/4 failed. Три OCR failures: e5rt13 и mixed-PDF count0; один failure нового observer был ошибочно отнесён к чужому task context. Original summaries/stdout сохранены, исходные OCR bytes в той версии не прикладывались. Исправлена только привязка observer к connection; исходный OCR эпизод этим не объясняется.
- **Первый combined full** на885b41e:433 passed/1 failed. Metadata bridge не уложился в прежнее5s ожидание; точная фаза старого ожидания не записывалась. [Activities](results/bridge-failure-activities.json) и scoped trace сохранены. Добавлены phase markers initial-snapshot/ready-coverage, условия и5s не ослаблены. Новый успешный прогон не доказывает причину старого timeout. Во время первого combined была также активна отдельная сборка retain control; это ограничение нагрузки, не доказанная причина. В том stdout найдено позднее обращение к assignment-runtime, поэтому та же ownership strategy применена ещё к двум конкретным fixtures.
- **Final combined make check** на accepted885b41e + текущая scoped правка:434 tests/608 runs,0failed/0skipped/0runtimeWarnings.94 roots/153 opens/153 close=0/94 removals,0 scoped failures/timeouts. Actual full stdout: **0 extended6922**.
- Release build без запуска и native ASan/UBSan controls прошли. Rust не менялся. Настоящий ASR E2E исключён стандартной целью; использовались уже разрешённые public E5, synthetic settings/menu renders, fake LLM и временные документы.

**Оставшееся ограничение:** [full stdout audit](results/stdout-audit.json) содержит83 `vnode unlinked while in use` messages у question-service29, memory-history19, assignment-fixture13, questions-ui12, knowledge-search8. Эти семейства не входят в описанный patch, их обычный defer тоже может сработать до освобождения владельцев. Нулевые Xcode runtimeWarnings не означают тихий stderr. Для следующей небольшой партии нужны scoped ownership и разбор намеренных fault-injection тестов этих suites; слепо подавлять их SQLite errors или объявлять весь58 готовым нельзя.

## Воспроизведение

Все output paths должны быть новыми. Before/control всегда используют зафиксированный old accepted ref24b75f6; final app/tests — текущий checked SHA на accepted885b41e. Existing public weights не скачиваются.

```sh
python3 -B research/fixture-lifecycle-58/prepare_before.py --output /private/tmp/fixture58-before-copy
python3 -B research/fixture-lifecycle-58/prepare_before.py --output /private/tmp/fixture58-retain-copy --retain-roots
run_fixture_control() {
  TEST_RUNNER_GOLOS_FIXTURE_BEFORE="$2" xcodebuild test \
    -project "$1/golos-meet.xcodeproj" -scheme golos-meet \
    -destination 'platform=macOS' -derivedDataPath "$3" \
    -only-testing:golos-meetTests/ProjectMemoryQueueTests \
    -only-testing:golos-meetTests/ProjectMemoryUpdateTests \
    -only-testing:golos-meetTests/IndexingProductionHooksTests CODE_SIGNING_ALLOWED=NO
}
run_fixture_control /private/tmp/fixture58-before-copy /private/tmp/fixture58-before-events /private/tmp/fixture58-before-derived
run_fixture_control /private/tmp/fixture58-retain-copy /private/tmp/fixture58-retain-events /private/tmp/fixture58-retain-derived
TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE=/private/tmp/fixture58-after-evidence \
TEST_RUNNER_GOLOS_MEET_E5_FOLDER=/tmp/golos-embedding-native/e5-small \
TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 \
make check DERIVED_DATA=/private/tmp/fixture58-after-derived
clang -Wall -Wextra -Werror research/fixture-lifecycle-58/native_unlink.c -lsqlite3 -o /private/tmp/fixture58-native
/private/tmp/fixture58-native
```

Retain control — только в отдельной synthetic copy. После test-host exit удалить перечисленные78 roots и проверить отсутствие; production/test patch не должен наследовать этот контроль. `collect_evidence.py` — collector конкретного локального исследования с явными `/private/tmp/golos58-*` paths, не переносимый general runner. Он не выгружает полный logarchive: системные archives остаются локально, публикация включает только synthetic test stdout и редактированные paths.

`python3 -B research/fixture-lifecycle-58/validate_evidence.py` проверяет сохранённые counts, close-before-unlink для каждого root, native outcomes, source hashes и receipt hashes.

Следующий шаг — independent exact-SHA review и решение координатора по оставшейся части58/исходным56. Автор не сливает PR; main/PR8draft неизменны. Рабочие данные, реальные Keychain/облако/capture/ASR не использовались.
