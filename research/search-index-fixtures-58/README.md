# #58: knowledge-search и index-service fixtures

Принятая база `ec77fea89c480eb1d0db7a5cbc2a1ff452d5bc46` (PR64 checked `3561d0cbd81a9a48284274d746b5e1541128d53d`). Перед новым managed worktree выполнены fresh GitHub/fetch/ancestry и empty full diff checked64→preview; main `bd6191c7960ae017e8063795f19e2348cdc35bd9` сохраняется. Unreviewed63/55 не использованы.

**Текущий checkpoint:** targeted Passed; первый full прерван disk guard и НЕ засчитан. Recovery full после достаточного запаса разрешён координатором отдельно, с приоритетом native review63. До его завершения общего full результата нет.

## Причины и actual before/control

Две строки прошлого full64 относились к root `knowledge-search-4F7F6753-077B-4628-89AD-379EEE5ED512` и `index-service-B6F066A9-E388-4DD0-AA9B-F4D29CF995FC`. Старый unscoped stdout не позволяет назвать точный метод этих двух старых instances. Новая before instrumentation связывает **актуальные** case/root/connection UUID/unlink/close; старые UUID не выдаются за новую трассу.

[prepare_control.py](prepare_control.py) создаёт fresh accepted copies. Только test-side observer использует принятый DEBUG native callback; raw sqlite3 helpers тоже отмечают настоящий close result, без изменения их API/FK semantics. [Scope mapping](results/scope-audit.json.gz), exact `*-events.json.gz` (filename→raw UTF-8) и trace hashes.

| Путь | Actual before | Retain-root control |
|---|---|---|
| Search cleanup |Все10 original roots удалены при живом primary handle после indexer.stop|Native handles закрыты до parent cleanup|
| Held search query |После unlink late write получила6922, затем search read тоже6922|Write и query успешны,6922 нет|
| Шесть normal index cases |Close успевал до deferred unlink; это не объясняет старый sporadic warning|Тоже без6922|
| Throwing index body + held worker |Deferred unlink обошёл success-only stop; после release worker получил шесть6922|Worker drained без storage message и6922|

Search cleanup удалял root **внутри живого Fixture**; index-service flat defer опасен при выходе до success-only stop. Это разные entry paths одного ownership/drain дефекта. Один небольшой test-only owner используется обеими suites; общий рефакторинг tests не выполняется.

Before1:18 функций/cases (17 original +search diagnostic probe),17 roots/26 opens/26 close0,11 early unlinks,9 vnode messages и2extended6922 в held probe. Before-index:6 original +1 throw probe,7 roots/8 close0, один early unlink и6extended6922. В обоих before native IDs и порядок сохранены; warning count недетерминирован и не служит критерием.

Retain:19 функций/cases,18 roots/27 native close0,0 vnode/6922. Все18 roots **после host exit удалены** с [receipt](results/retain-parent-cleanup.json). Retain-root — только причинный контроль.

[Search probe](HeldBeforeProbe.swift.txt) и [index probe](IndexHeldBeforeProbe.swift.txt) диагностические. Их Passed означает завершение измерения, **не успешную before SQL-запись**. Нативные faults не скрыты: search result10/extended6922 (beginImmediate и select), index result10/extended6922 (beginImmediate). Index probe сохраняет ожидаемый sentinel тела и фиксирует реальный storageMessage worker. Ни один probe не включён в app test sources PR.

Намеренные удаления transcript-folder/managed-copy файла и замена symlink сохраняются. Они не удаляют SQLite root. Намеренный v3 FTS conflict сохраняет **один** prepare/create/result1/extended1 и assertions на sentinel/user_version3. Только этот существующий asserted fault теперь учитывает accepted async single-use allowance; helper и его границы не менялись.

## Исправление

- Search Fixture/root, primary/reopened stores и direct sqlite3 handles включены в принятый SQLiteFixtureTrait/ledger. Cleanup больше не удаляет root. Явный MainActor у приватного Fixture согласует новые helpers с UI model/test resource owner; suites уже MainActor, общей `.serialized` не добавлено.
- Local index roots принадлежат scope, прежние root-defers убраны. Все создаваемые service/store/restarted store регистрируются; original success-path stop остаётся.
- [SearchIndexFixtureCleanup](../../golos-meetTests/SearchIndexFixtureCleanup.swift) держит gates/joins, но indexers/models/sources — слабо. OnFinish работает на любом выходе: clear model/cancel owned query tasks, release gates, actual stop+waitUntilIdle, join direct queries, затем clear candidate callbacks. Root удаляет только scope после weak-store/native close drain.
- Реальный fake cycle CandidateSource→candidate→load callback→CandidateSource разрывается после остановки worker. Shared LifecycleEncoder/CandidateSource declarations не менялись; новый control делает этот цикл удерживающим native store, чтобы проверить освобождение.
- Original typed Task-result assertions остаются; cleanup join читает тот же result и не выдаёт его за success, не принимает native faults. Reopened/raw SQLite APIs и SQL/FK/busy timeout не заменены.

Шесть controls: search/model и indexer × return/throw/cancel. Тело выходит без end-of-success cleanup. Noncooperative callback/encoder делает настоящую late SQL write; test-owned tail gate удерживает операцию ещё дольше. Пока root существует, reopened handle уже закрыт, primary/model/worker ещё живы. После tail release проверяются return callback, join/stop, освобождение weak refs (включая source/encoder cycle), native close0 и unlink. Исходный sentinel/CancellationError сохранён. Отмена относится к child body task, не отмене parent scope во время teardown.

