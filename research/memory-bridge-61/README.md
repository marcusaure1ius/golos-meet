# #61 · Наблюдение готовности и владельцев очереди памяти

Результат — диагностический test contract и управляемые controls, а не исправление установленного production-дефекта. Причина старого ready-source timeout и эпизодов OCR остаётся неизвестной. Новый успешный full не доказывает их исправление.

**Текущая комбинация после принятого PR62: full FAILED, 2 coverage timeouts.** Reviewable diagnostic contract не означает прохождения mandatory full. Последние исходники `e38a65a09adb1a335578ec5fa71dff073d773aa0`; [final-after62/checks](results/final-after62/checks.json). Изменения после него — только evidence/отчёт.

## Основа и границы

Отдельные managed worktree `61-memory-bridge-test-diagnostics` и ветка `codex/61-memory-bridge-test-diagnostics` созданы после fetch от принятого `fc2a92956fd50bd791e4926d5b388c8fe39f84d4`. GitHub подтвердил merged PR60 checked `ceeb98b5dd1c39dc774c810c82e834ae38fdfc72`; ancestry и пустой полный tree diff checked→preview проверены. Панель55 не включена в основу. Её worktree/head `50e22e00504ec2f87628464c9ed68fa8c4bb09e7`, safehost и evidence не изменялись.

Пока шла реализация, target preview продвинулся до `7be254c4a1eceb28755ad60d718a4ed72cb21179` через merged test-only PR62 checked `c9831bc4e15aecd42f95f11454e1b19f34a9ae63`. Fresh API/ancestry/empty full tree diff проверены. По явной команде координатора эта основа включена обычным merge `b8d44a2e8aa0342158f3ccaae043cae1804862c5`, без конфликтов. Production/Rust diff fc2→7be пустой; shared SQLiteFixtureScope/tests обновились. Прежний passed full наfc2 сохранён отдельно; выполнены combined checks, результаты ниже. Дальнейшие непринятые #58 ветки не включались.

`AGENTS.md`, `CLAUDE.md`, этап4 `DEVELOPMENT_PLAN.md`, issues61/37/5 и навыки golos-task/review прочитаны. Agent Board не используется. Main/PR8draft не изменялись; автор PR не сливает. Следующие fixture58 партии не включались.

Production control flow/policies/CAS/stop/timeouts не меняются. Изменения в worker и bridge обёрнуты в DEBUG; новый observer также целиком DEBUG. В Release нет observation/gate API. Единственный controlled gate — DEBUG-only опциональный per-instance hook между `changed()` и прежним guard перед `start()`, nil по умолчанию. Нет глобальной startup barrier или ожидания готовности в runtime.

## Какие данные были до изменения

[Before](results/before) сохраняет независимую передачу read-only: exact diagnosis, historical audit, result, source receipt и standalone diagnostic driver/copies. Их instrumentation/gates — локальные диагностические копии accepted source, не код принятого production и не реализация этого PR.

Старый failed full60 содержал ровно один bridge attachment:9scope events, initial snapshot marker, затем ready-source timeout, native close0 и unlink. Не было calls/worker/durable/config/weak snapshots. Rich catch панели55 в том эпизоде не выполнялся и не подставляется ретроспективно. У более раннего55/after57 stage вообще неизвестна. Нового confirmed P1/P2 или historical root cause независимая диагностика не установила.

До реализации были обозначены controls и критерии: (1) пауза после changed до start должна отделить revision от readiness; (2) явный отпуск sole owner должен дать weak nil/deinit/stop и отсутствие доставки, затем direct restart должен восстановить работу. Standalone before-контроли это подтвердили, но их generic trace ещё не имел всех owner IDs. Новый контракт делает эти состояния наблюдаемыми на фактических класcах приложения.

## Наблюдение и смысл IDs

`MemoryQueueDiagnostics.Event` содержит owner kind/UUID, stage, monotonic uptime и только метаданные. Каждый worker/bridge сохраняет observer своего создания, а не берёт текущий TaskLocal при каждом событии. Поэтому поздний deinit-stop старого объекта не относится к следующему case. Configuration requests имеют отдельные UUID; worker records связывают instance, run, attempt, job generation, cycle, sequence и count. Lease identity задаётся этим набором; transport invocation имеет свой UUID и ссылку на actual active worker fields.

