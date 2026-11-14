# #58 · Ownership fixtures вопросов и истории памяти

**Актуальное продолжение:** независимое ревью5446d7d выявило P2 повторного принятия fault при nested expectations. Исправление, matched negative probes и новый **красный** full с disk-pressure ограничением — в [P2 report](p2-single-use/README.md). Ниже сохранён исторический author run5446d7d;437/612 не является проверкой исправленного helper и не отменяет независимые OCR failures. Исторический validator сверяет source hashes по frozen5446d7d.

## Результат и границы

Вторая адресная часть #58 переносит удаление `question-service` и `memory-history` на принятый в PR59 scoped teardown. В вопросах cleanup отменяет сессию и освобождает callbacks, которые могли удерживать fixture. В истории прежние assertions защиты неизменяемого журнала сохранены; две намеренные SQLite-ошибки учитываются по точному соединению, фазе, операции и кодам. Production source, lifecycle, schema, busy timeout, retry, время ожидания и параллельность тестов не менялись.

База — accepted preview **`9dfdf8feecf83e94782c0e78acfdd0b2d920a37e`**, PR59 checked `2a5907a79c21f8ad8e394961fa68b9275609c1a3`. GitHub merge, fresh fetch, ancestry и пустой полный tree diff checked59→preview проверены до создания нового managed worktree. Код55 не используется; worktree предыдущей части и чужие checkout сохранены.

Final `make check`: **437 tests / 612 runs, 0 failed / 0 skipped / 0 runtime warnings**. Полный scoped ledger: **153 roots, 246 opens, 246 native close=0, 153 removals**. Все153 JSON attachments экспортированы из настоящего xcresult и побайтно совпали с сохранёнными traces. Это включает принятую часть59, новые55 fixtures и4 control cases.

`assignment-fixture`, `questions-ui`, `knowledge-search` остаются следующей частью: в этом full stdout у них39 vnode-unlink сообщений. #58 целиком не закрывается, PR использует `Refs #58`. Новый success не устанавливает причину исторического metadata-bridge5s timeout или OCR e5rt10/count0.

## Исходные faults разобраны до подключения ledger

Before наблюдал неизменённые assertions двух suites, без переноса cleanup:

| Сценарий | Реальный результат |
|---|---|
| Вопросы: политики/ABA/owners/revision/cancel/fake provider | Ожидаемые доменные ошибки; SQL вспомогательного соединения должен быть успешным |
| История: некорректные drafts, stale lease, budget, cancel | Доменные ошибки/откаты с прежними assertions; не blanket SQLite allowance |
| `invalidBatchRollsBackAllRowsAndImmutableJournalAndPaginationAreReal` — UPDATE | Native `step / update / result19 / extended1811` |
| Та же проверка — DELETE | Native `step / delete / result19 / extended1811` на том же соединении |

