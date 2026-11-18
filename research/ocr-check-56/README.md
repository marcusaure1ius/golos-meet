# #56 · OCR: evidence, forward progress и отдельный SQLite teardown

## Результат и границы

Подтверждён новый forward-progress дефект: синхронный Vision из множества default actor jobs способен занять cooperative pool и перестать продвигаться. Минимальный fix переносит jobs **каждого** LocalDocumentExtractor на его private serial Dispatch queue. Межэкземплярная параллельность сохраняется. Vision options, лимиты, cancellation checkpoints, ошибки, merging и assertions не меняются; retry/skip/увеличения production timeout нет.

**Исходный PR55 e5rt code 10 не объявляется объяснённым новым timeout.** Первый — framework error после внутреннего deadline, новый — отдельно воспроизведённый parent-bounded hang. Их связь возможна, но прямого доказательства нет. Пакет сохраняет original failures, новые отрицательные контроли и успешные after отдельно. Готовность #55/всего продукта определяет координатор после независимого review; интерактивный путь автора не заменяется этими headless tests.

База: accepted preview `24b75f63bad8429aec00331c4968d6963a09bc09` (PR54 checked `81efc1a4bacc769ff1edf4aeac7008d10010c335`, merge/ancestry проверены). Candidate для сравнения — unreviewed PR55 `ee48e1d1f319f29d2a54f4f3d19488f492da061f`; он использовался только в собственных /private/tmp copies, его код не включён в рабочую ветку. Author checkout не менялся. #51 не переоткрывается, main/PR8draft неизменны.

## Что сохранено от исходных failures

До Xcode retention final bundle 02:39 целиком скопирован в `/private/tmp/golos56-original-pr55/original-final.xcresult`, diagnostic/logarchive экспортированы рядом; SHA-256 сохранённых файлов — `/private/tmp/golos56-original-pr55/preserved-sha256.json`. Полный archive содержит системные процессы и не публикуется; в git — только фильтр synthetic test-host PID84693 с заменой личного cache prefix.

- [PNG failure](results/full-previous-failed.json): Russian «Решение: запуск проекта в ноябре», thrown e5rtError("e5rt_stream_completion_handler call failed",10). Старый bundle 02:30 удалён retention; сохранены summary/activities/runner log, полнота stdout ограничена.
- [Mixed-PDF failure](results/full-final-failed.json): native="Page 1", scanned="Decision: launch postponed to December", duplicateNative=false, exact-line count0 вместо1. Original input bytes/hash и распознанный output не записывались и восстановить их задним числом нельзя. Новая генерация по тем же исходникам не называется побайтной копией старого sample.
- [Original scoped unified log](results/original-vision-unified-redacted.json): первые наблюдаемые image1800×2400 и внутренний timeout `main__Op2_Cast`, затем e5rt10/CRImageReaderError1. Compiled E5 cache lookup уже имел exists=1. Это системный TextRecognition E5, **не embedding ONNX E5-small**.
- [Warning-only control](results/passing-warning-control.json): «Unable to find a valid E5 in provided path» присутствует и в прошедшем baseline. Сам по себе этот warning не различает успех и отказ; очистка cache не предлагается как fix.

PDF production path при OCR throw и непустом native text возвращает native + warning. Поэтому старый count0 assertion мог быть следствием framework fallback либо другого output; без того output нельзя выбрать причину только по assertion и соседнему логу.

## Воспроизводимый matched контроль

`build_probe.py` читает указанный ref через git show. В standalone research-копию вставляются **явные** trace patches из [instrumentation.py](instrumentation.py): actual file bytes, фактически поданные в Vision CGImage PNG/sha/dimensions, options, все top candidates/bboxes/confidences, error/catch и monotonic/wall times. Branch production не получает этих hooks. [Build receipts](results/build-receipts.json) фиксируют источники/patches/hash/команды.

Fixture drawing blocks берутся из выбранного LocalDocumentExtractorTests.swift; набор — PNG en/ru, пять mixed-PDF параметров и native two-page PDF. Генерация заморожена один раз: [actual inputs + SHA](results/frozen-inputs.json). Baseline/candidate OCR implementation, models и original fixture-generator source hashes одинаковы. Все assets — только synthetic.

Matched before/after использует один driver/source/target arm64-macos14.4, одинаковые frozen bytes, default Vision, fanout32 и deadline90s; меняется только executor. У каждого процесса отдельный CFFIXED_USER_HOME; фактические E5 bundle caches созданы под этими temporary homes. Существующий cache не удалялся. Shared OS/Metal caches и посторонняя нагрузка машины не сбрасывались; это ограничение сравнения, а не скрытая «cold system» гарантия.

