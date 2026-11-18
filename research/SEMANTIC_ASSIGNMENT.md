# Автораспределение без обязательного имени — #45

Основа: принятый PR #46 checked `a44986388fd7934dff5433e7645caa6cabb617d9`, merge preview `070323a7e52ebc5ed5c4c9689f07fcbe6004f2de`. Metadata PR, checked head, ancestry и равенство tree проверены после fetch. Отдельные managed worktree/ветка `codex/45-semantic-assignment`; принятые runtime-ветка и main не менялись.

## Правило v4

`trusted-aliases-margin-e5-v4` работает поверх принятого service/worker и встроенной E5. Буквальное имя больше не является универсальным gate. Для semantic auto нужны cosine ≥0,88, преимущество ≥0,04 перед любым другим проектом для **той же реплики**, минимум три общих предметных термина, из них два встречаются только в trusted context выбранного проекта, и покрытие не менее половины предметных терминов реплики. Если однозначное имя/alias есть в обеих сторонах, сохранён дополнительный маршрут cosine ≥0,90 + два общих термина + тот же margin. Имя само по себе ничего не назначает. M:N строится по отдельным доказательствам разных реплик.

Термины — локальные русские леммы с удалением служебных/общих слов и имён проектов. [Apple NLTagger](https://developer.apple.com/documentation/naturallanguage/nltagger) поддерживает доступные на устройстве схемы lemma; каждый вызов здесь создаёт собственный tagger, общих изменяемых экземпляров нет. `requestAssets` не вызывается, сетевые загрузки не нужны. На этом Mac русская lemma доступна. POS-теги на calibration оказались нестабильны (существительные иногда получали Adjective/Verb), поэтому POS не используется. Неизвестная лемма остаётся поверхностной формой. При отсутствии схемы термины пусты и auto воздерживается; качество других версий macOS отдельно не измерено.

Консервативное воздержание: отрицание/отмена/цитата/учебный пример в любой реплике блокируют auto всей встречи, отрицательный trusted fragment не даёт положительного основания; упоминание другого известного проекта/alias блокирует соответствующую пару. Это конечная лексическая эвристика, не модель понимания отрицаний или достоверности высказывания. Например, «без ошибок» и обычный учебный курс тоже могут остаться предложением.

Прежние имена берутся **только** из явного начального заголовка `Проект <имя>:` в уже проверенном trusted context. Заголовок ограничен 200 символами/шестью словами; auto/proposal-встречи и сама классифицируемая встреча alias не создают. Это нужно, чтобы после переименования прежнее чужое имя в реплике не исчезало из конкуренции. Произвольные псевдонимы по всему тексту не выводятся. Неполный/устаревший trusted context по-прежнему даёт waiting/error, не уверенное решение по усечённым данным.

## Сохранённые контракты

Worker, SQLite schema v6, lifecycle очереди, all-owner scope и открытие проверенных immutable snapshots не переделывались. Service по-прежнему читает весь trusted context и проверяет filesystem/model/checkpoint до commit. Store сверяет тот же versioned confidence predicate вместо старого hardcoded name gate. В сохранённом evidence добавлен optional `support`: общие/отличительные термины, число терминов реплики и blocked. Старые payload без этого поля декодируются; старый algorithm не может публиковаться как новый.

Algorithm и доступность/OS-профиль lemma включены в fingerprint: прежние auto пересчитываются, открытие старого current evidence отказывает при изменении профиля. Ручные M:N/явные Входящие не инвалидируются от новой версии, auto/proposal не становятся обучающим контекстом. CAS, cancel/late result, model/source/file ABA, leases/deadline и stale removal остаются принятыми. 200 проектов / 2000 окон / 100000 операций; новая лексическая подготовка расходует тот же comparison budget и проверяет отмену. Превышение/ошибка не публикует частичный confident результат. NLP не прерывается посреди отдельного bounded window; кооперативная отмена проверяется между ними.

UI показывает общие термины рядом с cosine/margin, называет их эвристикой и объясняет воздержание. Переходы к обеим сторонам evidence и ручной редактор прежние. Новые проекты автоматически не создаются.

## Разделение данных и исходные ошибки

В [assignment-45](assignment-45) сохранены корпуса, SHA, правила, полные сырые результаты и `verify.py`. Calibration и исходный новый evaluation записаны до подбора; `policy-freeze.json` содержит SHA v3, точный historical v3 policy snapshot сохранён отдельно. Пороги 0,88/0,04/0,82 не менялись после просмотра итоговых случаев.

V3 calibration с POS: 4 TP / 0 FP / 3 FN; после отказа от нестабильного POS — 5/0/2. Два пропуска перед похожим складским проектом сохраняются. Первоначальная evaluation v3: 7/0/1, а после переименования **7/1/1**. Чужое прежнее имя потеряло veto; дефект дополнительно воспроизведён на **calibration rename: 4/1/3**. После trusted-header alias fix v4 calibration rename стала 5/0/2. Ошибочные JSON сохранены, не заменены зелёным повтором.

Просмотренная evaluation v3 больше **не считается fresh evaluation** v4: это дополнительный regression (`seen-evaluation-renamed-v4.json`: 7/0/1). Пропуск учебного курса из-за слова «учебный» не исправлялся под этот пример. Для v4 до первого запуска записан новый корпус с другими предметами — светофоры, питомник, морские контейнеры, парковка; его SHA и версия правила в `policy-v4-freeze.json`. Последующие изменения service — только budget accounting и устранение unused binding; hash самого policy совпадает с freeze, итоговые source SHA сохранены в `verified-sources.json`. Пороги/признаки на новой final evaluation не менялись. Это авторские synthetic наборы, а не независимая статистическая выборка.

## Результаты настоящей E5 / SQLite

Везде `deny network*`, публичные pinned веса уже в `/tmp/golos-embedding-native/e5-small`, реальных документов/встреч нет. CLI сам индексирует synthetic документы и manually assigned meeting context, запускает **принятый serial worker** и проверяет фактические persisted owner rows, повтор/unchanged, обе стороны evidence, reindex → снятие auto/отказ старого evidence → recovery, manual Inbox на новой connection и restart worker. `production_wiring:false` честно указывает: production AppDelegate/запись CLI не запускает; bridge проверяется Swift-тестами и отдельным UI.

| Набор v4 | Встреч | TP / FP / FN по связям | Точно совпали встречи | Auto / proposal / новая тема |
| --- | ---: | --- | ---: | --- |
| Calibration | 14 | 5 / 0 / 2 | 12 | 5 / 9 / 0 |
| Calibration rename | 14 | 5 / 0 / 2 | 12 | 5 / 9 / 0 |
| Прежние name controls → regression | 8 | 7 / 0 / 0 | 8 | 6 / 2 / 0 |
| Новая final evaluation | 18 | 9 / 0 / 0 | 18 | 8 / 9 / 1 |
| Та же final после rename | 18 | 9 / 0 / 0 | 18 | 8 / 9 / 1 |

Из шести positive calibration встреч четыре получили **полностью** правильный auto; одна частичный M:N, одна осталась proposal. В regression все 6/6 positive встреч полностью auto, в новой final все 8/8, включая M:N. Отрицательных final встреч 10, ложных auto нет; девять из них имеют предложения из-за низкого proposal threshold 0,82. Близость E5 к общим текстам бывает высокой: предложение не означает уверенной принадлежности. Precision/recall по связям calibration 100%/71,4%, final 100%/100% **только в пределах этого малого набора**. Не переносить эти доли на архив.

В последнем native final прогоне: cold runtime+index 1,299 с; начальный drain 0,775 с; медиана последующего prepare+unchanged commit+открытий обеих сторон evidence **126,66 мс**; peak CLI RSS **1685274624 байт**. Это разные интервалы, медиана не latency первого auto. M4 Pro/24 ГБ, macOS27.0.1, Debug/Onone, disk cache не сбрасывался. Новая лексическая подготовка заметно дороже v2; большого архива и app RSS эти цифры не оценивают.

```sh
TEST_RUNNER_GOLOS_MEET_E5_FOLDER=/tmp/golos-embedding-native/e5-small \
TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 make check
python3 research/build_native_embedding_probe.py --assignment --output /tmp/golos45-native-assignment
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  /tmp/golos45-native-assignment /tmp/golos-embedding-native/e5-small \
  research/assignment-45/final-evaluation.json evaluation /tmp/golos45-final.json --runtime
# Дополнительный проход с переименованием перед worker.start:
# та же команда + --renamed (изменяет только имена в synthetic SQLite).
python3 research/assignment-45/verify.py
python3 research/build_search_preview.py --assignment --weights /tmp/golos-embedding-native/e5-small
```

Полный финальный `make check`: **353 passed / 450 запусков / 0 failures / 0 skipped**, `Test-golos-meet-2026.10.31_23-28-04-+0300.xcresult`, `/tmp/golos45-complete-check.log`, runtimeWarnings пуст. ASR E2E исключён. Существующие compile warnings ASR/Library/Sidecar isolation и AppIntents metadata остаются. Rust не менялся.

Сохранённые неуспешные полные прогоны v4: **351/448 passed +1 failure**, затем **352/449 passed +1 failure** в `indexUpdateBridgeRunsWhileNoScreenIsOpenAndManualEventsDoNotReindex`: `Library unavailable`. Fixture возвращалась из async readiness wait перед assign; отдельный MainActor turn позволял глобальному .projects событию начать reload между проверкой и действием. Исправлено только в тесте: readiness и вход в assign в одном MainActor turn. Production ready/save/reload guards не ослаблены. Итоги всех прогонов — [checks.json](assignment-45/checks.json); прежний v3 full passed не подменяет failures.

Xcode автоматически удалил самый ранний v3 xcresult при следующих запусках: его ранее прочитанные counts сохранены с явной provenance-пометкой, полный старый bundle недоступен. Оба failed v4 и финальный bundle на момент отчёта доступны. Версионируется metadata итогов, не бинарные xcresult.

## Фактический isolated UI

Build-only builder создаёт свежий bundle ID/временную библиотеку, не линкует production AppDelegate/capture/ASR/Keychain/cloud. Финальный host `com.golos.assignment-preview14.934ede809dff462082eff9edd85d350f`, temp `golos-assignment-preview45-k492yhrh`. Визуально и AX проверены waiting без модели → E5 → auto M:N с «для Янтаря» и без имени ИИ; отдельная встреча без имени автоматически получила Янтарь; общие термины/cosine/margin читаемы. Открыты выделенная реплика **00:12–00:30** и trusted TXT ИИ. Отрицание остаётся во Входящих с объяснением; semantic auto вручную возвращён во Входящие, статус manual подтверждён. Проверены loading/снятие прежних auto → cancel → release позднего результата без назначения → retry/auto; повреждение только synthetic копии → error/Входящие → восстановление/auto. Host закрыт, отсутствие процесса подтверждено.

В v3 host также осмотрено auto M:N; финальный v4 проверен отдельно. Финальная UI-сборка предшествует лишь эквивалентному устранению unused binding и test-only readiness fix, policy/UI идентичны. Новый restart через GUI не выполнялся: restart/manual/reindex подтверждены actual native worker/SQLite и Swift-тестами; прежний независимый UI restart принят в #46. CUA bind финального host занял ~20 минут вопреки timeout; это **не** измерение app startup/latency.

## Границы

Это семантический маршрут с лексическим подтверждением, не универсальная классификация по любому парафразу. Чистые синонимы без трёх общих терминов, близкие проекты, переименование без явного прежнего заголовка, отрицания вне словаря и длинные смешанные обсуждения требуют дальнейшей оценки. Глобальный veto может давать лишние proposals. Лемматизация зависит от ОС, неизвестные слова иногда не нормализуются. Большой архив, app RSS/UI latency/живой звонок не измерены. 2–3 реальных проекта по #14/#4 проверяются отдельно на явно выбранных пользователем материалах.

FS/SQLite не атомарны: сохраняются принятые snapshot/повторные проверки, а не обещание абсолютной атомарности. Новых загрузок моделей/облака/секретов/API/календаря нет. #5 не запускался. PR — Refs #45/#14/#4; готовность к preview определяет независимое ревью точного SHA, автор не сливает PR.