Timeline покрывает event receipt до main-actor hop и последующий main hop, config changed/start begin/return, discovery, claim, active attempt, injected transport enter/return и service publication/unchanged/insufficient return. Возврат `worker.start()` обозначен именно как возврат с observed run/started fields, а не как полная готовность всей очереди. Revision>0 по-прежнему только initial snapshot fence. Durable runtime generation уже существует после миграции; сама по себе она также не подтверждает startup.

Observer nil не вызывает построение больших snapshot dictionaries. Запись ограничена4096 rows; число отброшенных rows сохраняется, не скрывается. Physical enter/return означает вызов внедрённого ChatCompleter, **не живой HTTP**; отдельно сохраняется fakeCalls, чтобы не смешать вход в adapter с прохождением beforeSending guard. У return-event timestamp относится к возврату, а fields сохраняют binding snapshot входа (run/attempt), не повторный snapshot состояния при возврате.

## Failure recorder

Конкретный `concreteMetadataBridgeReceivesReadyEventWithoutLaunchingApplication` использует общий диагностический session helper. Strong owner сохраняется до необходимого завершения lifecycle и проверки weak-liveness. Исходный initial-snapshot fence, ready-source completeCoverage и fake calls==1 сохранены. Оба ожидания имеют прежний5s deadline; ни OCR/bridge failures, ни исходные assertions не помечались known/expected/skip.

При отказе **до unwind/cleanup** сохраняются:

- phase/error/elapsed/case/bridge/worker/transport IDs и timeline;
- actual weak bridge liveness, текущая конфигурация и ID возврата startup;
- worker run/attempt/lease/flags/revision;
- physical entered/returned/inFlight/maxPhysical и fakeCalls;
- bounded durable SQL rows (run/generation/attempt/cursor/total/state/cycle/model), до256 с overflow flag.

У каждого condition read есть begin/return либо error marker с phase/iteration. У collector reads есть отдельные begin/end timestamps; SQL read также отмечен как awaited. Worker/bridge/physical/SQLite readings — **неатомарная последовательность**. Их значения могут измениться между observations; `atomic=false` явно записан в report. Failure read не резервирует lease и не меняет поколения/политики. Внутренние framework/file awaits discovery представлены интервалом discovery; индивидуальная задержка каждого системного вызова этим контрактом не доказывается.

Оригинальная ошибка повторно выбрасывается после записи и cleanup. Ошибка сохранения evidence не выдаётся за отсутствие исходного отказа. Scope onFinish имеет независимые weak owner captures и release gate; нет вечного удержания roots или force-close. Завершение child cancellation не отменяет весь родительский test scope.

## Actual controls на новом коде

Использованы настоящие temp ProjectStore/SQLite/history/service/worker/bridge и NotificationCenter, injected ChatCompleter wrapper + spy и supplied2D vectors. Нет OCR/inference внутри этих контролей.

1. **Paused startup + controlled failure.** Hook остановлен после changed. Actual snapshot: revision1, startedfalse, worker run пуст, start-return event отсутствует. Готовый synthetic source/event принят, durable queued, physical/fake calls0. Gate намеренно удержан во время настоящего5s ready-coverage ожидания; общий recorder действительно записал failure и бросил busy. Тест проверил phase, timestamps/read pairs, beforeUnwind/non-atomic flags, owner attribution, config IDs, queued state и отсутствие lease/call. После release — start return, новый lease/attempt,1 physical enter/return,1fake call и inserted publication/completed.
2. **Sole owner release.** После actual startup return/idle отпущен единственный bridge owner. Под чужим TaskLocal observer появились weaknil/deinit/stop у исходных IDs, чужой trace остался пустым. Ready event не доставлен,0calls/durable jobs пусты. Explicit direct worker restart с новым run восстановил1call/completed. Это намеренный контроль, не доказательство неожиданного deinit старого эпизода.
3. **Error/cancel cleanup (2 параметра).** Тело держит startup gate, затем выходит intentional error либо настоящей cancellation child task. Reporter выполняется до cleanup; исходный outcome сохранён, bridge weaknil после cleanup, gate освобождён. Native scope закрывает connection до unlink.

В full controlled coverage failure записан через5.360s после начала именно ожидания; case elapsed8.864s включает подготовку/другие действия.5s deadline не расширялся: возобновление actor после deadline зависит от scheduler. Это измерение конкретного запуска, не универсальная задержка и не диагноз historical timeout.

## Последняя интеграция и фактические отказы