## Completed targeted

**19 tests/23 runs Passed;0 failed/skipped/expected/runtime warnings.22 roots/37 handles/37 actual close0→22 removals,29 attachments byte-verified.** Семь empty scopes: pure syntax test и шесть внешних scopes у manual lifecycle controls.0 vnode/6922; один intentional FTS fault принят ровно один раз.

Сохранены93 original assertion lines (search60/index33), включая false conditions, SQL и прежние5s/10ms ожидания. Нормализация сравнения касается только spelling reopened constructor. [Source hashes/assertions](results/source-check.json), [checks](results/checks.json), [attachment audit](results/after-attachment-audit.json), [stdout audit](results/stdout-audit.json).

Первая compile-only попытка остановилась до tests на missing MainActor annotation нового Fixture. Логи/receipt/telemetry сохранены как `compile-attempt-*`; после исправления выполнен приведённый completed targeted. Это не runtime failure и не повтор full.

## Первый full — INTERRUPTED, не результат проверки

Запущен `make check DERIVED_DATA=/private/tmp/golos58si-derived`, safe host, existing public E5 `/tmp/golos-embedding-native/e5-small`, synthetic Talk/Menu opts. Реальный ASR исключён стандартным target. Source SHA равны completed targeted.

При снижении global free space ниже6GiB guard послал SIGTERM только собственной process group. Процесс завершился signal15 примерно через14.57s; минимум **6,288,420,864B (~5.86GiB)**. ENOSPC не достигался; причину всего global расхода пространства не приписываем конкретному тесту/процессу. Прогноз только build/cache оказался недостаточным для наблюдённого совокупного пика.

**Completed test counts/full verdict отсутствуют.** Xcode не завершил bundle metadata: summary/tests/attachments export вернули64, diagnostics1. [Export status](results/partial-export-status.json), [исходные ошибки](results/partial-export-errors.json).113 отдельно записанных scope files сохранены как **неполный** raw subset, без вывода о полноте native coverage или остаточных warnings. OCR/bridge outcome этого запуска не устанавливается. Прежние completed red #61/#56 bundles этим не отменяются.

Partial bundle найден как единственный bundle этого собственного DerivedData с mtime после actual run start; stdout не напечатал final bundle path. Он сохранён APFS clone: `/private/tmp/golos58si-preserved-partial-full.xcresult`, [receipt](results/partial-bundle-receipt.json). Сохранены original log, telemetry, source SHA, stop reason и partial env files. Их нельзя выдавать за failed или passed completed full.

После STOP тяжёлые повторы не запускались до нового разрешения/восстановления места. Координатор разрешил recovery после native review63 и достаточного запаса, прежний partial не стирать/не засчитывать. Guard остаётся STOP<6GiB; для recovery требуется отдельный prefix и более консервативный прогноз.

## Общий остаток #58 и воспроизводимость

Targeted отсутствие diagnostics относится только к двум families и controls. Полный остаток stderr текущего diff пока **не проверен завершённым full**. [Read-only inventory](results/readonly-store-inventory.json) содержит25 файлов с ProjectStore constructors,11 со scope trait. Это статическая инвентаризация, не доказательство дефекта или безопасности остальных14 файлов. Они не патчатся; существующие native/migration/fault tests требуют отдельной интерпретации. Закрытие всего58 не заявляется по старым2строкам или новому targeted0.

[validate.py](validate.py) проверяет completed before/control/after, реальные6922, weak/held order, source SHA/assertions, native close/unlink, exact attachments и явный interrupted status. Частичные env bytes проверяются только по SHA, не выдаются за полный audit. Новых моделей/тестов/OCR/сети validator не запускает.

Подготовка копий и probes:

```sh
python3 -B research/search-index-fixtures-58/prepare_control.py --output /private/tmp/search-index-before
python3 -B research/search-index-fixtures-58/prepare_control.py --output /private/tmp/search-index-retain --retain-roots
python3 -B research/search-index-fixtures-58/install_index_probe.py /private/tmp/search-index-before
python3 -B research/search-index-fixtures-58/install_index_probe.py /private/tmp/search-index-retain
```

Actual before1 был выполнен до добавления index probe; before-index выбирает LocalIndexingServiceTests после [installer](install_index_probe.py), retain выбирает обе suites. Actual команды в `*-xcodebuild.log.gz`. [export_results.py](export_results.py) экспортирует completed bundles, [export_partial.py](export_partial.py) отдельно сохраняет доступность partial exports. [run_check.py](run_check.py) сохраняет telemetry каждую секунду, source SHA, отказывается overwrite evidence и проверяет отсутствие xcodebuild. Targeted/full используют одинаковый SourcePackages path через существующий cache, без лишней package-path пересборки.

Очищены только свои завершённые control Build/Index/Module/SDK outputs, с receipts; SourcePackages/Logs/TestResults/xcresults/worktrees/source/evidence сохранены. Координатор отдельно восстановил запас из completed outputs; это не cache workaround OCR. Текущий active DerivedData/runtime сохранён.

Только synthetic/temp/fake, no realdata/Keychain/cloud/captureASR/newweights. Production/Rust/helper diff пустой, UI не менялся/не запускался,63/55 не импортированы. Самопроверка автора не заменяет independent exact review. PR — Refs#58, не закрытие58; main/PR8draft/55 не менялись, автор не сливает.
