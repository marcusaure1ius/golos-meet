# #58: lifecycle `KnowledgeQuestionModelTests.QuestionUIFixture`

Адресная четвёртая часть #58. Принятая база — preview `7be254c4a1eceb28755ad60d718a4ed72cb21179`, PR62 checked `c9831bc4e15aecd42f95f11454e1b19f34a9ae63`. Перед новым managed worktree выполнены fetch, GitHub merge/head проверка, ancestry и пустой полный diff checked62→preview. Main `bd6191c7960ae017e8063795f19e2348cdc35bd9` не менялся.

## Actual mapping и причинный контроль

Старый `QuestionUIFixture.cleanup()` вызывал `model.cancel()` и сразу удалял root. Fixture продолжал держать primary store через собственное поле, ProjectLibrary, importer, search и фабрику sessions в model. `model.cancel()` сбрасывает UI-состояние и отменяет task, но не ждёт noncooperative response/query. `busy == false` не означает завершения этих операций.

[prepare_control.py](prepare_control.py) создаёт свежие временные копии accepted7be. Только test-side observer использует принятые DEBUG callbacks после actual native open/close; production в копиях не патчится. Фиксируются также вход/возврат fake transport и query, cancel и unlink.

- **Original before:**7 функций/15 cases Passed;15 roots/16 native opens/16 close=0. Все15 roots удалены при одном живом primary handle;15 `vnode unlinked`,0 extended6922. Один reopened store закрывался до unlink, primary — после.
- **Held-response before probe:** при удержанном fake response старый cleanup вернулся и удалил root. После release callback попытался реально записать synthetic project через тот же store: `step/beginImmediate/result10/extended6922`, затем `ProjectStoreError`. Native close=0 произошёл позже. Это конкретная воспроизведённая SQLite-ошибка данного fixture.
- **Retain-root causal control:** те же original15 cases +тот же held probe,8 функций/16 cases.17 opens/17 close=0,0 vnode/6922; late write probe завершилась успешно при существующем root. После **выхода host** все16 перечисленных roots удалены; [cleanup receipt](results/retain-parent-cleanup.json).

Before probe диагностический: он ловит и записывает исход ошибки, чтобы завершить измерение. Его1/1 Passed означает завершение probe, **не успешную SQL-запись**. Raw fault не скрыт и не переведён в allowance. [Probe source](HeldBeforeProbe.swift.txt), [installer](install_probe.py), [before SQL diagnostics](results/before-probe-sqlite-stdout.json). Probe-only строка clear callback после измерения разрывает намеренно введённый цикл и не изменяет уже наблюдённый результат cleanup/write. Этот probe не включён в app test sources PR.

Это causal control, не retain-all-roots patch. Причина historical OCR/bridge failures им не устанавливается; старые evidence сохраняются.

## Исправление

Изменяется только `golos-meetTests/KnowledgeQuestionModelTests.swift` плюс этот research-каталог:

- Original suite получает принятый SQLiteFixtureTrait. Root и primary store регистрируются до использования; один reopened store создаётся через зарегистрированный helper. DEBUG observer наследуется всеми native opens.
- Синхронный cleanup отменяет model и очищает stored callback, без unlink. Независимый test resource owner держит release gates; scope onFinish с weak model/spy работает и когда fixture уже освободился либо зациклен callback.
- OnFinish отменяет model/session, очищает callback и отпускает принадлежащие fixture held gates. Затем принятый scope ждёт исчезновения weak stores и фактических native close; только после этого делает unlink. Scope не удерживает model/spy/session сильно и не закрывает соединения принудительно.
- Сессии отслеживаются слабо только в fixture для проверок освобождения. Все production API, model generation/consent/postflight guards, schema, deadlines и существующие fault allowances неизменны.

Сохранены все36 исходных строк `#expect`/`#require` после нормализации spelling reopened constructor. Исходные8s settle/50ms delays/false conditions не ослаблены; [source check](results/source-check.json) и фактический diff. Новая проверка наличия scope учитывается отдельно.

