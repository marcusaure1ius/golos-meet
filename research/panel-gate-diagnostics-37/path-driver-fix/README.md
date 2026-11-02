# #37 · Grouped driver fixes before first actual host compile

**Текущий результат: FIRST ACTUAL COMPILE Passed, strict signature verify exit0; host НЕ запускался, runtime NOT RUN.** Compile code checkpoint `c3342ff42e0a9fa60eab926aec821c9110c5e05e`; исходные controls35c4 использованы через byte/ancestor binding без нового запуска. После compile только docs/evidence; независимый review43 exact final SHA/assets ещё требуется.

Root назначил только исправление двух подтверждённых P2 из [независимого exactfda review](review-fda/FINAL_STATIC_REVIEW.md), report SHA256 `85c30e34eaf124053959702a288125b976b79e28234abcf5d58f9070f116d15e`, [receipt](review-fda/static-review-receipt.json) SHA256 `2586dcd52d8feba50ebd1e64820adea2a191e177cac6a48c5536a336945449ad`. Frozen reviewed head `fda8a2f104501b1f6bcf2b25446342729421dd92`, immutable controls checkpoint `35c4da62abe23c4de90656525617676d75fbdcf7`. Helper/pathvalidation/typed host wiring не получили дополнительных P1/P2; host к этому моменту UNBUILT.

Старые path-alias-fix driver/STOP/controls/receipts остаются неизменными. Новый [build_once.py](build_once.py) использует отдельный exclusive namespace `results-first-compile`. Это адресно разрешённая подготовка после independent findings, не повтор failed tests. Предыдущий driver не вызывал compiler; здесь разрешён один FIRST ACTUAL COMPILE диагностического host с этим helper. Ни новые Foundation controls, ни app launch не разрешены.

## Два исправления

1. [preflight.py](preflight.py) получает repo root, нормализует driver folder к repo-relative POSIX path, захватывает `git status --porcelain=v1 -z --untracked-files=all` до создания attempt receipt и сохраняет raw bytes hex/text, exit/stderr, structured entries/parse error, normalized folder и phase ДО assertion. Допустимы только точные immutable artifact filenames с hashes из reviewed git objects; модифицированные/staged/deleted tracked paths, foreign/unreceipted untracked paths, symlinks и outside paths отклоняются. Controls subtree целиком не разрешается, allowdirtyall отсутствует. Новый собственный receipt не загрязняет исходный snapshot, поскольку snapshot снят раньше его создания.
2. Original controls receipt.code_head остаётся35c4, не переписывается и не сравнивается с текущим HEAD. Проверяются существование и ancestry35c4/fda, точные current/git35/gitfda/git-current bytes helper/harness/host/builder, helper+newline+harness==preserved combined source, все original artifact hashes, actual16 results и rawstdout, original temp check/results bytes. Текущий compile checkpoint и полный60-source manifest записываются отдельно. Diff от reviewedfda допускает только новый driver/docs/evidence namespace и index README; semantic source change — STOP.

Контролируемые source hashes заморожены: helper `17e72c66e142e379517bb38d596329d8cf682465b3b719675e03a7712c645c15`, host `1628d3b018d5f72cc671d4fc034303f392ab0c4954399506e6f4d499572dec4e`, builder `1ec090093a376a0b61f82981d7840890f79e9019c476ae79e20e9b413bbfd570`. Они не редактируются. Original controls16/16 не перезапускаются. Прежний STOP не становится Passed; исходные dynamic status values того отказа по-прежнему не captured.

## Ограниченная первая компиляция

После clean code checkpoint разрешена одна подготовка: expected remote55acfe guard, process inventory (`exit3` — ошибка, не отсутствие), reserve6GiB+forecast1GiB/STOP<6GiB, build≤180s/output≤1GiB. Fresh unique actual user temp output/app/bundle, без overwrite049ff/acfe/controls/старых repair assets. Только собственный completed bundle подписывается после всех sealed files, затем deep strict verify0, post-sign hashes60-source/11inputs/output receipts. Любой preflight/compile/sign failure сохраняется INCOMPLETE, автоматического retry нет.

Production entry/panel/model/store/service/worker/tests/Rust/Xcode/Makefile/default guard/privacy/30s deadlines остаются побайтово прежними. Main/preview23b/remote55acfe/PR8draft не обновляются. Никаких full/OCR/newcontrols/CUA/host launch/actual case/reset/push/newPR. Успех compile/signature не доказывает LaunchServices startup и UI gate. После docs-only final SHA нужен independent43 delta/assets review до любого runtime.

Статическая оценка без compiler/controls:

```sh
python3 -B research/panel-gate-diagnostics-37/path-driver-fix/prepare.py --check
```

