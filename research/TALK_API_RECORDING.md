# API-автозапись и lifecycle — #41

## Решение и границы

Пользователь выбрал PAT + заданные комнаты, поиск себя по email и явное подтверждение userKey. Он всегда входит muted и участвует только с этого Mac. Поэтому участие в API-режиме определяет **только свежий API presence**. IsRunningInput, уровень сигнала и имя окна не входят в условие старта/выхода. Подтверждать каждый звонок кнопкой не нужно. API не устанавливает устройство: один Mac — согласованное допущение пользователя.

Нативный процессный фильтр и готовность обеих дорожек сохранены как условия возможности захвата. Не включаются webhooks/серверная запись/календарь/Constance. Код подготовлен для preview, живой PAT/права/звонок этим PR не проверяются; весь #3 остаётся открыт.

## Включение и runtime wiring

После сохранения комнат и подтверждения аккаунта — явный переключатель «Автозапись по API Толка». Включение валидирует уже сохранённый origin/version/account/rooms и не коммитит drafts. `talk-api-mode.json` хранит только Bool, отдельно от credential/identity. Удаление PAT или смена origin/version оставляет API выбранным, но недонастроенным: **скрытого перехода к legacy нет**. Ошибка чтения режима блокирует автоматику с явным статусом. Выключение переключателя явно возвращает legacy, что написано в UI.

TalkRuntimeSettings проверяет binding сохранённых настроек и строит TalkRoomConfiguration. На запуске/после wake используется новая проверка конфигурации, не старый presence. Перед default store construction/read test-host guard возвращает unavailable. AppCoordinator.start также блокируется в test host; synthetic tests должны явно передать все безопасные зависимости.

AppCoordinator в API-режиме не запускает AudioProcessMonitor/WindowMonitor. Callback от прежде работающего legacy игнорируется. Сохранение PAT/preferences/mode синхронно на MainActor отправляет TalkSettingsChanges; coordinator отменяет старый observer до того, как queued reply сможет запустить старую конфигурацию. Режим синхронизируется и в других открытых окнах настроек без сброса их drafts. Изменения несохранённых полей не меняют фактически действующее подключение; runtime использует сохранённые значения.

## Присутствие, эпизоды и остановка

Один common-runloop timer раз в секунду читает **observer.observation getter**, включая его проверку свежести. Нельзя хранить present бессрочно. Observer обходит комнаты последовательно, не чаще общего PAT-бюджета (2 сек/запрос), следующая итерация через 10 сек после завершения. Цикл старше 30 сек от начала даёт unknown. В API нет дополнительного 30-секундного grace; он остаётся только у legacy. Обычно обнаружение требует порядка 10–30 сек, сеть/429 и длинный обход могут увеличить задержку или оставить unknown.

| Состояние | Действие |
|---|---|
| Полный свежий present, нет записи/финализации/suppression | Один автоматический старт Recorder |
| Present в нескольких комнатах/повторный pulse | Та же запись, без дублей |
| Полный свежий absent | Завершить автоматическую API-запись, штатно передать успешный материал в обработку |
| Unknown/401/403/429/сеть/частичный ответ/stale | Не стартовать новый захват и не считать выходом; текущая запись продолжается |
| Mute/тишина | Не влияют на API lifecycle |
| Native process/capture fault | Принятая failed-финализация, preserveAudio, без автоматической обработки |

Unknown может удерживать запись до ручного stop, свежего absent либо технической границы (сон/config/quit/fault); прекращение звонка без доступного API не угадывается. Меню отдельно показывает продолжающуюся запись с длительностью и неизвестное участие.

Ручной stop/отмена старта ставят suppression. Повторный present, unknown, смена конфигурации и sleep/wake не снимают его. Сброс — только достоверный absent; последующий present — новый эпизод. Явный ручной start/повтор после сбоя доступен независимо. Suppression действует в пределах жизни coordinator, не записывается на диск: новый запуск приложения при включённом режиме начинает новый runtime и может записывать уже идущий звонок **только после свежего API-подтверждения**. Это не восстановление старого cached present.

Ручная запись не завершается от API absent или изменения настроек; её завершает пользователь/технический fault/sleep/quit. Ручной stop сохраняет short-audio protection даже у первоначально автоматического сегмента и сохраняет штатную постановку в обработку. Автоматический успешный короткий сегмент по API absent сохраняет прежний short-filter. Подтверждённый выход и новый вход (включая reconnect, который API успел показать как absent) создают новый сегмент, не параллельную запись.

## Конфигурация, сон, quit

Смена сохранённой конфигурации инвалидирует observer generation. Автоматический сегмент финализируется с preserveAudio=true и без автообработки; новый старт ждёт завершения drain и нового API ответа. Ручной сегмент остаётся под ручным управлением.

В production зарегистрированы [willSleepNotification](https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification) / [didWakeNotification](https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification) через NSWorkspace.notificationCenter, queue main. Sleep: pause observer, stop legacy, сброс legacy latch, финализация любого сегмента с защитой. Wake: повторное чтение сохранённых настроек и configure/resume; даже равная конфигурация начинает новое поколение. Старый ответ после сна не используется.

prepareForTermination синхронно запрещает дальнейшие start/reload/pulse/wake, останавливает observer/legacy/timer и удаляет hooks/menu. AppDelegate затем выполняет прежнюю гонку финализации с лимитом ожидания 3 секунды, теперь с явной защитой interrupted audio. Recorder не изменяет готовность двух дорожек и coalesced drain; preserveAudio можно запросить для технической финализации.

