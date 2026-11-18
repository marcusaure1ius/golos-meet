# #58 · Итоговая проверка принятых SQLite fixture-компонентов

Один общий `make check` на принятой комбинации #63 + #65 завершился **Passed**: **459 тестов / 656 запусков**, без неожиданных failures, skips и runtime warnings. Все наблюдавшиеся **436 native close вернули 0 до удаления 261 root**. Этот PR добавляет только отчёт, сохранённые synthetic evidence и скрипты их проверки. Application, Rust, Swift-тесты, helper, assertions, skip rules и timeouts относительно принятой базы не меняются.

Это author audit для независимого exact-SHA review. #58 не закрывается этим отчётом автоматически. Historical bridge #61 и OCR #56 failures остаются сохранёнными; причина их отсутствия в новом запуске не установлена. Приёмка панели #55 и всего продукта не заявляется.

## Проверенная основа и метод

- Branch: `codex/58-integrated-fixture-audit`, отдельный managed worktree.
- Accepted preview и фактический HEAD полного запуска: **`e9990685bdcf334039cbce7edbfb245750b0154a`**.
- Полное дерево source/check: **`4284d8f240fd40d2abdd2efbd4968973a0d12df0`**.
- Checked #63 `9134715492c4f02664d5160ed4576e84173bfeab` и #65 `dcdbf7aca8c98c637c6e1650141d258df55e9210` — ancestors базы. GitHub merged/head/merge refs и fresh fetch сверены перед запуском: [provenance](results/accepted-provenance.json), [GitHub receipt](results/github-preflight.json).
- Команда: `make check DERIVED_DATA=/private/tmp/golos58integrated-derived`. Штатная цель исключает настоящий `PipelineE2ETests`; остальные условия не ослаблялись.
- Safe host, synthetic/temp/fake transport; явно включены public E5, Talk settings renders и native menu. [Фактические test-tree результаты](results/required-path-tests.json) подтверждают их исполнение, original-ready-event и diagnostic/overflow controls.
- Public `intfloat/multilingual-e5-small`, revision `fd1525a9fd15316a2d503bf26ab031a61d056e98`: проверены **5/5 SHA256 и размеров**, всего **487352505 B**, одновременно по accepted Swift manifest и JSON. [Локальный preflight](results/model-preflight.json) с hash receipt координатора. Новых загрузок/версий/моделей нет. Preflight не запускает inference; inference выполняют штатные opted-in tests.
- Собственный DerivedData получил APFS clone существующего SourcePackages. Общий cache не редактировался. C1 слот был явно освобождён координатором; preflight не нашёл другого xcodebuild. C1 остановлен INCONCLUSIVE до runtime; его гипотеза не засчитана результатом этого full.

## Критерии issue #58 → принятые компоненты

Все ссылки ниже ведут на уже принятый source/evidence. Новых before/control тестов в этом audit нет. Checked SHA каждого PR, merge SHA, roots и suites сохранены в provenance. Проверяются **10 root prefixes / 11 suites**; цифры разных запусков не суммируются.

