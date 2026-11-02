# Независимое static review diagnostic host

Reviewer `/root/review43`, не implementer host. Самостоятельный review worktree, frozen exact **049ff242643240a8bd57006fa1b1ad8ee240fb1b**, compiled checkpoint **fcdd8837d3163bf9aba9274b0c66449e14a11940**. Feature source24b49b067fcda107e397ed4f2461f9bb23de322f/accepted23b — ancestors. Current GitHub PR55 всё ещё24b/base23b,draft/unmerged: этот prepared SHA ещё не remote PR head. Авторский uncommitted fix не читался. Трекер/AGENTS/CLAUDE/план4/golos-review/issue37+5, весь20file research diff и production consumers прочитаны. Production app/Swift tests/asr/Rust/project/Makefile byte-diff от24b пуст.

## Вердикт: НУЖНЫ ИСПРАВЛЕНИЯ ПЕРЕД ЗАПУСКОМ

### P2 · Fresh setup не может пройти guard

`research/MemoryPanelGateDiagnostics.swift:335` требует nonempty attempt сразу после worker.start/waitUntilIdle, до появления actual panel/prepare. В fresh seed North askEveryTime. `MemoryQueueSQL.input` Store195 возвращает needsConsent; reconcile INSERT Store48 не задаёт attempt, значитNULL. Background claim Store74 выбирает только queued/partial/backpressured, needsConsent не трогает. Поэтому sample.job.attempt, прочитанный COALESCE(...,'') diagnostic reader, пустой. Actual UI prepare ещё недоступен, phase preparing. Host неизбежно fail setup fresh seed/needsConsent baseline. Compile и marker-based offline validator этого не проверяют.

Направление: initial seed baseline должен быть needsConsent/attempt empty/no physicalcalls/history0. Проверку nonempty preview lease/key сохранить ПОСЛЕ настоящего UIprepare, перед observed send marker. Не forceclaim/queued/artificialconsent и не ослаблять production guards. Доказательство — цепочка actual unchanged store/worker source; runtime не запускался.

### P2 · Готовый bundle не проходит signature gate

`research/build_memory_panel_preview.py:96` копирует Resources после swiftc, затем завершает без финального bundle signing/verify. Фактическая readonly команда `/usr/bin/codesign --verify --deep --strict '<output>/Golos Memory Gate Diagnostics.app'` вернула **exit1**, stderr **code has no resources but signature indicates they must be present**. Это проверенный отказ signature validation, а не доказанный запуском отказ LaunchServices/macOS.

Направление: корректно запечатать finished diagnostic bundle после всех ресурсов, проверить verify0 и записать новые post-sign whole binary/output hashes; signing может изменить Mach-O layout, поэтому при сравнении executable кода использовать sections/UUID и явно не выдавать whole-file hash equality. Ограничить этим diagnostic mode; менять production или normal preview не требуется. До исправления static packaging gate запуск не одобрен.

## Остальной статический механизм

Исследован581line helper целиком. Arm actor сначала сохраняет state, затем ACK; held ACK только после continuation installation, с token/call/request/payload bindings. Synchronous Published request=nil при busy=true записывается до создания model.operation Task; invalidate сначала busy=false и не называется consent. Initial project emission пропускается; actual model factory/entryUUID и weak subscriptions отделены от старой hidden state.model. Разные entry/model/old weaknil и new canApprove дают узкую проверяемую границу idle, не подменяются waitUntilIdle.

Source ordering resume SQL transaction COMMIT→process task/active/timer подтверждён. Fresh needsConsent sample до send marker, matching first-running и cancelled READEND<20s от sampleBEGIN являются консервативным anchor относительно production30s. SQL samples не атомарны сUI/actor; bounds/observer effect явно сохранены. Выбор проекта остаётся actual Picker, автоматической смены/cancel в success path нет. Durable synced cancellation proof предшествует diagnostic release, adapter намеренно возвращает late valid reply и записывает physical-return boundary. Final proof дополнительно требует history0,old weakmodelnil,new freshrequest/canApprove and new attempt. Непосредственный Task.value approval API отсутствует и это честно отражено.

Logger имеет event/byte guards/reserve, write+sync, отдельный pending final, final name только после close/sync. Overflow/write/read/binding/time ошибки — INCONCLUSIVE; cleanup отдельно снимает owned continuation/закрывает наблюдения, не становится доказательством project cancellation. Runtime поведение, UI ordering и eventual weakrelease статикой не считаются Passed.

## Independent checks / provenance

- Собственный read-only manifest/git-object audit: **59source files**,10compiled object inputs/11linked inputs,**307actual output files**, все размеры/SHA совпали с preserved receipts/current exact compiled checkpoint. Бинарь SHA3fe0e3b68bcbbd08c8f73e7f8a928994f73e2b6c04eddf62a328a148b0f4980c.
- Offline validator exit0; git diff --check exit0. Это provenance checks, не semantic startup/case pass.
- Один сохранённый авторский build действительно exit0/37.436s,334724977B,74space samples/min91202404352B,0compiler warning/error lines. Guard6GiB/1GiB/180s не сработал. Мой новый build/full/OCR/модель не запускались.
- Plist содержит unique diagnostic bundle, SourceCommit/manifest hash, разрешённый fresh /private/var/folders/.../T/golos-memory-gate37-.../library, без PublicWeightsFolder. Runtime library фактически отсутствует. AppRuntime GOLOS_MEET_TEST_MODE выставлен custom main до App/StateObject; actual sources exclude productionAppDelegate/factory/OpenRouterClient/Keychain/Recorder/ASR/player. Synthetic2D/fake толькоsetup, без PDF/OCR/ONNX inference.
- Normal builder mode сохраняет прежние explicit weights/reuse/resume и sources; новая diagnostic branch freshroot/forbidreuse/nounauthorisedlaunch. Старые evidence/seed не удаляются. При corrected SHA затронутые paths/build receipts требуют delta review.

Никаких source fixes/commits/push/review publication/merge/launch/CUA/case. Code verdict24b/full478/676 остаётся только для unchanged production; новый diagnostic runtime NOT RUN и по049ff не разрешён. UI gate37/5 не закрыт; historical56/61 не объяснены.