| Контроль | Actual исход |
|---|---|
| [Reference cooperative actor](results/matched-reference.json) | Parent timeout90s; 14 начатых незавершённых extract, остальные не успели начать |
| [Private dispatch executor](results/matched-queue.json) | 32/32 success, 29,19s, без framework error/assertion mismatch |
| [Независимые OS task executors](results/threads-default.json) | 32/32 success, 28,94s; сохраняет параллельность |
| Default/preflight-default/CPU на cooperative pool, отдельные fresh homes | Каждый остановлен parent timeout180s, 14 incomplete; смена compute option не снимает scheduling problem |

[Проверка exact Vision image hashes](results/matched-input-audit.json) подтверждает совпадение каждого наблюдавшегося before image с after, представлены все восемь типов fixture. Reference и fixed CGImage bytes совпадают; это не вывод из одного имени файла.

[Stack sample reference](results/fanout-default-sample.txt.gz): cooperative threads внутри VNImageRequestHandler/VNControlledCapacityTasksQueue ждут sync queue; один поток в TextRecognition ждёт semaphore. Процесс имел CPU≈0%, footprint≈390MiB (peak≈564MiB). Этот sample и executor controls подтверждают scheduling/forward-progress механизм нового hang; они не измеряют holder старого framework deadline.

До этого exploratory sequential/parallel default/CPU trials прошли. Первый sequential perform занял26,4s, поздние — доли секунды; этот порядок и прогрев **не используются** как доказательство преимущества concurrency/CPU. [Полный индекс](results/probe-index.json) сохраняет их отдельно с фактическими manifests. У ранних exploratory builds полная копия Probe.swift не сохранялась, только hash/binary/patch receipts; primary matched builds сохраняют исходную копию. Parent timeout, framework error и assertion mismatch различаются в recorder. Driver теперь требует явный `--expect timeout` для успешного выхода negative control; положительный запуск с error/mismatch/timeout возвращает ненулевой exit.