1811 — [SQLITE_CONSTRAINT_TRIGGER](https://www.sqlite.org/rescode.html#constraint_trigger), ожидаемый отказ immutable-journal triggers. Обе исходные строки `#expect(throws:ProjectStoreError.self)` и проверка сохранности двух записей оставлены. `validate_evidence.py` дополнительно сравнивает все исходные assertion lines по порядку с accepted base.

`SQLiteFixtureScope.openConnection` возвращает UUID, действительно полученный из `.opened` именно этого connection. Он не угадывает ID по последней глобальной записи. `expectingFailure` рассматривает только события в синхронной проверяемой операции: ровно один fault с указанными UUID/phase/operation/result/extended помечается expected. Raw `.sqlite-failure` и полный diagnostic остаются в trace, Logger продолжает писать stdout. Другая connection, код, фаза, лишний или поздний fault не получают разрешение. Existing schema/rollback assertions не ослаблены; skip/withKnownIssue/подавления stderr нет.

Применение ограничено двумя запрещёнными операциями одного теста истории. По умолчанию scoped ledger по-прежнему считает SQLite failure ошибкой teardown. Другая область теста не получает это ожидание.

## Before → causal control → after

[Скрипт подготовки](prepare_control.py) разворачивает `git archive` зафиксированного accepted9dfdf8f только в новую `/private/tmp` копию. Он добавляет case-scoped observer и отметки root creation/removal, не заменяя SQLite/VFS/error codes. Для raw sqlite3 helper вопросов записывается результат фактического синхронного `sqlite3_close` в существующем defer. Скомпилированные observers и точные patches/hashes — `results/before-*` и `results/retain-*`.

| Запуск | Assertions | Native handles и roots | stdout |
|---|---|---|---|
| Before accepted copy | 22 tests /55 runs Passed | 87 opens,73 observed close; все55 roots удалены при живых handles | question-service32 + memory-history23 vnode diagnostics; две intended19/1811 |
| Retain-root control | 22/55 Passed | те же87 opens/73 observed close,55 roots сохранены до host exit | 0 vnode diagnostics; обе intended19/1811 остались |
| After scoped patch | 22/55 Passed | 87 opens/87 close=0 перед55 removals | 0 vnode/6922; обе intended19/1811 явно expected |

До выхода before host не наблюдались14 закрытий:10 cases `finalTransportGateRejectsChangesAfterConsent` и4 `cancellationAndLateRepliesCannotPublish`. Их spy callbacks захватывают fixture: fixture→spy→closure→fixture. Cleanup теперь очищает `beforeGate` и `afterSend`, а слабый onFinish request страхует error path. Это тестовое управление ресурсами; service.cancel не превращён в новый production shutdown API.

Для **каждого** из55 before roots trace показывает unlink после open, но до native close либо при ненаблюдённом close. Для каждого after root проверено отсутствие живых connections и close-before-remove. Retain-root — только причинный контроль: после завершения host родитель удалил все55 перечисленных каталогов, [receipt](results/retain-parent-cleanup.json) подтверждает отсутствие. В patch нет сохранения всех roots до конца процесса.

Число stdout warning зависит от момента освобождения и нагрузки. Оно не используется как критерий исправления; первичное доказательство — actual handles и порядок событий. Ни один новый6922 в этих selected runs не возникал; отсутствие кода не подменяет before unlink evidence. Старые9+2/14+2 из #56/первой части58 остаются историческими результатами другой нагрузки.

## Meaningful controls

Новые3 test functions /4 runs используют настоящие SQLite и исходные fixture classes:

- Question callback **throw** удерживает fixture, выбрасывает исходную ошибку, cleanup разрывает цикл. После unwinding проверены native close и удаление root.
- Question callback **cancel** удерживает fixture и игнорирует cancellation до gate release. Task отменяется, gate освобождается, Task присоединяется, исходный CancellationError проверен; root удалён после native close.
- History body **throw** сохраняет исходную ошибку после открытия store; scoped cleanup закрывает соединение до unlink.
- **Fault boundary negative control:** два native connections одного и того же файла выполняют тот же запрещённый UPDATE. Во время точного ожидания ошибка чужой connection остаётся unexpected, ошибка указанной connection принимается. Ещё одна ошибка того же owner после операции тоже остаётся unexpected. Журнал содержит исходную запись. После всех native close root удаляется, а `finish()` **обязан выбросить sqliteFailures**, что проверено тестом. Все3 raw faults сохранены:1 expected и2 намеренно не разрешённых.

Поэтому5 scoped raw faults final full — это2 штатных immutable-journal guards плюс3 faults negative control, а не5 необъяснённых отказов приложения. В trace есть3 expected markers;2 оставшихся faults разрешены лишь как **ожидаемый отказ самого negative teardown**, не общим allowance.

## Проверки и остаток

[Счётчики](results/checks.json), [stdout audit](results/stdout-audit.json), [source hashes](results/source-hashes.json), [attachment audit](results/attachment-audit.json) и exact raw case bytes сохранены. Последние упакованы в `<run>-events.json.gz`: gzip содержит JSON map `filename → original UTF-8 text`, что позволяет восстановить исходные bytes и сверить hashes каждого файла. `before/retain` values — JSONL, остальные — JSON arrays. `collect_evidence.py` относится к этому локальному исследованию; его `/private/tmp/golos58qh-*` paths явные, не general runner.

- Before/retain/after: каждый22 tests /55 runs Passed,0 runtime warnings. В retain/after нет vnode messages этих семейств; expected19/1811 сохранены.
- Новые controls:3 tests /4 runs Passed,6 native close=0 и4 удаления. Они не заменяют настоящий app/runtime integration.
- Final `make check DERIVED_DATA=/private/tmp/golos58qh-derived` на accepted9dfdf8f + test-only patch:437 tests /612 runs,0failed/0skipped/0runtimeWarnings. Existing public E5, synthetic settings/menu opts; стандартный ASR E2E исключён.
- Full ledger153 roots/246 close=0/153 removals,0 teardown timeout. Допустимые/отклонённые fault events проверяются отдельно, не объявляются отсутствующими.
- Full stdout:0 extended6922,0 vnode messages question/history. **Остаются39**:assignment-fixture18,questions-ui14,knowledge-search7. Их raw строки сохранены; counts не приписываются изменению production behavior. Эти три семейства не менялись.
- `validate_evidence.py`, все original assertion lines, exact source/observer hashes, local links и `git diff --check` проверены. Application/Rust diff от принятой базы пуст. Нового production close-контракта, timeout/retry/serialization и изменения UI нет.

Перед independent review указан конкретный новый head SHA в PR. Проверка была на текущей macOS/Xcode test host; нового обещания macOS14.4 runtime или cold system нет. Сборки/control процессы не измеряют latency; shared OS cache и сторонняя нагрузка не сбрасывались. Зелёные assertions раньше сосуществовали с unlink diagnostics, поэтому в отчёте они разведены.

## Воспроизведение

Используйте новые paths; не перезаписывайте evidence. Accepted ref before/control закреплён9dfdf8f. Before и retain запускаются последовательно, patch after берётся из проверяемого нового SHA.

```sh
python3 -B research/question-history-fixtures-58/prepare_control.py --output /private/tmp/qh58-before-copy
python3 -B research/question-history-fixtures-58/prepare_control.py --output /private/tmp/qh58-retain-copy --retain-roots
run_qh58_control() {
  TEST_RUNNER_GOLOS_QH58_CONTROL="$2" xcodebuild test \
    -project "$1/golos-meet.xcodeproj" -scheme golos-meet \
    -destination 'platform=macOS' -derivedDataPath "$3" \
    -only-testing:golos-meetTests/KnowledgeQuestionServiceTests \
    -only-testing:golos-meetTests/ProjectMemoryHistoryTests CODE_SIGNING_ALLOWED=NO
}
run_qh58_control /private/tmp/qh58-before-copy /private/tmp/qh58-before-events /private/tmp/qh58-before-derived
run_qh58_control /private/tmp/qh58-retain-copy /private/tmp/qh58-retain-events /private/tmp/qh58-retain-derived
TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE=/private/tmp/qh58-after-events \
TEST_RUNNER_GOLOS_MEET_E5_FOLDER=/tmp/golos-embedding-native/e5-small \
TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 \
make check DERIVED_DATA=/private/tmp/qh58-after-derived
python3 -B research/question-history-fixtures-58/validate_evidence.py
```

После retain test-host exit удалить только перечисленные в `control-root-retained` synthetic question/history roots и проверить отсутствие; это не production способ уборки. В study этот шаг выполнен для всех55. Во время фактических builds использовался уже доступный package cache с `-disableAutomaticPackageResolution -skipPackageUpdates`; точные команды сохранены в gzip logs. Веса не скачивались. Full make check запускает настоящую разрешённую public E5, а генерация в вопросах остаётся fake transport.

Файлы/документы/аудио пользователя, реальные Keychain, live cloud/capture/ASR не использовались. Полные системные logarchives, models/cache/бинарники не включены в git. Следующий шаг — независимое exact-SHA review, затем решение координатора по remaining58. Автор не сливает PR, main/PR8draft неизменны.
