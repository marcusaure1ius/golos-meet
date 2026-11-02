# #37 · Grouped driver fixes before first actual host compile

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
