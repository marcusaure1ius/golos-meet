# #37 · Recovery интеграции панели памяти, PR #55

Один final `make check` на source **`74dbf7e8aa0031faf709f76ff738a850a23fb940`** завершился **Passed: 478 тестов / 676 запусков**. Предшествующий meaningful targeted — **54/67 Passed**. Новый source и отчёт подготовлены в отдельном managed worktree `37-panel-integration-recovery`, ветка `codex/37-panel-integration-recovery`; remote PR #55 пока остаётся на замороженном `50e22e00504ec2f87628464c9ed68fa8c4bb09e7`. Перед первым обновлением remote требуется fresh head guard координатора; force push и новый panel PR не используются.

Это продолжение той же feature #37. Independent review нового exact head ещё требуется. Автор не сливает PR, #37/#5 не закрывает. Main и draft PR #8 не менялись.

## Основа и изменения

Accepted preview при начале recovery — `e9990685bdcf334039cbce7edbfb245750b0154a` с принятыми #63/#65. Замороженный feature55 включён обычным merge `2d70f874b674ce27cc2266ba881886af6348a178`. Единственный конфликт в `ProjectMemoryQueueTests` разрешён сохранением принятого rich session #63 целиком; старый catch55 не заменяет новую диагностику. Его bytes совпадают с accepted source.

После независимой приёмки audit66 новый accepted preview **`23b1da158304a2c0c596752d9150e489b1884fb4`** включён обычным merge `f52b3ad1deb49637cb7c11d7d0450ccc8c7bac7f`. Его production/test/Rust code-equivalent e999; повтор ради docs не запускался. Критерии #58 приняты координатором отдельно; это не закрытие OCR56/bridge61/панели.

Поведение frozen55 — overview/history/manual journal/queue/consent/read-store и scoped panel fixtures — сохранено. Дополнительный узкий source для проверяемой навигации:

- `ProjectMemoryOpenButton` и `projectMemoryInspector` переиспользуют существующие подписи, GhostButton, accessibility IDs и ширины380/460/600 в production и safe host.
- `projectMemoryRoute` содержит тот же conditional project route, который теперь вызывается из `MeetingsScreen`; back по-прежнему сбрасывает `showingMemory`.
- `ProjectMemoryEntry` выделен из production factory. Его load/start/onDisappear-close код сохранён, провайдер модели можно передать явно в safe composition. Обычный initializer остаётся в `ProductionMemoryPanel.swift` и передаёт **ту же guarded factory**. Весь её исходный блок побайтово равен frozen55: `guard !AppRuntime.isTestHost` до real shared store/settings/queue/Keychain не ослаблялся.
- Safe host собирает actual entry, navigation helpers и panel/model/service/worker, получает temp SQLite и fake client через explicit DI. Production factory, AppDelegate, OpenRouterClient, Keychain, Recorder, ASR и player не входят в его allowlist. `--resume-library` ограничен stopped task-owned temp root и позволяет продолжать ту же synthetic библиотеку; выполненные сценарии не переигрывались после нужного rebuild.

[Source audit](results/integration-source-audit.json), [четыре UI пути, изменённые после targeted](results/source-after-targeted.json). Worker/service/tests после targeted не менялись; final full и final safe DI host проверяют последнюю entry/navigation адаптацию.

## Проверки

