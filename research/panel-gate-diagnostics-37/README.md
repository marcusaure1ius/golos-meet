# #37 · Self-recording diagnostic gate: подготовка до запуска

Это отдельная host-only часть той же feature PR55, base `24b49b067fcda107e397ed4f2461f9bb23de322f`, accepted preview `23b1da158304a2c0c596752d9150e489b1884fb4`. Новый managed worktree/branch `codex/37-panel-gate-diagnostics`. Production, Swift-тесты, Rust, Makefile, deadlines и privacy guards должны оставаться побайтово равными24b. Старые worktrees, reviewer app, completed seed и evidence не изменяются.

**Никакого запуска host/CUA/held-case в этой подготовке нет.** Разрешена одна сборка≤180s, output≤1GiB, fresh reserve6GiB+forecast1GiB, STOP<6GiB. После сборки code/report/receipt передаются независимому review43. Root отдельно решает публикацию exact SHA и один actual UI case. Remote PR55 до нового root guard не обновлять; новый feature PR не создавать.

Утверждённый [план](SELF_RECORDING_GATE_PLAN.md), SHA256 `ddeee469bd5ce06b0fc0f02b0a55083ea6f00ed2f358c3ec148f8161bbae64ed`.

## Source assessment до build

[prepare.py](prepare.py) проверяет hashes всего защищённого дерева24b, границы diff и фактический порядок:

1. Model `send`: busy=true → sending=requestUUID → request=nil → operation Task. Direct `$request.sink` не добавляет scheduler/Task/await и сохраняет marker синхронно; использует опубликованное новое значение. Cancel/invalidate выставляет busy=false раньше request=nil и не считается consent.
2. Worker approve → `resumeMemoryQueueConsent` с завершением транзакции → process → active task/timer. Время fake-call не является началом production30s budget.
3. Последний полный needsConsent SQL sample с non-null attempt замораживается в observed send marker. Консервативная нижняя граница — **начало его READ**, строго до marker/operation; read END/first running отдельно timestamped. First running обязан иметь ту же job/input/cycle/generation/attempt/run.