## Meaningful after controls

Original15 cases: **16 actual native close=0 до15 removals**,0 vnode/6922.

Шесть новых cases — response/query × return/throw/cancel. Используется тот же fixture, настоящий model/service/search/store и локальные fake callbacks. Response намеренно образует fixture→spy→callback→fixture цикл; query удерживает настоящую prepare operation. Тело возвращается, бросает sentinel либо отменяет собственный child task и бросает CancellationError **без end-of-success cleanup**.

Scope onFinish обязан cancel/release их самостоятельно. После первого release noncooperative callback делает реальную позднюю SQL-запись и проверяет второй project. Второй, test-owned tail gate продолжает удерживать operation: model уже не busy, но model/session/primary store ещё живы и root существует. Это проверяет отсутствие раннего unlink непосредственно во время завершения работы. Затем tail release позволяет закончиться transport/query и model task.

Проверены native order, все weak references и исходный результат тела:

`body-finished → cancel/callback release → held gates released → late write success → transport/query returned → последний close=0 → unlink`.

После finish weak fixture/model/spy/store и все созданные sessions равны nil. Reopened connection закрывается при выходе тела, primary — после held operation. Отдельный седьмой control подтверждает реальный callback cycle уже **завершённой** операции: fixture жив до finish и освобождается после очистки callback.

Cancel здесь относится к body child task; cancellation самого parent test scope во время teardown отдельно не моделируется. 3s bounded wait относится только к новому control, существующие deadlines не менялись. Нет нового production shutdown/join API; отсутствие удерживающих resources и actual native close проверяются тестами.

**Targeted:9 функций/22 runs Passed,0 failed/skipped/expected/runtime warnings.22 roots/29 opens/29 close=0/22 removals**,0 teardown timeouts.22 attachments побайтно сверены с direct evidence. [Checks](results/checks.json), [attachment audit](results/after-attachment-audit.json), [stdout audit](results/stdout-audit.json).

## Один final full — FAILED

Перед своим targeted/final full проверено завершение xcodebuild чата04; его source/61 instrumentation не брались и не дублировались. У этого worktree свои Build/Logs/Index/Module caches; SourcePackages ссылается на существующий `/private/tmp/golos-51-derived/SourcePackages`.

[run_full.py](run_full.py) выполняет один `make check DERIVED_DATA=/private/tmp/golos58qui-derived`, сохраняет source SHA/env и отказывается перезаписывать completed log. Existing public E5 `/tmp/golos-embedding-native/e5-small` и synthetic Talk/Menu opts разрешены ранее. Safe test host не запускает рабочий UI/capture/recovery; реальный ASR E2E исключён стандартным target.

Фактический результат окончательного diff:

- **451 test:446 ordinary passed,1 failed,4 tests с expected negatives.**
- **643 runs:630 passed,1 failed,12 expected negatives.**
-0 skipped,0 runtime warnings. Compile warnings прежнего Swift-кода не выдаются за отсутствие warnings вообще.
- Единственный failure — `ProjectMemoryQueueTests.concreteMetadataBridgeReceivesReadyEventWithoutLaunchingApplication`: `metadata bridge ready-source coverage`, прежний5s deadline. `metadata-bridge-initial-snapshot` достигнут, complete marker отсутствует. [Original failure activities](results/full-failure-activities.json). Это открытый #61; его причина/production fix здесь не исследуются. Непроверенная instrumentation61 не импортирована.

Native ledger full: **233 roots/393 opens/393 actual close=0/233 removals,0 teardown timeouts**.235 scope attachments побайтно сверены; два пустых внешних scope принадлежат принятым assignment controls. [Full attachment audit](results/full-attachment-audit.json.gz), [scope mapping](results/scope-audit.json.gz).