| Принятый PR | Root prefixes / suites | Что установлено ранее и проверяется совместно |
|---|---|---|
| [#59](https://github.com/marcusaure1ius/golos-meet/pull/59), checked `2a5907a` | `memory-update` — ProjectMemoryUpdateTests, ProjectMemoryQueueTests; `index-hooks` — IndexingProductionHooksTests; `assignment-runtime` — MeetingAssignmentRuntimeTests; `native-index-queue` — LocalIndexingNativeTests | Root переживает store/jobs, stop/drain и callback release. Actual before/control сохранил 6922/rollback; retain-roots был причинным контролем с последующим удалением, не исправлением. [Отчёт](../fixture-lifecycle-58/README.md). |
| [#60](https://github.com/marcusaure1ius/golos-meet/pull/60), checked `ceeb98b` | `question-service` — KnowledgeQuestionServiceTests; `memory-history` — ProjectMemoryHistoryTests | Cleanup questions/history, exact single-use fault allowance; nested expectation не принимает один fault дважды. SQL assertion/body error/closeBUSY canaries не скрываются. [Отчёт](../question-history-fixtures-58/README.md). |
| [#62](https://github.com/marcusaure1ius/golos-meet/pull/62), checked `c9831bc` | `assignment-fixture` — MeetingAssignmentTests | Before 23 ранних unlink при живых handles; after store/reopened-store ownership, indexer stop/join и native close. Один async migration fault привязан к фактическому новому connection. [Отчёт](../assignment-fixtures-58/README.md). |
| [#64](https://github.com/marcusaure1ius/golos-meet/pull/64), checked `3561d0c` | `questions-ui` — KnowledgeQuestionModelTests | Held query/response × return/throw/cancel, callbacks и weak owners завершаются до unlink. Before реальная late SQL после unlink дала 6922; retain control и after сохранены. [Отчёт](../question-ui-fixtures-58/README.md). |
| [#65](https://github.com/marcusaure1ius/golos-meet/pull/65), checked `dcdbf7a` | `knowledge-search` — KnowledgeSearchTests; `index-service` — LocalIndexingServiceTests | Held search before: 2 ошибки6922; throwing index before: 6 ошибок6922. Retain control дал успешную late write/query и drain; after шесть held paths, weak release/callback-cycle cleanup и actual close-before-unlink. 93 исходных assertions сохранены. [Отчёт](../search-index-fixtures-58/README.md). |

1. **Причина раннего unlink сопоставлена с resource path.** Каждый компонент содержит свой before/control/after. Старым sporadic UUID не приписывается конкретный тест без исходной instrumentation. Связь с OCR не объявляется установленной.
2. **Live handles / task drain / очистка проверены.** Текущий общий workload содержит все 10 prefixes, native ledger без нарушений, stdout0 vnode/6922. Intentional fault boundaries сохранены. Global rollback result1 отдельно разобран ниже: абсолютного отсутствия rollback diagnostics в stderr не заявляется.
3. **Unlink происходит после освобождения зарегистрированных ресурсов.** Ни одного native close!=0, незакрытого зарегистрированного handle, early unlink или teardown-timeout в записанных scopes. Roots реально удалены; retain-all-roots не используется. Это наблюдаемый workload, не гарантия всех будущих interleavings или всех объектов репозитория.
4. **Общий make check и native controls пройдены.** Новый accepted-combined результат Passed, raw bytes/stdout сохранены. Предыдущие red и interrupted остаются отдельными историческими результатами.
5. **PR / independent exact review / root merge.** Компоненты уже приняты, этот новый docs/evidence PR ещё требует собственного независимого ревью exact SHA и решения root. Author self-audit не заменяет его.

Machine-readable [criteria mapping](results/criteria-mapping.json) оставляет критерий5 pending.

## Фактический результат одного общего запуска

| Проверка | Результат |
|---|---|
| Full summary | **Passed**, 459 total tests = 455 ordinary passed + 4 tests с expected negative outcomes |
| Parameterized runs | **656** = 644 ordinary passed + 12 expected negatives; failed/skipped0 |
| Runtime warnings / actual test failures | 0 / 0 |
| Native scopes | 271 записанных scope; 261 с одним root, 10 без root; 436 opens / 436 close0 / 261 root removals |
| Lifecycle audit | 0 duplicate-open/bad-close/live-at-unlink/unclosed/root-mismatch/teardown-timeout; все expected fault acknowledgements single-use |
| Scope/bridge attachment bytes | **282/282** exact: 271 scope + 11 bridge files, missing/mismatch0 |
| OCR attachments | **41 invocations / 82 input-result attachments**; input SHA/bytes совпали; 40 extract-returned + 1 предусмотренный invalidDocument extract-threw |
| Whole bundle | APFS clone; размер и SHA каждого файла original/preserved сверены; summary/tests/diagnostics/attachments exports exit0 |
| Disk | 59 samples; preflight **94959124480 B** (~88.44GiB), minimum **93302865920 B** (~86.89GiB); глобальное снижение от preflight **1656258560 B**, не приписывается целиком одному процессу |
| Guard | Forecast3GiB сверх reserve6GiB, проверка раз в секунду, STOP<6GiB не сработал |
| Process | make exit0, elapsed57.415s, без повторного full |

Текущий [family ledger](results/family-ledger.json), все значения только этого запуска:

| Root prefix | Roots / removals | Opens / close0 |
|---|---:|---:|
| memory-update | 81 / 81 | 138 / 138 |
| index-hooks | 3 / 3 | 2 / 2 |
| assignment-runtime | 13 / 13 | 15 / 15 |
| native-index-queue | 1 / 1 | 2 / 2 |
| question-service | 34 / 34 | 39 / 39 |
| memory-history | 25 / 25 | 54 / 54 |
| assignment-fixture | 25 / 25 | 44 / 44 |
| questions-ui | 22 / 22 | 29 / 29 |
| knowledge-search | 13 / 13 | 24 / 24 |
| index-service | 9 / 9 | 13 / 13 |
| Отдельные fault/lifecycle controls: fault-expectation, assignment-fault, fixture-lifecycle | 35 / 35 | 76 / 76 |
| **Всего наблюдалось** | **261 / 261** | **436 / 436** |

Root может быть зарегистрирован без открытия DB (`index-hooks`), поэтому roots и connection counts не обязаны совпадать.

## Raw stderr и diagnostic controls

Passed и runtimeWarnings0 не означают пустой stderr. [Построчная карта](results/stdout-line-map.json.gz) хранит каждую исходную строку с номером, parsed diagnostic и имеющейся identity attribution; [полный stdout](results/stdout.txt.gz) сохранён без фильтров.

- **69 SQLite failure lines.** Ровно49 сопоставлены с native scope event по полному diagnostic и connection identity. Из49 native faults31 приняты точными single-use allowances; остальные18 принадлежат guard/negative cases, проверяющим непринятие foreign/late/extra/wrong-phase/operation/code. Сырые events и проверки отказа сохранены, не превращены в новые allowances.
- **20 строк не имеют registered scope match.** Их UUID не приписываются конкретному тесту по соседству параллельного stdout. Они сохранены как unattributed, даже при Passed full. Этот audit не добавляет глобальное подавление или acceptance для них.
- **0 vnode unlinked / 0 extended6922** в сохранённом global stdout.
- **1 global rollback result1**, вне зарегистрированных scope events; в scope faults rollback0. Existing `ProjectDatabaseDiagnosticsTests.commitErrorSurvivesFailedCleanupAndConnectionRemainsUsable` намеренно заканчивает transaction, затем wrapper COMMIT и cleanup ROLLBACK должны отказать; этот тест Passed. Это source context, а не доказанная UUID→test привязка конкретной stderr строки: такой receipt у unscoped case не записывался. Исторические unlink-associated rollback не объявляются исправленными по этой строке или исчезнувшими из всего stderr.
- **3 e5rt lines** указывают на System TextRecognition `.mlmodelc.bundle` (td/orientation/latincyrillic), не на `/tmp/golos-embedding-native/e5-small`. В них нет OCR invocation ID, поэтому точная per-input attribution неизвестна. Успешный OCR workload этого full не доказывает безвредность этих строк и не отменяет прежние e5rt10/13/mixedPDF failures #56.

[Bridge audit](results/bridge-audit.json.gz) содержит все7 timelines и4 raw failure reports с SHA. Original-ready-event и controlled-owner-release/direct-restart в новом full Passed, dropped0. Четыре failure-report созданы предусмотренными контролями: startup-pause/ready-source coverage (dropped0), overflow held ACK (657 dropped в failure capture), controlled body throw/cancel (35 dropped в каждом capture). Более поздние timelines отдельно показывают truncation: 690/45/45 dropped. Это намеренное исполнение failure recorder и bounded-overflow контрактов в прошедших тестах. Они не выдаются за настоящие full test failures; `summary.testFailures=[]`. Поля capture неатомарные, до unwind; новые данные не подставляются в старые red bundles.

## История и пределы вывода

[PR65 evidence](../search-index-fixtures-58/README.md) остаётся на своей accepted-baseec77fea серии: early diskSTOP partial без completed counts и отдельный completed red recovery453/649 с одним bridge failure. [PR63 evidence](../memory-bridge-61/README.md) остаётся отдельным red457/650 с двумя coverage failures dropped0. Ни один из этих исходов не переименован в нынешний Passed459/656 и не заменён этим bundle. Старые сохранённые `/tmp` paths в их receipts являются историческими: после внешнего изменения доступной FS наличие тех bundles сейчас не утверждается. Committed raw evidence остаётся в git.

Этот audit проверяет registered stores/reopened/raw connections, owned tasks и конкретные callbacks. Child-body cancellation controls не доказывают parent-scope cancellation или process death. В helper восьмисекундный pending deadline начинается **после** выполнения cleanup requests; это не верхняя граница всего finish. Отсутствие SuiteTrait у иных test files не доказывает их небезопасность: существуют ручные scopes/standalone observers. Не вводилась новая production shutdown/schema/retry/lifecycle семантика.

Текущий whole bundle: `/private/tmp/golos58integrated-preserved-full.xcresult`; [receipt](results/bundle-receipt.json) содержит original path и все file hashes. Raw `scopes.tar.gz`, `bridge.tar.gz`, `attachments.tar.gz` хранят exact bytes, manifest→test mapping и OCR input/result. [Archive member hashes](results/archive-members.json.gz), [source/run receipt](results/run-receipt.json), [checks](results/checks.json), [artifact hashes](results/artifact-sha256.json).

## Проверка сохранённого отчёта

```sh
python3 -B research/integrated-fixture-audit-58/validate.py
```

Validator перечитывает все архивы, проверяет hashes/exact attachment bytes, пересчитывает close-before-unlink и single-use acceptance, сверяет source с принятой базой, реальные opted-in test results, summary и disk guard. Он не запускает tests/OCR/inference и не скачивает weights. Author validation Passed.

`prepare.py`/`verify_model.py`/`run_check.py` — точные инструменты уже выполненной подготовки; runner намеренно запрещает перезапись существующего run и не является командой повторить full. `export_results.py` только экспортирует завершённый результат; `collect.py`, `map_stdout.py`, `finalize.py` работают с имеющимися bytes. Для этого audit новых runtime проверок не требуется.

Следующий шаг: независимое exact-SHA review этого PR, затем root решает соответствие всем критериям и закрытие #58. #56/#61/#37/#5 не закрываются по одному успешному combined full. Main `bd6191c7960ae017e8063795f19e2348cdc35bd9` и draft PR #8 не менялись; автор PR не сливает.
