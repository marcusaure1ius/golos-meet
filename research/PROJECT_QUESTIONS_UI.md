# Интерфейс вопросов по проекту — #35

Refs #35, Refs #5. База принятого preview `a68e62d8a8d9c9ae21cb77f08a1b4cdef1195f6b` (PR48 checked `944350911e8de79f1782625f1d1157975f068b8b`). Отдельная ветка `codex/35-project-questions-ui`, managed worktree `project-questions-ui/golos-meet`. Сервисная ветка не переписывалась. Main и draft PR8 не меняются.

## Пользовательский сценарий

В сайдбаре появился раздел «Вопросы», в выбранном проекте — одноимённое действие. Проект выбирается явно; вопрос ограничен 4000 символов. Для вопроса, не помещающегося в прежние лимиты локального поиска, появляется отдельный короткий запрос (20 слов / 256 символов). Полный вопрос не обрезается и передаётся генератору целиком, что проверено на actual UI model/service/transport payload.

«Подготовить контекст» выполняет локальный retrieval через принятый QuestionService. Preview показывает фактические отобранные snippets, страницу/реплику, владельцев и их режимы, число фрагментов и символов текста/заголовков, предупреждения неполного/недоступного семантического поиска. Объяснено, что кроме этого текста передаются полный вопрос, имя проекта, ссылки и метаданные. Число символов не выдаётся за HTTP bytes или токены.

После полного списка расположен consent/footer и явная отправка. Для askEveryTime кнопка разрешает только конкретный service-preview/instance/session, без сохранения токена в UI. localOnly любого владельца скрывает отправку и показывает запрет. Режим меняется только явным выбором проекта/политики и «Сохранить режим» в нативной sheet; режимы других владельцев не меняются автоматически. Новые встречи/проекты/события памяти не создаются.

Ответ — plain text с проверенными citation-кнопками, статусом недостатка оснований и предупреждением о пределах проверки. Source viewer получает принятый проверенный snapshot, открывает точную PDF-страницу или выделенную реплику, без autoplay. При неудачном открытии старый ответ/согласие очищаются и предлагается новая подготовка. Неизвестная дата источника прямо показана неизвестной; импорт отображается отдельно и не называется датой решения.

## Сессия и production wiring

- KnowledgeQuestionModel немедленно сбрасывает service/request/result/destination при редактировании вопроса, короткого поиска и проекта, отмене, уходе с экрана или новом prepare. Каждый async publish дополнительно проверяет UI generation. Некооперативный fake late reply проверен отдельно от кооперативной отмены Task. Повтор после ошибки снова проходит локальную подготовку и новое согласие.
- Индексные/проектные события production invalidируют активный UI preview/ответ; all-owner/file/source/model gates принятого сервиса остаются последней защитой на transport и postflight. Общая атомарность FS/SQLite/сервер не обещается.
- ProductionKnowledgeQuestions проверяет test-host guard до shared library/runtime/settings/AppPaths/Keychain. Новый экран создаёт модель один раз за жизнь entry, не создаёт encoder на render. Retrieval переиспользует ProductionKnowledgeSearch и существующий общий LocalIndexingService.
- QuestionOpenRouterClient разрешает Keychain.readChecked только на явном send, после test-host guard. Делегирует настоящий OpenRouterClient с beforeSending на каждой его попытке. Нет автоматического облачного запроса из render/prepare. Текущий llmModel берётся из существующих настроек и явно показан в provider label; настройка автоматических insights не превращается в автоматические вопросы.
- Settings-навигация ведёт в существующий экран. На synthetic host она заменена поясняющим callback, real Keychain/client туда не линкуются. Production shell/capture/ASR не запускались ради UI QA.
- Общие ChatMessage/ResponseFormat/LLMError/ChatCompleter перенесены без изменения контракта в самостоятельный ChatCompleter.swift: это позволяет compile настоящих service/model/view в host без конкретного облачного клиента. Probe/preview allowlists синхронизированы с текущими локальными контрактами ProjectStore. Native search probe скомпилирован, отдельно не запускался; остальные CLI modes этим проходом не проверялись.

## Проверки

```sh
TEST_RUNNER_GOLOS_MEET_E5_FOLDER=/tmp/golos-embedding-native/e5-small \
TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 \
TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 make check
```

