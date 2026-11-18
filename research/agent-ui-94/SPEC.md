# AutoClaw UI — паттерны для чат-оболочки Golos Meet (issue #94)

Дата: 14 ноября 2026. Источник: AutoClaw 2.2.2 (Zhipu AI, `com.zhipuai.autoclaw2`,
Electron + React + Tailwind), bundle `/Applications/AutoClaw2.app`.

**Ограничение метода.** Computer-use (agent.computerUse в node_repl) недоступен
для субагентов в этой среде (`Computer Use is not available in subagent` — hard
запрет в node-repl-host), а `screencapture` без разрешений экрана не работает.
Вместо интерактивного осмотра паттерны извлечены из реального кода рендерера
установленного приложения: JS-бандлы чата
(`Resources/app/dist/renderer/assets/session-history-*.js`, `index-*.js`),
CSS (`zwork-*.css`), i18n-строки (en + ru). Это наблюдения фактического UI,
не догадки; живые скриншоты не прилагаются.

## П1. Один чат-поток вместо панелей

Главный экран — единственная лента (timeline) на виртуализированном скролле
(`react-virtuoso`, `data-testid="virtuoso-scroller"`). Всё, что делает агент,
вставляется в поток сообщениями/блоками, а не уводится в отдельные экраны.
Разделители в потоке: «forked from conversation», «{{productName}} was updated»,
«Context compacted automatically». Внизу плавающая кнопка «Scroll to bottom».

## П2. Сообщения пользователя и агента

- Сообщение пользователя — компактный пузырь на тонированном фоне
  (`--msg-user`), ограничение ширины `max-w: min(560px, …)`, выравнивание
  вправо, перенос строк «anywhere».
- Ответ агента — колонка `msg.agent` с `gap-3`, ширина `max-w: min(768px, …)`,
  паддинг 12px, внутри: имя агента (`msg-assistant-name`), тело сообщения и
  опционально блоки инструментов. Фон не тонированный — агент «говорит в ленте».
- Адрес контента: ограничение ширины ~636–768px по центру, лента не растягивается
  на всё окно.

## П3. Narration — процесс как свёрнутый блок в потоке

Прогресс агента показывается блоком «Process» (aria «Process details»),
который сворачивает служебные шаги и не засоряет ленту:

- События стримятся парами: `tool_activity` с фазами `started|result`
  (toolName, command) и `narration` с `{seq, timestamp, text}` — текстовые
  строки «что я сейчас делаю», сортировка по `seq`, interleaved с инструментами.
- Внутри блока строки narration рендерятся как обычный текст 14px/leading-5
  (`child-process-narration-row`), инструментальные шаги группируются в
  «сегменты» по семейству (`child-process-segment`, `child-process-tool-row`).
- Свёрнутое состояние показывает агрегаты: «{{count}} commands», «Read {{count}}
  files», «{{count}} changes», «Thought for {{duration}}», «{{count}} items».
- Старые шаги прячутся с пометкой «Some earlier steps are hidden» — блок не
  растёт бесконечно.
- Статус работы в реальном времени подписывается поверх ленты: «Currently
  {{activity}}», «Finished {{activity}} and is thinking», «Planning next steps»,
  «Working».

**Вывод для Golos Meet:** narration — первоклассный элемент потока: пока агент
работает, в ленте видны короткие строки «Ищу встречи за ноябрь…», а
инструментальные вызовы собираются в один свёрнутый блок с счётчиками.

## П4. Артефакты — карточки инлайном

- Результаты (файлы, таблицы, документы) появляются прямо в ленте карточками;
  карточка открывает preview-панель (`zwork:artifact-preview`), поддерживает
  виды «Table / Source», экспорт («Exported {{name}}»), диагностику.
- В карточках-инструментах: «Cloud artifact registration», «Files in this task»,
  «Controlled artifact: {{reference}}» — каждый артефакт имеет ссылку на источник
  и статус доступа.
- Ошибки доступа к артефакту честно подписываются: «Artifact read authorisation
  expired», «Artifact integrity check failed» — состояние «неизвестно» не маскируется.

**Вывод:** карточка встречи/конспекта/предложения проекта в Golos Meet —
инлайн-объект потока с заголовком, метаданными (дата, проект, источники) и
действиями (открыть, копировать), без перехода на другой экран.

## П5. Разрешения и согласие — кнопки в сообщении

- Карточка «Needs your confirmation» (askUser): варианты ответов кнопками,
  «Other answer» со свободным текстом, «Next question», «Your answers»,
  «No responder» для отказа. Ответы возвращаются агенту в тот же поток.
- Карточка «Plan confirmation» (visiblePlanReview): план шагов + «Confirm and
  start» / «Adjust the plan» / «Skip» / поле «Plan changes».
