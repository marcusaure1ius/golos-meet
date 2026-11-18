# PR #46: исправление выполнения migration fixture

## Исходный независимый результат

Независимый полный E5 `make check` на `0179499e73cd720989363d7d15accf552e4a2ea6` завершился **308 passed / 372 запуска / 1 failure / 2 skipped**. Это не заменяется прежним авторским зелёным прогоном. Упал `EmbeddingMigrationRaceTests.concurrentConnections...version0`: acquire 0,168 мс, первый task 0,284 мс, SQLite BEGIN 0,532 мс; второй task не стартовал до watchdog около 5005 мс.

Fixture блокировала Swift cooperative executor внутри `SQLITE_TRACE_STMT`, ожидая другую задачу на том же executor. `.serialized` ограничивала только эту suite; параллельные блокирующие suites могли занимать остальные потоки. Отдельный watchdog освобождал lock, но не обеспечивал выполнение второго task. Этот результат подтверждает дефект test execution, а не дефект production SQLite busy handler.

## Изменение и доказательства

Изменён только `EmbeddingMigrationRaceTests.swift`: два test-owned `TaskExecutor`, каждый со своим Foundation Thread и очередью jobs. Реальные `ProjectStore.snapshot()` actor-вызовы сохранены. Предпочтение executor проходит в default actor по [SE-0417](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md); thread-local UUID сверяется непосредственно на SQLite BEGIN и на task-start. Одного раннего маркера Task недостаточно. Actor и production Database не получают специального executor.

Проверка contention требует разных connection UUID и executor UUID, обоих SQLite BEGIN после acquire и до release, совпадения task/SQLite executor и отсутствия любого timeout. Сохранены реальные reserved lock, v0/v2 миграции, задержки actor 650/900 мс, задержка peer 2500 мс, premature-release negative control, failure cleanup, watchdog 5 с, COMMIT/close и join до удаления временной БД. Production `busy_timeout=2000` и retry не менялись.

Новый negative control намеренно запускает обе настоящие snapshot на одном test executor. Первый SQLite callback занимает поток; второй BEGIN приходит после watchdog. Обе задачи завершаются, освобождение/закрытие успешны, contention predicate отвергает результат, новая EXCLUSIVE transaction подтверждает отсутствие удержанного writer перед cleanup. Этот ожидаемый timeout не принимается в положительных сценариях.

Executors закрываются после обоих task results и освобождения DB lock, очередь дорабатывает jobs; завершение потока отмечается `executors-joined` перед общим `joined`. API TaskExecutor доступно с macOS 15: только эта suite явно отключена на macOS 14 через `.enabled`, deployment приложения остаётся 14.4. На проверенном macOS 27.0.1 suite выполнилась целиком, без skips. macOS 14 fallback в этом исправлении не реализован.

## Проверки до интеграции preview

```sh
TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 \
TEST_RUNNER_GOLOS_MEET_MIGRATION_TRACE_DIR=/tmp/golos46-strict-final-traces \
xcodebuild test -scheme golos-meet -destination 'platform=macOS' \
  -derivedDataPath "$PWD/.build/xcode" \
  -only-testing:golos-meetTests/EmbeddingMigrationRaceTests CODE_SIGNING_ALLOWED=NO

TEST_RUNNER_GOLOS_MEET_E5_FOLDER=/tmp/golos-embedding-native/e5-small \
TEST_RUNNER_GOLOS_MEET_MIGRATION_TRACE_DIR=/tmp/golos46-full-fixture-traces make check
```

- Strict selected suite: **5 passed / 7 запусков / 0 failures / 0 skipped**, `Test-golos-meet-2026.10.31_22-39-11-+0300.xcresult`, runtimeWarnings пуст. Каждый JSON event подтверждает получение `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`; ширина глобального pool отдельно не измерялась.
- Полный E5: **310 passed / 374 запуска / 0 failures / 2 skipped**, `Test-golos-meet-2026.10.31_22-40-06-+0300.xcresult`. Existing QoS warning только `LocalDocumentExtractorTests.swift`. ASR E2E исключён. Оба прогона проверяют исходный head 0179499 плюс test-only исправление.
- В strict positive v0 BEGIN 0,967/1,093 мс → release 507,754 мс; v2 0,982/1,105 → 502,908; delayed peer 1,294/2524,803 → 3030,949. Разные реальные executor/connection UUID подтверждены. Shared-lane negative BEGIN 1,919/5017,762 мс при release 5006,333; преждевременное освобождение 502,778 мс перед BEGIN 1214,229/1416,028. Оба отрицательных сценария отвергнуты.

Полные sanitized events всех семи сценариев каждого прогона сохранены в [migration-fixture-46.json](migration-fixture-46.json). Cleanup использует текущую схему; исторический `fixture_version_label:4` не является тестом миграции из v4. Opt-in `GOLOS_MEET_MIGRATION_TRACE_DIR` пишет отдельный UUID.jsonl: только фиксированные названия, clocks, коды, UUID и strict flag; SQL/bindings/пути/содержимое не пишутся. По умолчанию файлов нет. Ошибка записи делает тест неуспешным. Action log xcresult сохранил лишь пять из семи stdout traces, поэтому полнота проверена по отдельным JSONL.

## Интеграция принятого PR #44

Fixture-коммит `8e8f4031507204d5c583fc972abd931ebbc15d03` отделён от merge `a8dbbc74a826f78ff150949e65bcef19f2753594`. Включён `origin/codex/product-preview` **8f04bb85258c25142c06599e38fc64c2d3075702**, содержащий принятый head #44 **1005554fe1c4c1163bcce332cfa40e6f3ca9f175** и ранее принятый #42. PR metadata/ancestry проверены после fetch. Единственный конфликт `applicationWillTerminate` разрешён порядком test-host guard → coordinator.prepareForTermination → assignments.stop → indexing.stop. `applicationShouldTerminate`, preserveAudio и остальная принятая логика #44 сохранены. Относительно preview AppDelegate добавляет только assignments.start/stop.

```sh
TEST_RUNNER_GOLOS_MEET_E5_FOLDER=/tmp/golos-embedding-native/e5-small \
TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 \
TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 \
TEST_RUNNER_GOLOS_MEET_MIGRATION_TRACE_DIR=/tmp/golos46-combined-preview-traces make check
```

Совмещённый SHA **a8dbbc74a826f78ff150949e65bcef19f2753594**: **349 passed / 444 запуска / 0 failures / 0 skipped**. `Test-golos-meet-2026.10.31_22-45-21-+0300.xcresult`, лог `/tmp/golos46-combined-preview-check.log`. Оба opt-in settings/menu теста выполнены. Это NSHostingView renders и проверки native menu, новый CUA-pass/живой звонок не выполнялись. Настоящий ASR E2E исключён. Единственный runtimeWarning — прежний QoS в LocalDocumentExtractorTests; compile warnings существующих ASR/Sidecar Swift 6 isolation и AppIntents metadata сохраняются.

Все семь combined JSONL сверены: положительные реальные lock/executor/connection доказательства есть, оба negative control отвергнуты, COMMIT/close успешны, tasks/executors joined. В combined v0 BEGIN 1,467/24,999 мс → release 532,510; delayed peer 2,640/2557,974 → 3063,648. Полные events добавлены третьим отчётом в JSON. Последующие изменения касаются только этих исследовательских отчётов.

При исправлении fixture production timeout/retry/данные/модели не менялись, новых загрузок и облачных вызовов нет. Новый SHA требует независимой delta-проверки fixture и merge-resolution. Это не закрывает семантический остаток #45 и весь #14/#4. Автор не сливает PR в preview/main.