| Проверка | Фактический результат |
|---|---|
| Targeted: panel, queue, bridge diagnostics/overflow, host isolation | **54 tests / 67 runs Passed**,0 failures/skips/expected/runtime warnings |
| Final full на74dbf7e | **478 tests =474 ordinary passed +4 expected tests**; **676 runs =664 passed +12 expected**; failed/skipped/runtime warnings0 |
| E5/settings/menu/panel opt-ins | Включены явно; фактические результаты в exported test tree |
| Полный native ledger | **458 opens / 458 native close0 перед 281 root removal**,293 scopes,0 lifecycle violations/teardown timeouts |
| Exact trace attachments | **304/304**:293 scope +11 bridge files; missing/mismatch0 |
| Targeted lifecycle |100 close0→62 removals,66 scopes/77 exact trace attachments |
| OCR full |41 invocations /82 input-result attachments, SHA/bytes verified;40 extract-returned +1 предусмотренный invalidDocument |
| Panel native renders |**44 PNG +4 manifests**, все exact bytes/member hashes сохранены; selected partial-consent-light и conflicts-claims-dark просмотрены |
| Первый safe host |Build Passed наe2ba5b5, source/binary receipt отдельно сохранён |
| Final entry/route safe host |Build Passed на74dbf7e; binary SHA256 `79e853f465e46db7561e7b64a55565b07a8b0cb75f0b091f410dbf58a4bd3027`,59 allowlisted files |
| Final full disk guard |40 samples; preflight95680262144B (~89.11GiB), minimum92470943744B (~86.12GiB), reserve6GiB/forecast3GiB; STOP не сработал |
| Process |Final make exit0,38.284s; повторного full не было |
| Offline evidence validator / git diff --check |Passed; validator не запускает tests/OCR/UI/inference |

Пять файлов public `intfloat/multilingual-e5-small` проверены по SHA/размеру и двум accepted manifests перед full; revision `fd1525a9fd15316a2d503bf26ab031a61d056e98`. Новых weights/version/downloads нет. Штатный full использует ONNX E5; panel fixtures/host — synthetic2D/fake transport. Настоящий ASR E2E исключён стандартной целью.

Whole bundles:

- `/private/tmp/golos37recovery-preserved-targeted.xcresult`
- `/private/tmp/golos37recovery-preserved-full.xcresult`

APFS clones проверены по размеру/SHA каждого файла. Summary/tests/diagnostics/attachments exports exit0. Receipts, raw archives и file hashes доступны в [results](results).

## Actual interactive: выполнено и границы

Человек уже разрешил isolated UI и подтвердил unlock. После прерывания восстановлен только потерянный JS-binding; это не product finding. Открывался исключительно task-owned `Golos Memory Panel Preview.app`, реальное рабочее приложение не использовалось.

| Сценарий | Наблюдение / граница |
|---|---|
| 25 chunks / отдельное согласие |Actual UI показал12 raw +2 derived, затем12 raw, затем1 raw. Три явных send дали12/25→24/25→25/25 и3 fake calls. Автоматической следующей отправки не было. Первый checkpoint durable cursor12/total25 сохранён; последующие переходы подтверждены CUA и тремя exact payloads. |
| Manual retraction |Обязательная причина→preview с2 source refs→explicit commit→append-only history. Фильтр нашёл новую запись. После изменения памяти queue generation пересчитан/cursor0; это отдельный переход, не подмена предыдущего25/25 checkpoint. |
| Project change при preview |СменаNorth→Private сбросила preview, показала localOnly deny; fakeCalls остались3. ВозвратNorth потребовал новое согласие. |
| Source change при held response |Call4 удержан после согласия; изменён current transcript, gate released. Events до/после полностью равны30, current вернулсяneedsConsent, старый ответ не опубликован. |
| Project change при held response |Call5: events остались30, но durable state показал **30s timeout**. Не засчитывается как доказательство отмены именно project change; причина/порядок до timeout не восстановлены. Deadline не увеличивался. |
| History pagination/filter |Новый отдельный source дал ещё24 событий через2 согласия, всего 54. Первая страница ограничена50; «Более ранние» показал4 исходных события. Фильтр ограничен текущей страницей; очистка показала реальные старые IDs. |
| Physical-source stale correction |Попытка отменить исторический seed после изменения его raw file была отклонена stale guard, без публикации. Не называется успешным recovery. |
| Logical stale intermediate |ЧерезUI отозван свежийnew-1 / часть 19; производныйnew-2 / часть 1 сталstale. Provenance показал retired ancestor и related change. Явная отменаmiddle через preview сохранила25raw refs и добавила новое событие. Всего56events, исходные30побайтово сохранены. **Полное повторное rawqueue completion этого interactive примера не заявляется**; отдельный accepted native test полного recoveryPassed в targeted/full. |
| Actual project route + entry |Final safe DI: кнопка«Память»→общий conditional route→actual ProjectMemoryEntry/ProjectMemoryPanel→«К проекту» вернул исходную composition. |
| Actual meeting inspector + entry |Общаякнопка→shared inspector→actualentry сmeetingIDcurrent; North выбран из назначения встречи; toggleзакрылпанель. Explicit factory trace содержит оба набора аргументов. Порядок callbacks не приписывается click chronology: action clock не записан. |
| Factory / normal environment |Default production factory побайтово сохранена и host-isolation testPassed. Исполнен explicitsyntheticprovider. **Полная runtime-композиция MeetingsScreen/MeetingDetail с normal singletons не запускалась**; её wiring проверено source/build. |
| Width/theme/noaudio |Фактический inspector около460pt при окне 1100 pt; светлая/тёмная темы просмотрены. Два drag не изменилиAX/layout; **actual380/600extrema не подтверждены**. Контракт ширины 380/460/600 сохранён. Audio/player/recording/ASR отсутствуют в allowlist. |