| Проверка после62 | Результат |
|---|---|
| Targeted после исправления control assertion |29tests/41runs Passed,0fail/skips/runtimeWarnings |
| Первый combined full, source b8d44a2 |Failed: total452,446ordinary passed +4reported expected +2failed;626passed runs +12expected +2failed;0skips/runtimeWarnings |
| Final combined full, source e38a65a |**Failed с теми же counts**, исходный ready-source timeout и новый direct restart coverage timeout; control publication assertion прошёл |
| Native lifecycle selected5cases final |5roots/5native close0/5unlink, close до удаления,0scope errors |
| Final attachments |309,227scope/bridge byte matches,41OCR input hash/bytes verified |
| Final free-space minimum |7,682,637,824bytes (~7.15GiB), shared-volume telemetry |

Первый combined full получил обычный ready-source timeout и обнаружил дефект **самого нового control assertion**: durable completed уже читался, а service caller ещё не вернулся, поэтому немедленный `trace.has(publication.inserted.return)` был false. В финальном timeline того же owner событие уже присутствовало. Исходный failed source/summary/activities/whole bundle сохранены в [after62-before-fix](results/after62-before-fix). Исправлено только ожидание отдельного return acknowledgement в новом control (те же5s); исходные coverage fences и production не менялись. Targeted после этого прошёл.

Final full выполнили один раз после этой подтверждённой правки. Он всё ещё failed: (1) original-ready-event/ready-source coverage, (2) controlled-owner-release/direct restart coverage. Оба теперь действительно исполнили rich recorder до unwind. Никакого rerun после этого final и ослабления5s нет.

В новом original episode bridge weakAlive=true, enabled/started=true, startup-return config совпадал с текущим, event получен, job leased/active и durable running/cursor0 с тем же run/attempt. При physical snapshot entered/returned/fakeCalls=0. В final capture ещё не было update.begin, то есть не доказано, запускалась ли task preparation или где именно она ожидала. В предыдущем combined episode update.begin был, physical.enter появился позже во время неатомарного capture. Это разные наблюдения **новых эпизодов**, не объяснение старых failures.

В direct-restart episode bridge weakAlive=false намеренно: deinit/stop исходного owner завершился до direct restart, worker получил новый run и lease, started=true/durable running, physical counts0 на момент capture. Recovery до5s в этом full не прошёл. Не объявляем это потерей event, неожиданным deinit, причиной OCR или подтверждённым SQLite/executor defect. Нужна отдельная ограниченная интерпретация actual evidence координатором/reviewer; production workaround не добавляется.

Все неатомарные readings/timestamps и полные timelines сохранены. На финальном дереве OCR-тесты прошли, но known OCR gate других runs не снят. Global stdout final содержит69 SQLite failure lines/26unlink warnings/3e5rt lines; selected5scopes clean. Existing expected outcomes4tests/12runs относятся к принятым negative SQLite helper tests; bridge/OCR не expected и не skipped.

Raw failed bundles сохранены также `/tmp/golos61-after62-preserved.xcresult` и `/tmp/golos61-final-preserved.xcresult`. Архивы содержат reports/scopes/attachments/migration, raw gzip stdout/logs, member hashes. [Final checks](results/final-after62/checks.json) — актуальный результат; initial checks ниже исторические.

Всего было3 full на трёх разных деревьях: initialfc2, integrated62, затем подтверждённая control-only race fix. Каждая новая основа/правка и каждый красный результат выделены. Это не повтор одного SHA до зелёного. Release audit остаётся применим: production source после62/test-only fix побайтово тот же, что при Release build.

## Первоначальные проверки наfc2 (сохранены)

Первоначальное проверенное дерево исходников: `d1aeb2f7bc30aa5de69e1f1d8e4d36f76af61041`. После него добавляются только отчёт/evidence.

| Проверка | Результат |
|---|---|
| Final targeted: Queue + MemoryBridgeDiagnostics | **29 tests /41 runs Passed**,0failed/skipped/runtimeWarnings |
| Единственный final full `make check` с existing publicE5/settings/menu/bridge/scope/migration opts | **Passed:** total446 tests,444 ordinary passed +2 reported expectedFailures;622 ordinary passed runs +7 expected runs;0failed/skipped/runtimeWarnings |
| Release build | Passed, build-only |
| Release source audit | Worker/bridge release tokens равны accepted base после удаления DEBUG блоков и нормализации whitespace/optional semicolons |
| Release symbol audit |0новых diagnostic matches; Debug observation symbols присутствуют |
| Native lifecycle пяти затронутых случаев |5roots/5opens/5native close0/5unlink, closes до удаления,0scope errors |
| Attachments |271:181scope+8bridge+82OCR;189scope/bridge byte matches,0mismatches;41OCR inputs SHA/bytes verified |
| Migration |9raw traces |
| Free space | Release minimum8,385,552,384bytes (~7.81GiB), full minimum6,146,646,016bytes (~5.72GiB) |