Финальный результат: **371 passed / 499 запусков / 0 failures / 0 skipped**, macOS27.0.1 arm64; xcresult `Test-golos-meet-2026.11.01_16-08-04-+0300.xcresult`, runtimeWarnings пуст. Первый полный прогон до visual fix также 371/499/0/0, с прежним QoS warning в LocalDocumentExtractorTests. Существующие ASR/Sidecar/Library isolation/AppIntents compile warnings не скрыты. Настоящий ASR E2E исключён; Rust не менялся.

Новые содержательные integration checks используют actual KnowledgeQuestionModel → actual service → temp SQLite/import/retrieval → fake ChatCompleter: запрет общего владельца и явное сохранение политики/restart, отсутствие вызова на prepare, exact request-consent, полный длинный question в payload, project/question/query/cancel late fences, задержанный retrieval, index-event invalidation, noKey/network/invalid/invented/empty/insufficient, retry с новым request ID, source open/back и очищение ответа при stale source. TestHostIsolationTests проверяет nil production composition до доступа к real dependencies.

### Фактическое интерактивное UI

Build-only команда:

```sh
python3 research/build_questions_preview.py --weights /tmp/golos-embedding-native/e5-small
```

Fresh unique bundle `com.golos.questions-preview35.f34fd47c931a4c30a20990e521ef19d0`, root только во временной task-owned папке. Явный allowlist local Knowledge + actual model/view + fake completer, без production AppDelegate/Recorder/ASR/Keychain/OpenRouterClient. Installed public E5 включалась отдельной кнопкой с диска, без скачивания. Данные — authored synthetic PDF/реплика/пустой проект.

CUA выполнил и показал:

- no selected project → Север/question/local prepare → shared-owner denied, fake calls0;
- выбор второго владельца в настоящей sheet → явное askEveryTime save → новый prepare/consent → fake answer → PDF page2 snapshot → back;
- изменённый managed source → отказ открытия и удаление прежнего ответа;
- network/noKey/invalid answer с recovery; отдельный held generation → cancel → release без late ответа;
- held reply → смена проекта → release → пустой проект без чужого ответа;
- missing semantic model с локальным lexical preview; затем настоящая E5 с диска и новый контекст;
- Лира → answer → точная реплика42.5–55сек без autoplay;
- полный вопрос427символов → отдельный short query → локальный prepare без обрезки текста;
- светлая/тёмная темы, generation/cancel/empty/error/denied/source.

Первичная CUA getApp-привязка заняла1062,34с вопреки timeout15с; вернулась без отказа/lock. Это задержка инструмента, не измерение app startup. Последующие действия были короткими. Один сигнал user-changed потребовал свежего AX перед продолжением; отказ разрешений не обходился. После одной visual fix партии тот же bundle/path был последовательно перезапущен (новый temp synthetic root), повторная bind1,48с. При первой повторной сборке Swift упал на дублировании PCM через /var и /private/var; сохранено первоначальное написание module-cache path, сборка прошла. Не создавались параллельные hosts. После QA host закрыт; pgrep по точному executable path вернул отсутствие процесса.

### Отдельный визуальный review

Fresh-context агент просмотрел actual pixels и соответствующий UI code. Два исходных замечания: Send предшествовал полному списку контекста/owners; disabled Prepare выглядел активным. Они исправлены одной партией: consent/Send после snippets, footer cancel, явный disabled opacity только новых primary controls. В ограниченном recapture просмотрены final-consent-after-context, final-generating-footer, final-disabled-prepare, final-long-question-dark, final-denied и final-owner-settings. Оба пункта **resolved**, verdict **ship только в этом визуальном scope**. Это не independent code review итогового SHA и не разрешение merge.

[Скриншоты, полные AX и sanitized UI traces](questions-ui-35/), [проверки и SHA captures](questions-ui-35/checks.json). PNG — actual CUA captures, не ImageGen/макеты. Доисправительные preview/generation сохранены как evidence, финальные начинаются с final-. Обрезанная строка PDF находится в самом synthetic fixture (draw(at:) без переноса); не выдаётся за новый дефект viewer.

## Пределы и передача

Live OpenRouter, production Keychain, реальная запись/ASR, большие архивы и 2–3 пользовательских проекта этим проходом не проверялись. Native tests/host/E5, fake LLM и реальный облачный запрос различаются. Retrieval-spinner переход проверен integration model; в interactive host поиск обычно завершался до следующего AX, отдельно удерживалась генерация, а не retrieval.

#35 и #5 остаются открытыми до независимого code review точного head и приёмки UI/runtime координатором в preview. Автор не сливает PR. История/worker #36/#37, production-redesign19, календарь и Constance не запускались. Main и итоговый draft PR8 остаются без изменений.