Apple описывает публикацию `@Published` в willSet, до присвоения хранимому свойству: [официальная документация](https://developer.apple.com/documentation/combine/published?changes=la__7_1_3). Поэтому project sink использует emitted value, пропускает initial emission и для verdict требует последующее чтение фактического model.projectID. Marker — наблюдённый send-state, не mouse click. SQL anchor не зависит от позднего adapter timestamp.

## Реализация одного case

- Отдельный `MemoryPanelGateDiagnostics.swift`; normal preview source не меняется. Builder diagnostic mode запрещает weights/reuse/resume, создаёт уникальные app/bundle/root прямо под реальным `/private/var/folders/.../T`, совместимым с AppPaths guard.
- Test-mode guard до store/runtime setup. Одна meeting/current, North askEveryTime, Private localOnly, синтетические2D vectors; PDF/OCR/ONNX inference/network/Keychain/audio/capture/ASR отсутствуют. Actual entry/model/store/service/worker выполняются после будущего разрешённого launch; здесь не запускались.
- Координатор не создаёт hidden panel model. Factory регистрирует entryUUID/ObjectIdentifier и weak actual returned model; appearance/factory могут приходить в разном порядке. Subscription callbacks weak, не держат модель через await; initial project emission не считается Picker action.
- Arm label появляется после actor receipt и fsync ACK. Physical-held label — только после сохранения continuation в actor **и** frozen first-running sample. Call/request/token/payload hash связаны; один physical call.
- Пользователь сам даёт consent и меняет actual Picker. Coordinator проект не переключает. Самописец имеет локальные инструкции и countdown: до5мин чтения preview, затем conservative cancel END<20s, весь case≤45s.
- Read-only SQL connection, busy_timeout0; каждый read — отдельная read transaction с началом/концом/UTC, полным bounded job snapshot, run, projects/policies и history count+первые2 строки. Изменение identity/run/policy/history, missing running/attempt, read error — INCONCLUSIVE. Изменение generation/обнуление attempt допускается только как ожидаемый cancellation transition; после explicit retry требуется свежий attempt.
- Diagnostic release вызывается только после записанного/flushed early-cancel proof и связывается с его sequence/hash. Actor release/adapter return могут логироваться в разном порядке после actor hop; actor timestamps/receipt сохраняют фактическую причинную связь. Нет automatic consent/retry/fallback.
- Physical adapter намеренно некооперативен: после diagnostic release возвращает валидный поздний ответ реальному service. Проверяется history0/calls1. Только waitUntilIdle не используется как approval join.
- Пользователь делает К проекту→Память и explicit retry/prepare без второго send. Old weak model nil + новый canApprovePreview=true дают отдельный receipt: actual guard требует active=nil, worker=nil, loadingPreview=false, и старый operation больше не удерживает старую модель. Это не прямой Task.value API; проверяемая граница вывода описана в source.
- Logger≤512events/2MiB, монотонные sequence/clock+UTC, append+sync, явный overflow/error. Final manifest не появляется под final.json до успешных write/sync/close. Snapshot атомарен только внутри своего SQL transaction; общая UI/actor/SQL картина неатомарна, observer может влиять на scheduling.
- Любой сбой красный INCONCLUSIVE. Cleanup отдельно маркирован и не считается project-cancel proof; снимает только собственную continuation, закрывает observation и read-only sensor, не force-close production DB и не удаляет библиотеку.

## Единственный build: результат

**Build Passed, actual case NOT RUN.** Скомпилирован code checkpoint `fcdd8837d3163bf9aba9274b0c66449e14a11940`. После него изменены только отчёт/receipts/offline validator; helper и builder не менялись.

| Проверка | Фактический результат |
|---|---|
| Сборка |Одна попытка, exit0,37.436s; повторов/full/test matrix не было |
| Outputs |334724977B (~319MiB), ниже1GiB |
| Space |74samples; preflight91507605504B, minimum91202404352B; reserve6GiB+forecast1GiB, STOP не сработал |
| Compiler |0warning lines /0error lines в сохранённом raw build.log |
| Native binary SHA256 |`3fe0e3b68bcbbd08c8f73e7f8a928994f73e2b6c04eddf62a328a148b0f4980c` |
| Source manifest SHA256 |`f163707e9972b480a60dc44318f661fa293d06c17612ee5591ef5c0d01e85ace` |
| Bundle |`com.golos.memory-gate37.7260db48e97e426e954d1f6bcc258c68` |
| Runtime |Host NOT launched; CUA/consent/held attempt NOT executed; fresh `library` directory ещё не создана |

Output root: `/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T/golos-memory-gate37-ef623b597e83409796b75d7e232d4420`. Бинарь и SDK caches остаются локально; в git только source/evidence/hashes. Старые completed библиотеки не сбрасывались. Linked package input hashes записаны после build и должны совпадать перед будущим разрешённым запуском; это не новые модели/веса.

[Build receipt](results/build-receipt.json), [summary](results/build-summary.json), [raw build log](results/build.log), [allowlist](results/source-allowlist.txt), [source manifest](results/source-manifest.json), [linked inputs](results/linked-inputs-postbuild.json). Target14.4 проверен компиляцией текущимSDK, не runtime на отдельнойmacOS14.4.

Offline audit без compiler/launch:

```sh
python3 -B research/panel-gate-diagnostics-37/validate.py
```

Он проверяет защищённые source bytes, compiled checkpoint hashes, manifest/Info/binary, output file hashes, budgets и отсутствие созданной runtime library. Он не проверяет поведение неисполненного case. Перед actual launch нужны независимый review43 этого exact prepared SHA и отдельное решение root; текущий build не является таким разрешением.

## Статус и передача

Static assessment: [results/static-assessment.json.gz](results/static-assessment.json.gz). Результат единственного build сохранён в results/build-receipt.json и raw build.log. Meaningful compile failure не исправляется с новым автоматическим build; incomplete не выдаётся за Passed.

Normal singleton composition и width-extrema не проверяются этим диагностическим case. Прежние FINAL24b/noP1P2 и старые inconclusive/0call captures сохраняют свои исходы. Не требуется от человека повторять старый неинструментированный путь или ждать команды чата между timed действиями.