Expected outcomes полного набора принадлежат **уже принятой SQLiteFaultExpectationTests** (strict negative controls). Их exact summary/test tree сохранены. Новые bridge controls имеют обычный Passed; удержанный startup/intentional errors явно заданы тестом и проверены catch/assert, а не объявлены known historical failures. Отказов OCR в этом конкретном full не было, но это не восстановление общей гарантии OCR/runtime stability.

Global stdout не объявляется чистым:55 SQLite failure lines,40unlink warnings других fixture families и3e5rt diagnostic lines сохранены целиком и в excerpt. Negative tests и незавершённая общая #58 диагностика отдельно; пяти selected scopes эти ошибки не приписываются. Весь system logarchive не публикуется.

Первоначальный full наfc2 — один запуск; subsequent combined runs перечислены отдельно выше, без rerun-until-green. Первый targeted build предшествовал финальным read-marker/error/cancel additions и отдельно сохранён как iteration; final targeted и full покрывают final source. Release/full runner раз в секунду записывает free-space telemetry и не чистит/перезапускает ничего. Метрика относится к shared volume, не доказывает, кто занял пространство. Extra OCR probes=0. Новых весов/моделей не скачивали.

## Артефакты и воспроизведение

[checks](results/checks.json), [before](results/before), [failure recorder audit](results/failure-recorder-audit.json), [scope audit](results/scope-audit.json), [attachments](results/attachment-audit.json). Полные gzip logs/stdout сохранены. Exact bridge reports/timelines, native scope traces и Xcode attachments упакованы в отдельные `.tar.gz` в full/targeted; имена members, bytes и SHA записаны в [archive-members](results/archive-members.json). Каждый архив после упаковки прочитан и сверён побайтово; сырые JSON не нормализованы. Full test tree сохранён как JSON gzip. Это уменьшает генерируемый diff; evidence не удалено. Хэши сжатых и исходных логов/исходников записаны; models/caches/build binaries в git не включены. Full xcresult остаётся в собственном `.build/xcode/Logs/Test/Test-golos-meet-2026.11.02_07-43-57-+0300.xcresult`.

```sh
TEST_RUNNER_GOLOS_FIXTURE_EVIDENCE=/tmp/golos61-review-scopes TEST_RUNNER_GOLOS_BRIDGE_EVIDENCE=/tmp/golos61-review-bridge xcodebuild test -scheme golos-meet -destination 'platform=macOS' -derivedDataPath .build/xcode -only-testing:golos-meetTests/MemoryBridgeDiagnosticsTests -only-testing:golos-meetTests/ProjectMemoryQueueTests CODE_SIGNING_ALLOWED=NO
python3 research/memory-bridge-61/audit_release_source.py
python3 research/memory-bridge-61/run_check.py release --prefix /tmp/golos61-review-release
python3 research/memory-bridge-61/run_check.py full --prefix /tmp/golos61-review-full
```

Использовать новые output prefixes. Full запускает и OCR общего набора; отдельные OCR probes здесь не нужны. Требуется явно установленная publicE5 по указанному в runner пути, скачивания нет. Системные caches/daemon/settings/reboot не менялись. Production Keychain, пользовательские документы/аудио, live cloud, capture/ASR/GUI/CUA не использовались. Обычные build caches пишет сам компилятор, вручную их не чистили. Другой Mac и разблокировка текущего — отдельные действия пользователя; GUI55 не запускался.

## Передача

Самопроверка не установила production root cause; mandatory combined full остаётся failed. Отдельный reviewer должен проверить exact новый SHA: DEBUG-only isolation/Release absence, owner lifetime/context, failure path и native lifecycle, без смешивания negative controls с historical causes. #61/37/#5 не закрывать по одному зелёному запуску; решение по диагностическому контракту и остающемуся bridge gate принимает координатор после независимого review. PR55 и общая interactive/OCR проверка остаются отдельными.
