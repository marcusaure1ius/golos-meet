# #37 · Два подтверждённых P2: final fix preparation

Независимое review43 завершено на frozen prepared `049ff242643240a8bd57006fa1b1ad8ee240fb1b`: два обязательных P2, других обязательных замечаний нет. [Исходный отчёт](review049ff/FINAL_STATIC_REVIEW.md), SHA256 `cf836f79f82144103c0085e9a109fee4fd3e2abc117c5c9d8d838d834d831fbb`; [receipt](review049ff/static-review-receipt.json), SHA256 `4b959a86a76b89d9c42584b7900b9c67b1e169ec532f055bd05a1aa31351ba58`. Копии точные, checkout ревьюера не менялся.

Startup P2 адресован локальным `f152e7daad646e53d8269646db6bea4954d86954`: [описание](../p2-initial-attempt/README.md). Initial needsConsent/attempt NULL отделён от actual UI prepared lease receipt. Этот host source здесь не меняется.

Packaging P2: старый completed bundle фактически вернул strict verify exit1 «code has no resources but signature indicates they must be present». Это отказ статической проверки подписи; запуском отказ macOS не доказан. Только diagnostic mode builder теперь после завершения всех sealed files выполняет ad-hoc sign собственных вложенных Mach-O, затем собственных containers изнутри наружу и корня нового bundle. Symlink/outside targets отклоняются. После signing требуется deep strict verify exit0; commands/stdout/stderr/exit codes и before/after whole binary SHA сохраняются вне sealed bundle. Сравнение executable sections/UUID не выполняется и эквивалентность кода по whole binary hash не заявляется. Внешние linked frameworks/products/runtime не подписываются и не изменяются.

Static assessment проверяет весь protected source против24b, точность старых receipts, сохранность startup fix и AST normal builder после удаления ровно нового diagnostic-only блока. [Оценка](static-assessment.json) не является runtime proof. Production, tests, Rust, Xcode project, Makefile, privacy/deadlines, normal preview и старые bundles/libraries остаются неизменными.

Root разрешил **одну final fix build совместного diff** после final049ff review. Новый уникальный `/private/var/folders/.../T/golos-memory-gate37-*`, новый bundle id, output≤1GiB, elapsed<180s, fresh free≥6GiB+forecast1GiB и STOP<6GiB. Exclusive новый receipt создаётся до preflight; любой preflight/compile/sign/verify/budget failure сохраняется INCOMPLETE и не запускает повтор. Старый build/source/receipt049ff не переписываются и никогда не запускаются. До сборки создаётся чистый code checkpoint; после неё только docs/receipts final SHA для независимого review43 delta.

Никакого launch/CUA/actual held case, full, OCR, матриц, live inference, облака, ASR, новых весов, push или нового PR. Main и remote PR55 не обновляются. Runtime NOT RUN даже при успешных compile/signature checks. Финальное решение о публикации и одном actual UI case принимает root после exact-SHA delta-review; пользователь сейчас не участвует.

Воспроизведение только статического аудита:

```sh
python3 -B research/panel-gate-diagnostics-37/final-fix/prepare.py --check
```

`build_once.py` — одноразовый guarded driver. Его не следует повторно запускать ради проверки; exclusive receipt блокирует следующий запуск. `validate.py` предназначен для чтения сохранённых результатов после этой единственной сборки и не запускает приложение.
