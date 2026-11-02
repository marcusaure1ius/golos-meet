# PR60 P2 · Одноразовое принятие native SQLite fault

## Исправление

Независимое ревью head `5446d7dfaff87f8cd97256340960b20dc293a874` подтвердило P2: внутреннее `expectingFailure` принимало единственный fault, а внешнее повторно находило этот raw event. Его `count==1` проходил, хотя из pending failures ничего больше не было принято. [Исходный reviewer probe](results/reviewer-probes.swift.txt) и [красный summary](results/reviewer-before-summary.json) сохранены.

Теперь поиск исключает raw events с `expected=true`. Проверяется **успешное принятие одного ещё не принятого fault**, а не одно совпадение: должны существовать и новый unconsumed event, и его pending diagnostic. Под одним lock событие помечается `acceptedBy=<expectation UUID>`, удаляется из pending failures и получает один marker с исходным eventIndex. Checked event отдельно фиксирует matchingUnconsumed/accepted. Raw diagnostics и stdout не удаляются.

Nested API остаётся поддержан: у внешнего и внутреннего ожиданий должен быть собственный fault. Два реальных faults работают и при внешнем fault до inner, и после inner. Идентичность connection/phase/operation/result/extended и границы синхронной операции сохранены. Production/Rust diff по-прежнему пуст, fixtures других семейств не менялись.

## Native before и контроли

Один и тот же `SQLiteFaultExpectationTests.swift` выполнен на frozen pre-fix5446d7d в собственной temporary copy и на исправленном helper. [Receipt](results/before-receipt.json) фиксирует SHA обоих источников; `prepare_before.py` не редактирует рабочую ветку или чужой checkout.

- Pre-fix suite:6 functions /13 cases. **2 failing functions /3 failing runs**: nested single-fault не дал обязательную rejection issue; два настоящих nested faults, напротив, ломали внешний count. Это actual SQLite UPDATE/result19/extended1811, без VFS/error replacement.
- Fixed targeted + исходные question/history и предыдущие controls:31 tests /72 runs. **29 ordinary passed tests +2 tests с ожидаемыми negative issues;65 passed runs +7 expected negative runs;0 unexpected failures/skips/runtime warnings**.
- В missing-outer control один raw fault, один expected marker, два checks: inner accepted=true, outer matchingUnconsumed=0/accepted=false. Ровно одна helper assertion обязана быть зарегистрирована.
- Positive nested control: два faults, два разных eventIndex и expectation IDs; оба порядка before-inner/after-inner Passed.
- Cardinality controls0/2, foreign/late/extra, wrong operation/code/phase проверяют отказы. Thrown body сохраняет Sentinel error.12 перекрывающихся scopes держат разные actual native connections, без cross-attribution.

