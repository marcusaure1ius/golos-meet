# Independent static review · path alias fix fda8a2f1

Reviewer `/root/review43`, non-implementer, отдельный managed worktree. Exact **fda8a2f104501b1f6bcf2b25446342729421dd92**, source/control checkpoint **35c4da62abe23c4de90656525617676d75fbdcf7**. Source/old crashes/receipts не редактировались; author uncommitted state не читался. Currentremote PR55 — acfe44fb379a9ba8de3c0aa5de7fefb9c93bd28f/base23b,draft/unmerged; fda unpublished.

## Verdict

**Нужны два адресных driver fixes перед первым actual compile.** В самом path helper/typed host wiring дополнительных подтверждённых P1/P2 не найдено. Старый AppPaths alias fault содержательно исправлен на source/shared-helper controls уровне; полного host compile/startup/runtime pass нет. Source fda **UNBUILT**, новых app/bundle/binary/manifest/signature assets нет. Старый acfe actual startup failure остаётся фактом, UI gate37/5 не закрыт.

## Confirmed P2 findings

### P2 · build_once.py:24 — incompatible path formats in receipt whitelist

`research/panel-gate-diagnostics-37/path-alias-fix/build_once.py:24` compares repo-relative porcelain lines with `'?? '+str(folder)+'/controls/'`. `folder=Path(__file__).parent` при обычном Python invocation absolute; intended untracked line `?? research/.../controls/` не равна absolute spelling. Поэтому документированный режим committed checkpoint + saved untracked control receipts отклоняется до compiler. Сохранённый failure действительно на этом assert, build_started=false. Но ORIGINAL checkpoint_status и evaluated __file__ не захвачены: историческую причину конкретного запуска нельзя объявлять полностью записанной; post-stop inspection уже содержит results receipt и не подменяет прошлый snapshot.

Направление: вычислить repo root и normalized repo-relative paths, сравнивать структурированный porcelain (желательно -z/untracked-files=all) с точным file allowlist/immutable artifact hashes; reject modified tracked/foreign/unreceipted paths/symlinks. Не allowdirtyall и не широкое разрешение произвольного controls subtree. Записывать исходные status/normalized folder/phase в новый preflight receipt ДО assertion.

### P2 · build_once.py:26 — raw HEAD equality rejects valid preserved controls

`controls.code_head == git rev-parse HEAD` требует, чтобы immutable receipt35c4 был выполнен на текущем commit. На exactfda эти значения уже различаются, хотя helper/host/builder bytes совпадают с35c4. При clean working tree line24 пройдёт all(empty), но line26 гарантированно остановит currentfda. Коммит предстоящего driver fix также изменит HEAD; данное условие нельзя удовлетворять переписыванием старого receipt или ненужным rerun controls.

Направление: сохранить original receipt.code_head35c4 и все его raw hashes; проверить существование/ancestry controlled checkpoint, точную byte identity фактически тестированных helper+harness и combined source с текущими source inputs и git objects того checkpoint. Отдельно record current build code checkpoint/full compile source manifest и reviewed-scope diff. Host wiring/builder35c4 также неизменны на текущемfda и могут быть явно content-bound. HEAD может отличаться только в подтверждённом driver/docs/evidence delta, не по blanket exemption. Source semantic change требует отдельной оценки, не автоматической замены receipt.code_head.

Следующая root-authorized попытка должна получить НОВЫЙ exclusive attempt receipt/namespace. Существующий STOP receipt не удалять/переписывать; FileExists guard сам по себе правильный и не должен обходиться. Это recommendation для одного grouped fix/first actual compile, не разрешение rerun/build.

## Source/helper audit