Настоящий сон может приостановить процесс раньше завершения записи на диск: это best effort, исходные start metadata уже защищают аудио, остаётся StartupRescue. Backend, навсегда игнорирующий отмену start, по-прежнему может удерживать stopping; timeout не гарантирует ответ ОС. При неисправном stopCapture физическая остановка захвата не доказана. Эти пределы не объявляются исправленными.

## Проверки и UI

`TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 make check`: **327 passed / 398 запусков / 0 failures / 4 skipped**. Пропуски: native embedding/search с настоящей моделью. ASR E2E исключён. Settings render и native NSMenu render выполнены. Известный QoS warning LocalDocumentExtractorTests; предсуществующие compiler actor warnings ASR/Library/Pipeline, новых warnings изменённых runtime/Talk-путей нет. `git diff --check` успешен.

Synthetic tests проходят настоящий AppCoordinator → TalkRoomObserver → TalkAPIClient(URLProtocol) → Recorder → временные WAV. Другие сценарии используют cancellation-ignoring continuations и manual monotonic clock: unknown/absence, несколько комнат, повторный present, manual suppression, startup failure/explicit retry, cancel/late start, config/key generation, freshness, sleep/wake, quit. Process loss проходит настоящий SystemAudioCaptureTrack + TalkAudioProcessGuard с injected stream/inspection, без SCK/TCC. Mode store tests проверяют fail-closed чтение, version binding, отсутствие fallback, synchronous invalidation, сохранение drafts другого окна и временный файл. Старые OR-тесты относятся только к явно выбранному synthetic legacy; default coordinator заблокирован до побочных эффектов.

[UI-host](talk-runtime-preview/README.md) собран отдельно, без production AppDelegate/coordinator/Recorder/audio/Keychain/библиотеки/ASR/cloud. Через CUA AX+bitmap просмотрены реальный переключатель/подтверждённый аккаунт/пояснения, включение режима в памяти host и обе темы. Видимый текст состояния записи+unknown также получен. **Native popup bitmap/полный осмотр popup не подтверждены**: AX actions работают, native scroll/keyboard CUA возвращали noWindowsAvailable; native NSMenu rows/visibility/button проверены opt-in тестом. Host завершён по точному проверенному PID, обычная app не запускалась. CUA binding занял около 30 минут несмотря на короткий timeout — это предел инструмента, не результат проверки продукта.

Живые PAT, email/room права, настоящий звонок, muted join на устройстве, TCC/дорожки/исключение чужого звука/сон/синхронизация/качество остаются для отдельно выбранного пользователем теста после кодового ревью. Независимый reviewer проверяет текущий SHA; авторская самопроверка его не заменяет. Main и draft #8 не меняются.

## Исправление P2 независимого ревью: два окна

На исходном head `b26dd2f85cf33be5f549b49b56b10fd6b3deb512` reviewer подтвердил stale binding: после смены PAT V1→V2 второе окно сравнивало preferences V1 с собственной cached credential V1. Оно могло заявить включённый API при фактическом api(nil), а затем перезаписать свежие preferences V2 старой версией/аккаунтом. Три регрессии автора воспроизвели это до исправления; точный независимый driver затем повторён на исправленных моделях: старое подтверждение nil, включение false, сохранение false, новая версия и owner-new сохранены.

TalkMeetingSettingsModel теперь обязательно получает authoritative TalkCredentialStoring из родительского TalkConnectionModel. Сохранение комнат, confirm, поиск до запроса и после success/error, переключение режима и сам persist проверяют актуальные origin/token/version. Проверка/запись синхронны на MainActor; защитой не является одно лишь уведомление. При несовпадении/ошибке чтения binding снимается, lookup/revision инвалидируются, прежние карточка/drafts сбрасываются, операция отказывается без записи чужих preferences или mode. UI просит повторно открыть настройки. Новое окно с отсутствующим подключением по-прежнему позволяет явно выключить глобальный API-режим.

Notification refresh также инвалидирует старую credential, вместо обновления одного Bool. При неизменном подключении room drafts сохраняются, но confirmed/readiness читаются из актуальных preferences; сохранение комнат не восстанавливает старый аккаунт из кэша. Delete старого connection window сверяет сохранённый snapshot с текущим store; ответ profile для уже заменённого PAT не помечает новое подключение проверенным. Удаление preferences разрешено только после фактического удаления credential.

`isReadyForAPI` отражает валидную сохранённую конфигурацию отдельно от выбранного режима. В устаревшем окне включённый переключатель сопровождается сообщением о недоступных комнатах/аккаунте и необходимости открыть настройки заново; готовность не заявляется. Это не проверка живых прав API.

После исправления: `TEST_RUNNER_GOLOS_MEET_RENDER_TALK_SETTINGS=1 TEST_RUNNER_GOLOS_MEET_MENU_PREVIEW=1 make check` → **335 passed / 426 запусков / 0 failures / 4 skipped / runtimeWarnings=[]**. Проверены все пять действий (rooms/confirm/enable/disable/lookup) при PAT/origin/delete/read-failure без notifications, оба late reply исхода без notifications, реактивные two-window сценарии, свежая identity в том же подключении и защита от устаревших delete/profile. Standalone model fixtures теперь явно получают synthetic credential stores, без обхода guard. В opt-in render добавлены 2 реальных NSHostingView PNG устаревшего окна, светлая/тёмная тема, оба просмотрены автором; всего 10 settings captures. Synthetic host пересобран build-only, CUA/обычная app/живые ключи не запускались. Прежний предел визуального осмотра native popup не изменился. Новый SHA требует повторного независимого ревью.
