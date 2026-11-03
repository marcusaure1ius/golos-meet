# #67 · Отдельный packaged QA profile

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

Targeted Swift + обязательный `make check` ещё предстоят. Для них используются
собственный DerivedData, fresh space forecast/reserve6GiB, serialized build и
STOP<6GiB. Real ASR E2E исключён штатной целью; opt-in E5/model sessions отключены.
Известный historical failure при full сохраняется и требует root assessment,
не повторного full ради зелёного результата.