DiagnosticGatePaths.shared verbatim93lines рассматривается вместе с host. Абсолютные компоненты без . / .. /NUL; только системный /var↔/private/var alias; exact current per-user temp parent, прямой outputchild с golos-memory-gate37- +32lowercasehex; library leaf. Existing temp/output checked by device/inode/owner и canonical existing parent identity; custom links ниже OS alias/output отклоняются. После этого appended absent library проверяется и raw, и canonical spelling; existing file/directory/dangling link не разрешены. Broad /tmp/string prefix fallback отсутствует.

Типизированная installValidatedConfiguration вызывается после testhost guard и ДО GateLog/store/setup; ошибки переходят в INCONCLUSIVE, evidencePath использует безопасный displayPath без accessing uninstalled root. Никакого forceclaim/consent/default real singleton. Internal URL invariant accessor остаётся precondition, но текущий failure flow его не вызывает. Новый helper включён только diagnostic allowlist; normal builder AST при удалении этого insertion совпадает сacfe. Подпись/weakactualmodel/arm-held/request+call/anchor/release/physicalreturn/boundedlogs не менялись этим delta. File checks — snapshots, не atomic openat capability и не защита от конкурентной подмены; это явно документированная граница.

## Independent actual evidence checks

- Hash/git-object audit: exacthelper SHA17e72c66e142e379517bb38d596329d8cf682465b3b719675e03a7712c645c15; host1628d3b018d5f72cc671d4fc034303f392ab0c4954399506e6f4d499572dec4e; builder1ec090093a376a0b61f82981d7840890f79e9019c476ae79e20e9b413bbfd570 совпали currentfda и checkpoint35c4. Helper + newline + harness точно равен preserved combined check.swift/hash878b1deb…d976; standalone использует ТОТ ЖЕ helper, не переписанную модель.
- Все artifact hashescontrols receipt сверены; rawstdout JSON семантически равен control-results.json,13negative actual==expected и3positive same temp/output device+inode+owner/library URL. Original task-owned TEMP check.swift/control-results bytes совпали с committed copies. Все16 результатов действительно представлены, а не только summary/assert strings.
- Сохранённый ONE Foundation invocation actual exit0/2.543869084s/empty stderr,60s/256MiB/free6GiB guards не сработали. Это независимо проверенная авторская evidence; reviewer НЕ перезапускал controls/Swift/compiler.
- 3positive: native/private-root-var-temp/var-root-private-temp.13negative: missing config, leaf/name/prefix suffix, outside/nested/traversal/broadtmp/missing output/reused library/output symlink/dangling library link/foreign fixture link. Эти controls не являются captured LaunchServices environment или host startup pass; branch ownerMismatch/TOCTOU/future interleavings не выдаются за отдельно пройденные.
- Source-only `prepare.py --check` exit0; git diff --check exit0. App/tests/asr/Rust/Xcode/Makefile diff отacfe пуст. Currentfda/sourcecheckpoint35c4 ancestry подтверждена; aftercheckpoint изменены docs/evidence. Старые307+317 output files size/SHA проверены независимо и сохранены; нового asset не возникло.
- Failure receipt не содержит output_root/command/elapsed/compiler pid: build_started=false, driver останавливается до remote/process/space/compile/sign stages. Значения этих этапов не выдуманы. Нынешний success-oriented validate.py не запускался: он ожидает будущий successful build и не может объявить текущий STOP Passed.

## Minimum grouped direction / limits

Исправить только две preflight/provenance guard ошибки, добавить явные pre-assert raw diagnostics и новый immutable attempt path. Не менять прошедший sharedhelper/harness/source и не rerun16controls без новой причины. Затем root отдельно может разрешить первый actual compile текущего helper+host с full source manifest/signature/output/linked input receipts, после чего новый exactSHA/assets требуют delta review ДОlaunch. Настоящий OS startup и один actual UI gate всё равно остаются отдельно.

Reviewer ничего не implement/commit/push/merge/publish и не выполнял build/full/OCR/CUA/launch/новые controls/case/SQLwrites. Предыдущие staticclean и runtime/crash reports не переобъявлены, production feature acceptance не дана.