В stdout остаются2 vnode сообщения других семейств: knowledge-search1/index-service1; questions-ui0, extended6922=0. Их число недетерминировано, это не закрытие всего #58. Blanket stderr filters не используются; сохранены полные redacted test stdout/build logs.

OCR именно этого full прошёл:40 successful extraction streams и один предусмотренный invalidDocument. Все82 OCR attachments/41 invocation сохранены с exact input bytes и raw result JSON/SHA; [OCR audit](results/full-ocr-audit.json.gz), [synthetic assets](results/ocr-assets). Это не объявляет OCR восстановленным и не отменяет прежние red bundles/e5rt10/e5rt13/mixedPDF failures.

Disk coordination/guard: preflight≥6GiB и отсутствие другого xcodebuild, runtime STOP floor4GiB с process-group termination до ENOSPC. Снято19 samples каждые5s; минимум **6,504,001,536B (~6.06GiB)**. Guard не сработал, ENOSPC/write failures не наблюдались. [Telemetry](results/full-telemetry.jsonl), [receipt](results/full-receipt.json). Это не диагноз старых failures. Full после этого результата не повторялся.

Whole failed bundle сохранён: `/private/tmp/golos58qui-preserved-full.xcresult`; original bundle/exports в отдельном DerivedData также остаются. Старые worktrees/Logs/evidence не удалялись. В git нет моделей, бинарников или system logarchive.

## Evidence и воспроизводимость

Крупный JSON упакован без изменения исходных bytes; `*-events.json.gz` хранит filename→exact UTF-8 trace, соседние trace hashes проверяют его. [validate.py](validate.py) открывает plain/gzip JSON, проверяет actual6922/retain control, шесть held paths, original assertions/source SHA, close-before-unlink, single-use faults принятого helper, exact attachments/OCR и фактический FAILED full. Он не запускает тесты/OCR/модели/сеть.

Подготовка копий:

```sh
python3 -B research/question-ui-fixtures-58/prepare_control.py --output /private/tmp/question-ui-before
python3 -B research/question-ui-fixtures-58/prepare_control.py --output /private/tmp/question-ui-retain --retain-roots
python3 -B research/question-ui-fixtures-58/install_probe.py /private/tmp/question-ui-before
python3 -B research/question-ui-fixtures-58/install_probe.py /private/tmp/question-ui-retain
```

Исходная suite запускается отдельно от probe; retained control включает обе. Команда (подставить свежие output/evidence paths):

```sh
TEST_RUNNER_GOLOS_QUESTION_UI58_CONTROL=/private/tmp/question-ui-before-events \
 xcodebuild test -project /private/tmp/question-ui-before/golos-meet.xcodeproj \
 -scheme golos-meet -destination 'platform=macOS' \
 -derivedDataPath /private/tmp/question-ui-control-derived \
 -clonedSourcePackagesDirPath /private/tmp/golos-51-derived/SourcePackages \
 -disableAutomaticPackageResolution -skipPackageUpdates \
 -only-testing:golos-meetTests/KnowledgeQuestionModelTests CODE_SIGNING_ALLOWED=NO
```

Для probe selector — QuestionUIHeldBeforeProbe. Final targeted выбирает KnowledgeQuestionModelTests и QuestionUIFixtureLifecycleTests в текущем worktree и собственном DerivedData, env `TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE`. Actual команды — в сохранённых `*-xcodebuild.log.gz`. [export_results.py](export_results.py) экспортирует только завершённые bundles; [collect.py](collect.py) собирает evidence.

Только synthetic/temp/fake transport. Без реальных документов/Keychain/cloud/capture/ASR/newweights. UI не менялся и не запускался; actual model/service test не выдаётся за интерактивный UI. Production/Rust/helper allowances diff пуст. Knowledge-search/index-service не патчатся. Самопроверка автора по golos-review не заменяет независимого ревью exact SHA. Это частичный Refs#58, общий full gate красный; main/PR8draft и PR55 не менялись, автор PR не сливает.