После единственной сборки `validate.py` проверяет сохранённую provenance, source/asset/input hashes и budgets, не запуская приложение или controls. Исторические failure и actual crash acfe остаются сохранёнными фактами.

## Результат единственной разрешённой попытки

Новый code checkpoint `c3342ff42e0a9fa60eab926aec821c9110c5e05e` был чистым до вызова driver. [Preflight/build receipt](results-first-compile/build-receipt.json) теперь действительно захватывает исходные values до assertions: status command exit0, raw hex/text пусты, structured entries[], normalized folder `research/panel-gate-diagnostics-37/path-driver-fix`. Runtime dirty whitelist branch на этом clean snapshot не потребовалась; negative dirty/symlink cases не исполнялись отдельными новыми controls и не заявляются проверенными экспериментально.

[Control/source binding](results-first-compile/control-source-binding.json) сохраняет original checkpoint35c4 и receipt SHA256 `4b35577a91d4d6ba0a8bdef50c1f7ecf66858799351c37b2ae30897d3ad1dce7`, подтверждённую ancestry35c4→fda→c334, exact helper/harness/combined/host/builder bytes и scoped diff. Controls не перезапускались. Полный manifest компилируемого checkpointc334 содержит60 файлов и совпал с preflight map. Это правильная привязка различающихся commit IDs, не изменение старого receipt.code_head.

| Проверка | Результат этой попытки |
|---|---|
| Первый actual host compile с исправленным helper |**exit0, 32.594828333s**, одна попытка |
| Outputs |**334537215 B**,317 post-sign files, ниже1GiB |
| Space |65 samples, preflight82461728768 B, minimum82128830464 B; reserve6GiB+forecast1GiB, STOP не сработал |
| Compiler |Raw log0 B, warning/error lines0 |
| Signature |Три собственных sign commands exit0; `codesign --verify --deep --strict --verbose=2` **exit0** |
| Source manifest SHA256 |`106c033a62bdee2ce2b98e8c1b3ca67f68ba7fe114cffcbff34c2e178bb71885` |
| Before-sign binary SHA256 |`3536b16125940329d0e3cf89f8d8b88180856416e788a7e9bc742962207e7a5f` |
| After-sign binary SHA256 |`4a9a607d781f0a2b5f391c01ffc64f289401a218a1d6230c249ec7d4e669d089` |
| Fresh bundle |`com.golos.memory-gate37.f82072742833483eaa3a21868679161e` |
| External inputs |11 reviewed linked files unchanged before/after; не подписывались |
| Old outputs |Все307 файлов049ff и317 файловacfe совпали с прежними size/SHA; библиотеки отсутствуют |
| Protected source |257 tracked source files побайтово прежние; helper/host/builder/harness точны35c4 |
| Runtime |New library отсутствует; host/LaunchServices/CUA/actual case NOT RUN |

Fresh app: `/private/var/folders/f6/hwzbqsn10fn6p6gx8d5vmnfm0000gn/T/golos-memory-gate37-28de2281609d4670ad977d96df4b6eee/Golos Memory Gate Diagnostics.app`. SyntheticRoot — `library` того же fresh root. Builder/code-sign outputs остаются локально; в git source/docs/receipts/hashes. Sealed files завершены до подписи; после подписи bundle не изменялся. Whole binary hashes before/after отличаются; executable section/UUID equivalence не проверялась и не заявляется.

[Summary](results-first-compile/build-summary.json), [signature commands/stdout/stderr/exit](results-first-compile/signature-receipt.json), [post-sign output hashes](results-first-compile/build-output-files.json.gz), [source manifest](results-first-compile/source-manifest.json), [11 inputs before/after](results-first-compile/linked-inputs.json), [disk telemetry](results-first-compile/build-telemetry.jsonl), [raw compiler log](results-first-compile/build.log), [old output preservation](results-first-compile/preservation-summary.json). Expected remote55acfe guard фактически прошёл; remote не изменялся.

Offline validator Passed:

```sh
python3 -B research/panel-gate-diagnostics-37/path-driver-fix/validate.py
```

Он заново проверяет saved binding/hashes/ancestry/git objects, текущие60 source bytes,317 outputs/11 inputs/307+317 old assets, signature receipt и budgets. Новых Foundation invocations/tests/launch не выполняет. Target14.4 проверен компиляцией текущимSDK; actual runtime наmacOS14.4/LaunchServices/UI не проверялся. Full478/676 относится к ранее unchanged production source, не к новому diagnostic runtime. Source path fix исправлен и собран, но прежний actual crash acfe этим не отменяется.

Дальше docs-only final SHA → тот же independent43 delta/assets review → отдельное root решение о публикации/любом runtime. До этого не запускать новый host. СтарыеSTOP/failure и controls16/16 immutable, no rerun. PR55 remoteacfe, preview23b, main и draftPR8 прежние; #37/#5 не закрываются.