Контракт: [Swift global executor не предназначен для блокирующих операций без forward progress](https://developer.apple.com/documentation/swift/globalconcurrentexecutor), [Apple WWDC21 о cooperative pool](https://developer.apple.com/videos/play/wwdc2021/10254/), [compute-device control Vision](https://developer.apple.com/documentation/vision/vnrequest/setcomputedevice(_:for:)). Это контекст API; причинный вывод основан на recorded controls.

## Production/test delta

В LocalDocumentExtractor.swift добавлен небольшой SerialExecutor с immutable private DispatchQueue. Он исполняет каждый consumed job один раз, удерживает executor до конца job, сохраняет actor isolation. У разных extractor разные очереди; global OCR lock не добавляется. Никаких исследовательских CPU/trace flags в production.

В LocalDocumentExtractorTests:

- Новая реальная parallel OCR regression выполняет32 PNG extraction с прежним English assertion.
- PNG/PDF calls прикладывают **исходные bytes перед извлечением**, SHA, wall/elapsed, полные blocks/lines/warnings либо оригинальный thrown error к текущему тесту. При последующем assertion эти данные уже записаны. Исходные assertions сохранены.
- Negative control actual invalid PNG сохраняет исходную invalidDocument ошибку, не превращая её в success.
- [Аудит экспортированных attachments](results/attachment-audit.json):82 attachments,41 input hashes сверены, invalid input bytes0/1/2/3 и original error восстановлены после удаления fixture roots. Это проверка реального xcresult export, не только вызова recorder API.

[Swift Testing attachments](https://developer.apple.com/documentation/testing/attachments) используются только для synthetic test inputs. Production documents/outputs в них не попадают.

## Проверки и comparison workload

[checks.json](results/checks.json):

- Неизменённый accepted baseline full:429 tests/603 runs Passed, QoS warning.
- Instrumented accepted full:429/603 Passed, QoS warning; recorded12 OCR extractions.
- Instrumented exact55 full:447/621 Passed, QoS warning; recorded13 OCR extractions. Это новые положительные runs, не отмена двух original failures. Одинаковые opts/public E5 и генерация; candidate добавляет свой panel workload, поэтому это comparison всего treatment, не isolated measurement одной функции. Trace I/O также может влиять на timing.
- Final targeted:20 tests/33 parameter runs Passed, без warnings. Parallel regression внутри test делает32 real calls дополнительно к внешним parameter counters.
- Final own-branch `make check` с public E5/Talk/Menu opts: **431 tests/605 runs, 0 failed/0 skipped/0 runtimeWarnings**.
- Exact55 temporary copy + только OCR fix/tests overlay: **449/623, 0 failed/0 skipped/0 runtimeWarnings**. Overlay receipt в build-receipts; author branch не изменялась и не включена в PR.
- Отдельный Release build для macOS14.4 — BUILD SUCCEEDED, app не запускалась.

Смена источников между warm/late runs не скрывается. Полный baseline без instrumentation запускался отдельным дополнительным прогоном; initial command выбрал текущий accepted worktree вместо временной копии, поэтому он честно выделен как uninstrumented baseline. Все instrumented comparison команды явно выбирали свой `-project`.

## SQLite cleanup — отдельный подтверждённый симптом

[Scoped raw lifecycle](results/sqlite-lifecycle.json), [retain-root negative control](results/sqlite-retained.json), [точная сводка](results/sqlite-control-summary.json). В temporary accepted-copy наблюдались test name → root UUID → connection UUID → removal/error/close. Выбирались только known synthetic prefixes memory-update/index-hooks, SQL/values/личные пути не пишутся.

Один и тот же non-OCR selected workload:43 tests/78 runs Passed в обоих вариантах. Default teardown дал **9 ошибок6922 и2 сопутствующих rollback=1** (11 SQLite errors всего). В восьми error records root уже отсутствовал. `rootExists=true` не доказывает наличие DB inode во время рекурсивного unlink. При сохранении78 roots до выхода test host —0 SQLite errors. В original historical log нет такого connection→test mapping; новые имена не приписываются старым UUID задним числом.

Наблюдавшиеся новые owners: latestDisabledConfigurationWinsQueuedEnableAndBridgeStop, concreteMetadataBridgeReceivesReadyEventWithoutLaunchingApplication, metadataAndIndexSubscriptionsCoalesceAndSettingsCanStopThenResumeSameWorker и два IndexingProductionHooks tests — полные имена в summary. Удаление roots при ещё живых store/background jobs требует отдельного fixture drain/lifetime решения. Retain-root — **только causal control**, не patch, не предлагаемое накопление каталогов. Production stop может быть логической отменой, не физическим join всех подписок/adapter tasks. Произвольное изменение stop semantics памяти здесь не делается.

SQLite errors воспроизводились без Vision/OCR workload. Это не доказательство, что они вызвали старый e5rt error; симптомы разделены. #51 lock mechanism не меняется.

## Воспроизведение

Используйте новые output/home paths: существующие evidence не перезаписываются. Swift toolchain/Xcode текущей машины; CLI target14.4, independent task-executor control требует macOS15+. Никакие веса не скачиваются.

```sh
python3 research/ocr-check-56/build_probe.py --ref 24b75f63bad8429aec00331c4968d6963a09bc09 --output /private/tmp/ocr56-before-build
python3 research/ocr-check-56/build_probe.py --ref HEAD --output /private/tmp/ocr56-after-build
python3 research/ocr-check-56/run_probe.py --binary /private/tmp/ocr56-before-build/ocr-probe --inputs /private/tmp/ocr56-inputs --output /private/tmp/ocr56-before --isolated-home /private/tmp/ocr56-before-home --mode fanout --compute default --repeats 4 --timeout 90 --expect timeout
python3 research/ocr-check-56/run_probe.py --binary /private/tmp/ocr56-after-build/ocr-probe --inputs /private/tmp/ocr56-inputs --output /private/tmp/ocr56-after --isolated-home /private/tmp/ocr56-after-home --mode fanout --compute default --repeats 4 --timeout 90
TEST_RUNNER_GOLOS_MEET_E5_FOLDER=/tmp/golos-embedding-native/e5-small TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 make check
```

`prepare_test_copy.py`/`trace_sqlite_copy.py`/`retain_sqlite_control.py` предназначены только для новых private/tmp copies выбранных refs. Каждый добавленный hook записывается в receipts. Они не нужны production fix и не должны применяться к чужому checkout. `collect_results.py` фиксирует источники уже выполненных локальных экспериментов, а не является portable general runner. Его пути относятся к этому исследованию.

## Передача

Исправлен доказанный executor дефект с substantive bounded negative control и real OCR regression. Исходный PNG/MixedPDF framework/assertion episode сохранён с точными missing-data limitations. Дополнительные гарантии отсутствия любого будущего e5rt10 не заявляются; при повторе нужны новые exact bytes/returned output/warnings и scoped framework log. Автоматическая retry/serialization/cache deletion/timeout extension для его сокрытия не добавлены.

Перед merge — независимое exact-SHA review, только координатор. Main/PR8draft/чужие checkout неизменны. Живые Keychain/пользовательские документы/ASR/capture/cloud/новые модели не использовались. Старый global logarchive остаётся локально, model caches/бинарники/weights в git не включаются.
