# dsh-спайк над QA-архивом Golos Meet (issue #94)

Спайк: поднять DeepSeek Harness (dsh) локально и написать поверх него два
агентных инструмента над QA-архивом (176 реальных встреч), чтобы решить,
продолжаем на dsh или форкаемся. Сценарий-критерий: вопрос «о чём договорились
по прайсингу за ноябрь?» — ответ агента с цитатами и таймкодами из архива.

## Что здесь

| Путь | Назначение |
| --- | --- |
| `package.json` | пиновка `@deepseek-ai/dsh` версии **0.2.2-rc.1** (npm, MIT, developer preview) |
| `plugins/golos-qa/index.js` | dsh-плагин с двумя инструментами: `search_meetings`, `summarize_meeting` |
| `dsh-patch.yml` | оверлей web-профиля: регистрация плагина, модель OpenRouter `deepseek/deepseek-v4.1-flash`, отключение телеметрии |
| `run-web.sh` | запуск web UI dsh (порт 3080) с ключом OpenRouter из QA-Keychain |
| `test/mock-llm.mjs` | локальный OpenAI-совместимый стриминговый mock-LLM для e2e без ключа |
| `test/dsh-patch.mock.yml` | тестовый оверлей: маршрут openrouter → mock |
| `test/e2e-mock.sh` | e2e-проверка обеих инструментов через mock |

Инструменты работают напрямую с QA-хранилищем
`~/Library/Application Support/golos-meet-qa-b2c0b2c1c6e2413cba82e061cdb9cd97`
(только чтение; рабочее хранилище пользователя не затрагивается):

- **search_meetings** — FTS5-запрос по `knowledge_fts` (join на `embedding_chunks`),
  возврат цитат, таймкодов (`startSeconds`/`endSeconds` из `location`), id встречи
  и заголовка из `meta.json`. Фильтры `since`/`until` (YYYY-MM-DD), шумовые
  пустые сегменты (<5 символов, P3 из #93) отфильтрованы; стратегия AND-запрос
  с fallback на OR и ранжированием по числу совпавших слов.
- **summarize_meeting** — читает `meetings/<id>/transcript.json`, сжимает моделью
  (прямой REST-вызов OpenRouter, модель `deepseek/deepseek-v4.1-flash`).

## Секреты

Ключ OpenRouter живёт в QA-Keychain
(`golos-meet.qa.b2c0b2c1c6e2413cba82e061cdb9cd97` / `openrouter-api-key`) и
передаётся **только** через переменную окружения `OPENROUTER_API_KEY` процесса
dsh (`run-web.sh` достаёт его `security find-generic-password -w` в момент
запуска). Ключ не хранится в файлах, логах и конфигах: `dsh-patch.yml` содержит
только имя переменной (`apiKeyEnv: OPENROUTER_API_KEY`).

## Запуск

```sh
cd research/dsh-spike-94
npm install          # ставит @deepseek-ai/dsh@0.2.2-rc.1
./run-web.sh         # поднимет http://127.0.0.1:3080 (токен печатается в stdout)
```

Первый запуск создаёт профиль `golos` (копия поставляемого web-профиля) в
локальном `.dsh-home/` (вне git). Открыть напечатанный URL
`http://127.0.0.1:3080/?token=…` в браузере и задать вопрос — агент увидит
инструменты `search_meetings` и `summarize_meeting`.

⚠️ Первый доступ к ключу через `security` вызывает диалог macOS: нужно ввести
пароль связки ключей «Вход» и нажать «Разрешить» (или «Разрешать всегда» —
тогда ночные запуски больше не спросят). Без этого шага `security -w` висит.

## Проверки

- **e2e без ключа (mock):** `test/e2e-mock.sh` — поднимает локальный mock-LLM,
  гоняет dsh headless через оба инструмента и проверяет, что реальные цитаты и
  таймкоды из архива дошли до модели (`PASS: search_meetings`,
  `PASS: summarize_meeting`). Полный цикл «профиль → плагин → tool-вызов →
  результат в модель → ответ» проверен этим способом.
- **Маршрут OpenRouter:** с фиктивным ключом dsh доводит запрос до
  `https://openrouter.ai/api/v1` и получает их 401 на невалидный ключ — то есть
  резолв модели `deepseek/deepseek-v4.1-flash` и передача env-ключа работают.

## Известное состояние ночи (2026-11-14)

- dsh 0.2.2-rc.1 (npm dist-tag `latest`) запиннован; web UI на 127.0.0.1:3080
  поднимается и отвечает (HTTP 200 по токену).
- Оба инструмента зарегистрированы и работают end-to-end (mock-e2e зелёный).
- Шаг, оставшийся до полного критерия приёмки: реальный ключ OpenRouter —
  доступ к QA-Keychain упирается в диалог macOS с паролем связки ключей
  «Вход», который должен ввести пользователь. После ввода пароля
  `./run-web.sh` даст полный сценарий с настоящей моделью DeepSeek V4.1 Flash.

## Почему `research/`, а не `tools/`

Это спайк-артефакт для решения «dsh vs форк» (issue #94, фаза 0), а не
продуктовый код: здесь нет сборки в приложение, а `.dsh-home`/`node_modules`
локальны. Продуктовые обёртки (`search_meetings` над гибридным поиском,
consent-слой) переедут в `tools/` по итогам решения — см. план ночного
спринта в #94.