[Swift Testing withKnownIssue](https://developer.apple.com/documentation/testing/withknownissue(_:isintermittent:sourcelocation:_:when:matching:)) применяется только в новых negative controls, которые **обязаны** зарегистрировать assertion отказа. Matcher принимает лишь expectationFailed из `SQLiteFixtureScope.swift`, а confirmation требует ровно одну issue. Конструирование/open/SQL assertions происходят вне этого разрешения либо в другом source file; ошибки тела не принимаются matcher. Если helper ошибочно пропустит missing fault, тест падает с knownIssueNotRecorded/confirmation miscount, как actual before. Это не разрешение unexpected failures исходных тестов и не suppression stdout.

## Полный check: красный, без повторения до green

Завершён один actual full `make check DERIVED_DATA=/private/tmp/golos58qh-derived` с existing public E5 и settings/menu opts:

| Уровень | Passed | Failed | Expected negative | Skipped |
|---|---:|---:|---:|---:|
|443 tests|436|5|2|0|
|625 parameter runs|610|8|7|0|

Runtime warnings0. **Статус Failed**, обязательный final gate не объявляется пройденным.

Failing functions:

- DocumentFormatImportTests actual PNG import: e5rt13.
- LocalDocumentExtractorTests concurrent PNG и обычный PNG: e5rt13.
- LocalDocumentExtractorTests mixed PDF: exact-line count0.
- ProjectMemoryQueueTests concreteMetadataBridge: **metadata bridge ready-source coverage**,5s; initial-snapshot marker был достигнут, complete marker не записан. [Activities](results/bridge-activities.json) и scope trace сохранены. Это уточнение стадии, не установленная причина; timeout и production behavior не меняются.

Независимый pre-fix full60 также был красным:434 passed/3 failed tests,605 passed/7 failed runs,0skips/runtime warnings. [Его summary](results/reviewer-full-summary.json) и [stdout](results/reviewer-full-stdout.txt.gz) сохранены отдельно. Старый author437/612 green сохранён как исторический результат, не отменяет ни reviewer red, ни новый red.

Full native ledger: **177 roots,294 opens,294 close=0,177 removals**,0 teardown timeout.30 exact allowance checks:23 accepted once,7 deliberate rejected.34 raw SQLite faults сохранены, в том числе negative controls; не объявляются исчезнувшими.177 scoped JSON attachments совпали с actual xcresult bytes. **82 OCR attachments /41 invocations** включают точные synthetic PNG/PDF bytes+SHA, output/errors/warnings; [аудит](results/attachment-audit.json), deduplicated inputs — `results/ocr-assets/`. Новых OCR-проб не выполнялось; это сохранение результата обязательного full.

Whole completed bundle сохранён локально: `/private/tmp/golos60-p2-preserved-full.xcresult`. Exported diagnostics и original attachments — `/private/tmp/golos60-p2-final-full-diagnostics` и `/private/tmp/golos60-p2-final-attachments`. Целые системные archives в git не включены. Full stdout содержит38 vnode messages других fixtures:assignment13/questionsUI15/search5/index-service5; counts недетерминированы, это не расширение scope и не готовый58.

## Среда и discarded попытки

[Limitations](results/attempt-limitations.json) сохраняют следующие границы:

- Первый sandbox targeted вызов завершился до тестов из-за запрета cache writes. Authorized targeted завершился с приведёнными выше результатами.
- Первый full вызов оборвался exit2 во время dependency build; completed reader отсутствует, Info.plist bundle не записан, тесты не стартовали. Лог сохранён; по неполному логу точная причина не установлена. Обязательный actual full затем выполнен в уже собранном собственном DerivedData. Завершённый красный OCR full **не повторялся**.
- Первый selector отдельного Swift Testing метода выбрал0 тестов. Его command success отброшен как доказательство. После этого выполнена вся frozen before suite с указанными actual failures.
- В ходе работы Data volume наблюдался с примерно1.8GiB свободного места; координатор отдельно зафиксировал реальный ENOSPC, затем освободил только воссоздаваемые build products до примерно11GiB. Per-OCR free-space telemetry нашего full нет. Период disk pressure/recovery — существенное ограничение, **не доказательство причины** прежних или текущих e5rt13/bridge timeout.
- После сообщения координатора не запускались новые builds/full/OCR. Фактический final mandatory gate после стабилизации среды остаётся отдельным решением координатора. Системные Vision caches, production fallback/timeout и новые модели не менялись.

## Проверка evidence и дальнейший шаг

```sh
python3 -B research/question-history-fixtures-58/p2-single-use/validate.py
```

Validator пересчитывает single-use eventIndex→expectation, native close-before-unlink, before/targeted/red-full counters, exact source hashes и input SHA всех41 OCR invocations. Raw case bytes сохранены gzip JSON map filename→original UTF-8 text. Путь и смысл инфраструктурных попыток не смешиваются с actual native before/after.

Повторные тесты после восстановления среды здесь автоматически не запускаются. P2 передаётся на delta-review нового точного SHA по уже выполненным targeted/native controls и actual red full. Остальные семейства58, originalOCR56 и bridge cause остаются отдельной работой. Main/PR8draft/чужие checkout неизменны; автор не сливает PR. Пользовательские материалы/audio/реальные Keychain/live cloud/capture/ASR не использовались, веса не скачивались.
