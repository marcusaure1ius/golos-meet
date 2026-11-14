# #51: COMMIT внешнего test-lock и SHARED contender

Внешняя транзакция migration fixture предназначена только для удержания RESERVED lock. Прежний release через COMMIT мог сам потребовать EXCLUSIVE lock и получить SQLITE_BUSY, когда один из настоящих BEGIN contenders держал SHARED. Для служебной транзакции без данных release заменён на ROLLBACK. Production ProjectStore, схема, busy_timeout=2000, retry и код памяти не меняются.

## Исходное наблюдение и предел вывода

[Исходная трасса PR50](results/original-pr50-commit-busy.jsonl) сохранена побайтно из accepted `c9ba025ec72b8dc6a23254d3cd6526145308e8a4`; источник и SHA-256 — в [provenance](results/provenance.json). COMMIT внешнего lock вернул 5/5 в 524,340 мс, cleanup rollback/close — 0. Оба production snapshot впоследствии успешны. Это отдельная фаза относительно прежнего BEGIN BUSY #30.

В исходной трассе нет наблюдения native SHARED holder. Эксперимент ниже доказывает воспроизводимый механизм и неверность предположения «COMMIT служебного lock всегда успешен», но не устанавливает личность holder в эпизоде PR50 или повторе #37. Успешные новые прогоны не переписывают этот исходный failure. Никакого подтверждённого production-дефекта памяти из этих результатов не следует.

## Нативный контролируемый эксперимент

[lock_probe.c](lock_probe.c) работает отдельным процессом с системной SQLite. Process-local VFS делегирует все операции исходной native VFS. После двух реальных SQLITE_TRACE_STMT entries для BEGIN IMMEDIATE задерживается возврат одного **успешного native xLock(SHARED)**. SQLITE_FCNTL_LOCKSTATE подтверждает SHARED=1. В этот момент основной поток освобождает внешний RESERVED=2 lock.

| Действие внешнего lock | Native holder | Состояние writer после действия | SQLite result/extended | Cleanup | Оба contenders |
|---|---|---|---|---|---|
| COMMIT, отрицательный контроль | SHARED=1 | PENDING=3 | 5/5 | ROLLBACK=0, close=0 | BEGIN/COMMIT/close=0 |
| ROLLBACK, исправление | SHARED=1 | NONE=0 | 0/0 | close=0 | BEGIN/COMMIT/close=0 |

Коды не подменяются. Не устанавливается новый busy handler: у contenders штатный native busy_timeout=2000, внешний test-lock без ожидания. Пауза SHARED синхронизирует реальный native lock и моделирует вытеснение потока ОС, а не SQL ошибку. У процесса есть alarm 15 с, у runner — timeout 20 с. Упрощённый DDL в probe синтетический; миграции приложения отдельно проверяются Swift-тестами.

Матрица включает zero-byte v0 file и уже инициализированный SQLite-файл без таблиц. Оба имеют user_version=0; это не имитация production v2. В обоих случаях механизм воспроизводится, поэтому объяснение только особенностью заголовка новой БД не подтверждается. Actual v0/v2 остаются в production ProjectStore fixture.

[Четыре исхода](results/native-vfs.jsonl), [400 raw исходов](results/native-stress.jsonl), [сводка stress](results/native-stress-summary.json). Все 100 отдельных процессов дали четыре ожидаемых исхода: 200 COMMIT BUSY и 200 успешных ROLLBACK, все 800 peer BEGIN/COMMIT/close успешны. ASan/UBSan запуск всех четырёх вариантов также прошёл.

Воспроизведение (macOS, native compiler/SQLite, без моделей и сети):

```sh
clang -Wall -Wextra -Werror research/migration-commit-51/lock_probe.c \
  -lsqlite3 -lpthread -o /private/tmp/golos51-lock-probe-vfs
python3 research/migration-commit-51/run_probe.py \
  --binary /private/tmp/golos51-lock-probe-vfs --iterations 100 \
  --output-dir /private/tmp/golos51-native-results
```

Контракт согласуется с документацией SQLite: [SHARED/RESERVED/PENDING/EXCLUSIVE](https://www.sqlite.org/lockingv3.html), [COMMIT BUSY при открытом reader и ROLLBACK](https://www.sqlite.org/lang_transaction.html#implicit_versus_explicit_transactions). Эти источники объясняют наблюдаемый механизм; они не заменяют измерение исходного holder.

## Test-only изменение и регрессия

В `EmbeddingMigrationRaceTests.swift`:

- `MigrationReservedLock` освобождает reserved-only транзакцию через ROLLBACK. COMMIT доступен только как явно выбранный отрицательный контроль. При его ошибке сохранён cleanup, error не маскируется успешными snapshot.
- Трасса различает rollback-result, commit-result, cleanup и native lock-state до/после release. Снимаются только фиксированные labels, коды, clocks и случайные UUID; values/SQL/пути не логируются.
- Новый parameterized test держит настоящий SHARED reader на существующей библиотеке: старый COMMIT получает BUSY/PENDING, исправленный ROLLBACK получает OK/NONE, reader остаётся SHARED в обоих вариантах. После cleanup новый writer получает EXCLUSIVE, schema и sentinel прежние.
- Сохраняются actual v0/v2, разные OS executors, SQLite entries до release, delayed peer 2,5 с, positive/negative controls, watchdog, ожидание обеих Task и завершение executors перед teardown.

## Проверки приложения

Targeted: 23 теста / 26 запусков, без ошибок. Обычный и strict stress: по 30 повторов v0/v2, по 60 успешных миграций. Полный make check: 381 passed / 0 failed / 6 gated skipped, 520 passed запусков с параметрами. В полном наборе отмечен ранее наблюдавшийся QoS runtime warning в LocalDocumentExtractorTests; fixture warnings не добавлены.

Счётчики, xcresult и события — в [swift-checks.json](results/swift-checks.json), полные агрегированные события strict stress — в [swift-strict-events.json](results/swift-strict-events.json), полного набора — в [swift-full-events.json](results/swift-full-events.json).

```sh
# 30 повторов обоих actual migration parameters; exact Swift Testing identifier
TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 \
TEST_RUNNER_GOLOS_MEET_MIGRATION_TRACE_DIR=/private/tmp/golos51-strict-traces \
xcodebuild test -scheme golos-meet -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/golos-51-derived \
  '-only-testing:golos-meetTests/EmbeddingMigrationRaceTests/concurrentConnectionsReadSchemaOnlyAfterAcquiringMigrationLock(version:)' \
  -test-iterations 30 CODE_SIGNING_ALLOWED=NO

TEST_RUNNER_GOLOS_MEET_MIGRATION_TRACE_DIR=/private/tmp/golos51-full-traces \
make check DERIVED_DATA=/private/tmp/golos-51-derived
```

Дополнительно выполнены targeted SQLite suites и 30 повторов v0/v2 с обычным pool. Первый сокращённый filter без `(version:)` выбрал 0 тестов и не засчитан. Первый stress с обычными environment prefixes не передал strict flag в macOS test host и учитывается только как обычный pool. В фактическом strict run каждый event подтверждает strictPool=true. Это подтверждение получения флага, не отдельное измерение ширины pool.

Проверки используют только synthetic/temp SQLite и изолированный test host. App UI, настоящие Keychain/записи/ASR/capture/облако и модели не запускались. Код #37 не включён. Перед приёмкой требуется независимое ревью exact SHA; этот отчёт не закрывает #37/#13/#4 и не объявляет готовность продукта.
