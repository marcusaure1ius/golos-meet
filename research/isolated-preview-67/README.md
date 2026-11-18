# #67 · Отдельный packaged QA profile

> Примечание (ребейз на 6ed86f7, PR #92): артефакты прогонов `results/*`,
> упомянутые ниже, относятся к проверкам старого SHA и хранились локально вне git;
> в этот перенос они сознательно не включены — свежие проверки описаны в PR #92.
База реализации — accepted `23b1da158304a2c0c596752d9150e489b1884fb4`, новый
managed worktree/branch `67-isolated-preview` / `codex/67-isolated-preview`.
PR55 `d0e47d0f5ca7c9c380abaf243b11a208aa36d4ab` остаётся отдельным reviewed,
draft/unmerged изменением. Он сюда не сливался и не является непроверенной базой.
Только root после независимого review67 может подготовить local combined QA
snapshot55+67. Shared preview/main и статусы PR55/PR8 не меняются.

## Что изменилось

Pure `AppProfile` распознаёт normal, explicit `isolated-qa-v1` и test profile.
Test-host проверяется первым, даже если bundle metadata повреждена. QA metadata
должна содержать согласованные32lowercasehex ID, bundle id и видимое имя.
Неизвестная/частичная metadata не выбирает production fallback. Нет произвольного
AppSupport path/environment override профиля.

Normal сохраняет `com.golos.golos-meet`, target `golos-meet`, модуль `golos_meet`,
AppSupport `golos-meet`, UserDefaults.standard и Keychain service `golos-meet`.
QA получает отдельные bundle/display name, `golos-meet-qa-<ID>`, preferences
domain `com.golos.golos-meet.qa.<ID>`, service `golos-meet.qa.<ID>`. UISettings и
ASRSettings используют выбранный preferences store. Test paths/service сохраняют
изолированный temporary root, settings теперь имеют также уникальный test domain.
Keychain операции при ошибке profile не вызывают SecItem API.

AppLibraryState/AppDelegate блокируют рабочую инициализацию до library/settings/
coordinator при ошибке profile. UI в таком случае показывает локальное сообщение
без открытия production data. Internal URL/preferences accessor требует валидный
profile; это инвариант, не fallback. Существующие test-host guards остаются первыми.
QA sidecar берётся из bundle, developer env override сохранён для normal/test.

Упаковщик получил `PREVIEW_ISOLATED_QA=1` / `--isolated-qa`: один новый profile ID,
`Golos Meet QA.app`, metadata до inside-out ad-hoc sign, strict verify, отдельный
manifest/inventory/ZIP и [простая инструкция](../preview-package/ISOLATED_QA.md).
Чтобы новый packaging mode не пометил старый binary без runtime isolation,
archive должен содержать тот же committed packager и profile contract source.
Эта проверка совместимости не заменяет independent semantic review snapshot.
Pinned dependencies/Cargo.lock, sidecarCLI --version/--help без Session и модели
сохраняются в будущем package build. Rust code не меняется.

## Границы

Нет копирования рабочих записей/документов/настроек/секретов/весов и нет symlink к
production models. QA starts empty. E5 устанавливается только по выбору пользователя;
установка ASR weights автоматически не подключена. Без отдельно подготовленных
весов ASR не обещается, новый ModelManager сюда не входит.

Финальный package build, app launch, живые модели/ASR/cloud и новая пользовательская
сессия НЕ выполняются при реализации67. Текущая работающая `/Users/alfa/Applications/Golos Meet.app`
не открывается, не подписывается, не останавливается и не меняется. Старый37
worktree/source/evidence остаётся frozen. Constance/календарь/редизайн/таймерные
diagnostic cases вне scope. Полная QA-копия пользователю передаётся root после
source+combined snapshot review и отдельно разрешённого одного package build/audit.

## Проверки

Python packaging guards: `python3 -B research/preview-package/test_package_preview.py`
— **8 tests Passed**, включая literal Make argument/env transport, strict profile
metadata, отказ старому snapshot, nested container signing order и исходные
model/data/symlink guards. Fixtures синтетические; Xcode/real signing/sidecar/app
не запускаются этими тестами.

Swift `AppProfileTests` проверяют normal/QA/test namespace separation, отсутствие
путь traversal, полную/частичную/неизвестную metadata и test-first precedence на
pure values без реальных data/Keychain/network. Existing TestHostIsolationTests
дополнены проверкой profile и defaults domain.

Оба Swift запуска завершены на exact source checkpoint
**`7451f7816468c6e2ddce1e547118c2d049d2faa7`**. После них изменяются только
docs/evidence. [Machine-readable checks](results/checks.json) и оба полных raw
logs/test trees сохранены, без повторного full.

| Проверка | Фактический результат |
|---|---|
| Focused Swift |**8 tests /8 runs Passed**, failed/skipped0, runtimeWarnings0;40.178s с cold compile |
| Обязательный `make check` |**Passed**,463 test cases =453 passed +4 expected negative +6 opt-in skips; failed0/testFailures[]/runtimeWarnings0 |
| Full parameterized runs |654 исполненных =642 passed +12 expected negative;6 skipped, всего660 run entries |
| Full process |Exit0,23.121s, один full без повторов |
| Resource guard |Свой DerivedData, clone только public SourcePackages; forecast8GiB сверх reserve6GiB, serialized inventory, STOP<6GiB не сработал |
| Space |Targeted40samples/min76291493888 B; full23samples/min76140343296 B |
| Source |Input SHA до/после совпали; Rust/Xcode project и default normal bundle settings не менялись |
| Product/runtime |QA package НЕ собран; отдельная QA app не запускалась, combined55 snapshot пока не создавался |

Шесть skips — четыре opt-in public E5/native inference и два opt-in native UI
render suites. Они намеренно не включались: root запретил новые model sessions
и дополнительные UI/OCR probes. Real ASR E2E исключён штатной целью. Отдельного
живого ASR/LLM/recording результата не заявляется. Обычные synthetic OCR тесты в
make check исполнились без отдельной probe/matrix. Существующие Keychain tests
использовали только штатный test-host service, не рабочие секреты.

Первая компиляция содержит155 compiler warning lines (пакеты/ранее существующие
файлы), в изменённых Swift source warning lines0. Incremental full compiler
warning lines0. Raw full log содержит18 строк, соответствующих фильтру
SQLite+failure/error; e5rt0. Они сохранены без глобального подавления или новой
атрибуции; успешный summary не объявляет объяснёнными исторические #56/#61.
Эта задача не расширяется в новый fixture/SQLite diagnostic audit.

При первом static xcresult export sandbox отказал записи внутреннего TestReport
cache. Сохранён [export denial](results/export-initial-sandbox-denial.json);
последующий static export получил нужный файловый доступ. Тесты при этом не
повторялись. Whole xcresults остаются в task-owned temporary DerivedData/result
paths из receipts; JSON summary/trees/raw stdout/telemetry/source hashes в git.

Raw/evidence: [targeted receipt](results/targeted/receipt.json),
[full receipt](results/full/receipt.json), [full summary](results/full/summary.json),
[full stdout](results/full/stdout.txt.gz), [full test tree](results/full/tests.json.gz),
[artifact hashes](results/artifact-sha256.json). Test runner сохранён как
`check-runner.py.txt` для воспроизводимости команд/guards, а не как продуктовый UI.

## Передача

Source подготовлен для independent exact-SHA review; author self-check не заменяет
его. По указанию root review43 параллельно читает исходный7451f78 без build/runtime;
docs-only final SHA требует итогового delta-review. PR направляется в
`codex/product-preview`, с `Refs #67`, поскольку package/combined/audit/delivery
критерии ещё впереди. Автор ничего не сливает и не меняет статусы55/8.

После независимого source review root отдельно готовит локальное сочетание
reviewed55+reviewed67, не затрагивая shared branches. Только после этого — отдельно
разрешённый один package build и независимый unzip/static/dependency/sign/CLI
audit. Конечная передача пользователю — одна `Golos Meet QA.app` с простой
инструкцией, пустыми отдельными data/settings/models/Keychain и честным пределом
доступных без моделей/ключей функций. Никаких новых диагностических human cases.
