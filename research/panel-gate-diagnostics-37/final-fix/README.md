# #37 · Два подтверждённых P2: final fix preparation

Независимое review43 завершено на frozen prepared `049ff242643240a8bd57006fa1b1ad8ee240fb1b`: два обязательных P2, других обязательных замечаний нет. [Исходный отчёт](review049ff/FINAL_STATIC_REVIEW.md), SHA256 `cf836f79f82144103c0085e9a109fee4fd3e2abc117c5c9d8d838d834d831fbb`; [receipt](review049ff/static-review-receipt.json), SHA256 `4b959a86a76b89d9c42584b7900b9c67b1e169ec532f055bd05a1aa31351ba58`. Копии точные, checkout ревьюера не менялся.

Startup P2 адресован локальным `f152e7daad646e53d8269646db6bea4954d86954`: [описание](../p2-initial-attempt/README.md). Initial needsConsent/attempt NULL отделён от actual UI prepared lease receipt. Этот host source здесь не меняется.

Packaging P2: старый completed bundle фактически вернул strict verify exit 1 «code has no resources but signature indicates they must be present». Это отказ статической проверки подписи; запуском отказ macOS не доказан. Только diagnostic mode builder теперь после завершения всех sealed files выполняет ad-hoc sign собственных вложенных Mach-O, затем собственных containers изнутри наружу и корня нового bundle. Symlink/outside targets отклоняются. После signing требуется deep strict verify exit 0; commands/stdout/stderr/exit codes и before/after whole binary SHA сохраняются вне sealed bundle. Сравнение executable sections/UUID не выполняется и эквивалентность кода по whole binary hash не заявляется. Внешние linked frameworks/products/runtime не подписываются и не изменяются.

Static assessment проверяет весь protected source против 24b, точность старых receipts, сохранность startup fix и AST normal builder после удаления ровно нового diagnostic-only блока. [Оценка](static-assessment.json) не является runtime proof. Production, tests, Rust, Xcode project, Makefile, privacy/deadlines, normal preview и старые bundles/libraries остаются неизменными.

Root разрешил **одну final fix build совместного diff** после final049ff review. Новый уникальный `/private/var/folders/.../T/golos-memory-gate37-*`, новый bundle id, output≤1GiB, elapsed<180s, fresh free≥6GiB+forecast1GiB и STOP<6GiB. Exclusive новый receipt создаётся до preflight; любой preflight/compile/sign/verify/budget failure сохраняется INCOMPLETE и не запускает повтор. Старый build/source/receipt049ff не переписываются и никогда не запускаются. До сборки создаётся чистый code checkpoint; после неё только docs/receipts final SHA для независимого review43 delta.

Никакого launch/CUA/actual held case, full, OCR, матриц, live inference, облака, ASR, новых весов, push или нового PR. Main и remote PR55 не обновляются. Runtime NOT RUN даже при успешных compile/signature checks. Финальное решение о публикации и одном actual UI case принимает root после exact-SHA delta-review; пользователь сейчас не участвует.

Воспроизведение только статического аудита:

```sh
python3 -B research/panel-gate-diagnostics-37/final-fix/prepare.py --check
```

`build_once.py` — одноразовый guarded driver. Его не следует повторно запускать ради проверки; exclusive receipt блокирует следующий запуск. `validate.py` предназначен для чтения сохранённых результатов после этой единственной сборки и не запускает приложение.

## Единственная final fix build: результат

**Build/signature verify Passed; host НЕ запущен, actual case NOT RUN.** Чистый code checkpoint **`2febb801cd211db850eb3ce8dba70741a526d5a0`**, включающий startup fix f152e7d и diagnostic signing. После сборки изменения ограничены docs/receipts; helper/builder/production/test source не меняется. Старый Passed37.436s и его неподписанный bundle остаются отдельным историческим результатом; всего были одна первоначальная подготовительная сборка и одна отдельно разрешённая final fix build, без циклических повторов.

| Проверка | Результат этой final fix build |
|---|---|
| Process |Одна попытка, exit 0, **29.369291875s** |
| Guard |180s /1GiB /reserve6GiB+forecast1GiB; STOP не сработал |
| Output |**334455314 B**,317 post-sign output files |
| Space |59 samples, preflight91046187008 B, minimum90710740992 B |
| Compiler |Raw build.log — 0 B, warning/error lines0 |
| Signing |Два собственных resource bundles, затем собственный root app: все sign exit 0 |
| Strict verify |`/usr/bin/codesign --verify --deep --strict --verbose=2 <fresh.app>` — **exit 0**, stderr «valid on disk / satisfies its Designated Requirement» |
| Before-sign binary SHA256 |`1244171ace0b471810eb0c3d85e81ec3cff4f9bab2970ba3630822a08287050e` |
| After-sign binary SHA256 |`ae7f8d0e29241bf61deaa0c95cc5829f3f08c4b08ead04d2fdc07d25b6043094` |
| Source manifest SHA256 |`ee1dddb5698539a1bed1287c1db0d8263ea75b5a854a8cbcb615acbd70c9350f` |
| Fresh bundle |`com.golos.memory-gate37.e09a046874694f3ba87b32616c963c6f` |
| External linked inputs |Все 11 файлов до/после имеют исходные reviewed bytes/SHA; ни один не подписывался |
| Old outputs |Все 307 прежних output files совпали по размеру/SHA; old runtime library отсутствует |
| Runtime |New library отсутствует; consent/physical call/PDF/OCR/inference/CUA не исполнялись |

Fresh output root: `/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T/golos-memory-gate37-a19e1b2b2d6b4518abd9614c7f16130f`. App/binary/module cache остаются локально, в git только исходники, docs и evidence. Ресурсы/Info были завершены до signing; после него sealed bundle не дописывался. Отличие before/after whole binary hashes ожидаемо фиксируется, но не подменяет section/UUID comparison: такое сравнение не выполнялось, тождество executable code на его основании не заявляется.

[Build receipt](results/build-receipt.json), [summary](results/build-summary.json), [signature commands/exit/stdout/stderr](results/signature-receipt.json), [post-sign output file hashes](results/build-output-files.json.gz), [source manifest](results/source-manifest.json), [linked inputs before/after](results/linked-inputs.json), [сохранность старых outputs](results/old-output-preservation.json), [raw compiler log](results/build.log), [disk telemetry](results/build-telemetry.jsonl). Remote55 guard в preflight фактически подтвердил24b; remote не записывался.

Offline validator Passed:

```sh
python3 -B research/panel-gate-diagnostics-37/final-fix/validate.py
```

Он проверяет source provenance/hashes, old/static assessment, current completed output hashes, budget telemetry, signature command receipts, input hashes и отсутствие runtime library. Это не семантическая проверка запуска или held-case. Target14.4 скомпилирован текущим SDK, отдельная runtime-проверка macOS14.4 не выполнялась. Make check/full/OCR/matrix намеренно не запускались по явной границе root для этой diagnostic задачи.

Дальше: docs-only final SHA → тот же independent43 delta-review точного SHA, startup source и actual signed outputs → root отдельно решает fresh guard/push и один actual UI case. До этого не запускать ни старый, ни новый host. #37/#5 не закрываются; main/PR8draft и historical #56/#61 прежние.