[UI receipts](results/ui) сохраняют raw read-only memory tables, exact fake payload trace, hashes и author notes об actual CUA действиях. Notes не выдаются за machine-captured AX dump. Снимки actual окна присутствуют в CUA rollout этого чата; committed44PNG — отдельные native test renders, не screenshots interactive последовательности. После необходимого rebuild task-owned library продолжена; UI fake counter нового процесса0, cumulative raw trace содержит прежние7calls. Новыхtransportattempts при route checks не было.

Ранее выполненные04 PDFpage2/sourcejump/42–55s/manualcorrection/consent/error/empty/private/lightdark остаются историческими проверками frozen host. Они не переименованы в actual проверки новой binary. Текущий full заново проверяет corresponding model/native render states; это отдельный вид evidence.

## Raw diagnostics и старые результаты

Global stdout full: **69 SQLite failure lines,6 e5rt lines,0 vnode-unlink/extended6922**. Построчная карта сохраняет49 exact native scope matches (31 single-use accepted faults,18 negative guard faults),20 без сохранённой привязки к тесту. В scopes rollback0; один global rollback result1 вне scoped traces сохранён без выдуманной UUID→test связи. e5rt указывает на System TextRecognition, не embeddingONNX; harmlessness/корневая причина не заявляются. Xcode compiler actor-isolation warnings также остаются в raw log; runtimeWarnings=0 не означает build warnings=0.

Все4 bridge failure reports принадлежат предусмотренным passing diagnostic controls; actual summary.testFailures пуст. Пределы bounded raw timeline/non-atomic snapshots сохранены. Native ledger доказывает только зарегистрированные resources этого workload; child cancel не отмену parent scope или process death,8s pending wait начинается после cleanup requests.

Старые full55/OCR/bridge red, interrupted65 и accepted66 evidence сохранены в своих каталогах/commits, их причины не отменяются текущим Passed. #56/#61 остаются открыты. Source04/worktree04 frozen и не редактировались; PR66head не менялся ради панели.

## Воспроизведение аудита без новых runtime вызовов

```sh
python3 -B research/panel-integration-recovery-37/validate.py
```

Validator перечитывает hashes/archives, пересчитывает opens/closes/unlinks/allowance cardinality, проверяет raw OCR bytes, реальные opted-in test results, UI payload fragments12/12/1, append-only journal и source на checked commits. Initial offline validator предполагал chronological order двух factory callbacks; actual trace имеет другой порядок. Проверка исправлена на множество фактических аргументов, trace сохранён, runtime не повторялся и source не менялся.

Следующий шаг: подготовленный report commit→root fresh guard remote55head==frozen50e22→обычный fast-forward push в существующую `codex/37-project-memory-panel`→independent delta-review exact новогоhead. До guard remote не обновлять, новыйpanel PR не создавать. Авторская передача не объявляет оставшиеся UI границы пройденными и не закрывает37/5.