- Карточка безопасности (safetyApproval): «High-risk operation detected.
  Confirm to continue.», причина, раскрывающаяся команда («Expand»/«Collapse»),
  кнопка «Allow»; срок действия согласия: «Approval expired; the action did not run».

**Вывод:** consent-слой #37 ложится на паттерн askUser — разовое согласие это
сообщение-карточка с кнопками, не модал.

## П6. Композер — минимальный ввод

- Одно поле ввода с кнопкой «Add» (меню: «Add attachment»), рельсой вложений
  (pending attachments, remove по имени, поддержка папок) и чипом контекста
  проекта (`zwork-composer-context-project`) — контекст виден до отправки.
- Кнопка действия морфится: «Send» → «Stop» → «Stopping» во время работы агента.
- Черновик сохраняется («Draft save failed, but the message was sent» — черновик
  не теряется даже при ошибке).
- Начальный экран: крупный заголовок «{{suffix}} with {{productName}}» со
  сценариями (Code/Design/…) и стартовыми агентами (Analyst, Planner, Executor,
  Doc writer, Data visualizer) как карточки-подсказки.

## П7. Chrome минимальен

- Сайдбар: список чатов/задач (sessions), «New chat», пин/архив чата, агенты;
  сворачивается («Expand sidebar»). Основная площадь отдаана ленте.
- Дисклеймер под ответом: «Content generated by AI. Verify key information.»
- Действия сообщения: «Copy answer», «Copy code», «Retry», «Branch» (fork).
- Тема: светлые токены `--theme-panel #fff`, `--theme-text #292929`,
  `--theme-bg-sub #f5f5f5`, `--border-default #f0f0f0`, `--link #249dff`;
  второстепенный текст `text-muted-foreground`/`text-[--text-tertiary]`;
  анимации 0.2s ease, сворачивание блоков 240–280ms cubic-bezier(.23,1,.32,1).

## П8. Состояния и честность

- Ошибки инструментов не роняют ленту: карточка с конкретной причиной
  («Approval expired», «Target file already exists…», «Network or proxy
  connection failed») и продолжение работы.
- Состояние «обрабатывается» всегда видимо («In progress», elapsed time,
  «Verifying goal»), статус-строка беседы (`--conversation-status-*`).
- Повтор/продолжение: «Retry», «Reconnecting», «Retry» — после сбоя агент
  сам предлагает продолжение.

## П9. Применимость к чат-оболочке Golos Meet

1. Экран «Агент» = один поток + композер; сайдбар получает пункт первым,
   остальной UI не трогаем.
2. Narration-строки агента — отдельный элемент потока (второстепенный цвет,
   12–13px), инструментальные шаги агрегируются в свёрнутый блок с счётчиками.
3. Артефакты — карточки инлайном: «Встреча», «Конспект», «Предложение проекта»;
   у карточки источник (встреча/документ), действия и честный статус.
4. Разовое согласие (#37, W4) — сообщение-карточка с кнопками; в W3
   зарезервировать компонент действия в сообщении.
5. Композер: поле + отправка/стоп, контекст-чип проекта, вложения позже.
6. Палитра — дизайн-язык `golos` (см. существующие экраны), не копия AutoClaw:
   берём структуру (один поток, narration, карточки), а не их токены.
7. Поверхность нативная (SwiftUI): реальный агент (dsh-рантайм W1) подключается
   за один слой — модель потока: `AgentChatItem` = `.narration` / `.message` /
   `.toolSteps` / `.artifact(вид)` / `.action(согласие)`.

## П10. Иконки: SF Symbols (фолбэк, решение задокументировано)

Генерация иконок через Codex CLI не удалась: модель по умолчанию (`gpt-6.1-sol`)
и все проверенные альтернативы (`gpt-5.1-codex`, `gpt-5.1`, `gpt-5-codex`,
`gpt-5`, `o4-mini`, `gpt-5.1-codex-max`, `gpt-5.1-codex-mini`, `gpt-4.1-mini`)
отклоняются API («model is not supported when using Codex with a ChatGPT
account»); один прогон `codex-mini-latest` прошёл, далее стабильно та же ошибка —
CLI в этой учётке неработоспособен. Использованы SF Symbols как заглушки,
что совпадает с существующей дизайн-системой приложения (`GNavRow` и все
экраны — монохромные SF Symbols): `sparkles` (агент), `waveform` (встреча),
`doc.text` (конспект), `folder.badge.plus` (предложение проекта), `arrow.up` /
`stop.fill` (отправить/стоп). Генерированные SVG-иконки можно подключить
отдельной задачей как набор символов (asset catalog), не ломая текущие экраны.

Скриншоты нативного экрана: `research/agent-ui-94/*.png`
(env-gated тест `AgentChatTests/renderActualAgentChatStatesWhenExplicitlyRequested`,
переменная `TEST_RUNNER_GOLOS_MEET_RENDER_AGENT_CHAT`).
