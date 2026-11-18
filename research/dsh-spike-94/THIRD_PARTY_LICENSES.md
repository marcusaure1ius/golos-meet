# Third-Party Licenses

Спайк `research/dsh-spike-94` (issue #94) использует сторонние компоненты,
перечисленные ниже. Это локальный исследовательский артефакт: в приложение
Golos Meet ничего из него не бандлится. Файл сохраняет нотисы на случай, если
по итогам спайка обёртки переедут в `tools/` и начнут распространяться.

## DeepSeek Harness (dsh)

Пиннованная зависимость `@deepseek-ai/dsh` **0.2.2-rc.1** (npm, developer
preview) — **MIT License**. Полный текст из `LICENSE` пакета:

```
MIT License

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Источник: https://github.com/deepseek-ai/deepseek-harness

## Cordis (плагинное ядро dsh)

dsh построен на Cordis («everything is a plugin»). Пакеты семейства
`@deepseek-ai/cordis` — все **MIT License**, copyright согласно их `LICENSE`:

- `@deepseek-ai/cordis` 4.1.0
- `@deepseek-ai/cordis-plugin-group` 1.1.0
- `@deepseek-ai/cordis-plugin-include` 1.1.0
- `@deepseek-ai/cordis-plugin-loader` 1.1.0
- `@deepseek-ai/cordis-plugin-timer` 1.2.0
- `@deepseek-ai/cosmokit` 1.9.0

Остальные ~80 пакетов `@deepseek-ai/dsh-*` из дерева зависимостей dsh —
тоже MIT (см. группировку ниже).

## Транзитивные зависимости

Полное дерево `npm install` для `@deepseek-ai/dsh@0.2.2-rc.1` — **724 пакета**
(по `package-lock.json` версии 3). Все встречающиеся лицензии — слабые/
перmissive; группировка по метаданным `license` в lock-файле:

| Лицензия | Пакетов | Примечание |
| --- | --- | --- |
| MIT | 596 | включая всё семейство `@deepseek-ai/dsh-*` и `commander`, `js-yaml`, `zod` |
| Apache-2.0 | 71 | включая AWS SDK (`@aws-sdk/*`) и `@smithy/*` |
| BSD-3-Clause | 19 | |
| ISC | 11 | |
| LGPL-3.0-or-later | 10 | прекомпилированные бинарные сборки libvips для `sharp` (`@img/sharp-libvips-*`); в спайке не используются |
| MPL-2.0 | 6 | `@deepseek-ai/libreoffice-kit*` (офисные конвертации dsh); в спайке не используются |
| Apache-2.0 AND LGPL-3.0-or-later (AND MIT) | 4 | прочие платформенные сборки `sharp` (`@img/sharp-wasm32`, `@img/sharp-win32-*`); не используются |
| Python-2.0 | 1 | `argparse` |
| Unlicense | 1 | `fast-sha256` |
| BlueOak-1.0.0 | 1 | `lru-cache` |
| 0BSD | 1 | `tslib` |
| (MIT OR CC0-1.0) | 1 | `type-fest` |

Итого: MIT/ISC/Apache-2.0/BSD — 697 пакетов (~96%); остальные —
опциональные компоненты dsh (libvips/sharp, libreoffice-kit), которые спайк
не импортирует (плагин `golos-qa` использует только встроенный
`node:sqlite` и `node:fs`).

Нотисы всех транзитивных пакетов (версии + источники) при необходимости
распространения собираются из `package-lock.json` — по образцу
`THIRD_PARTY_LICENSES.md` проекта `golos` (таблица на пакет через
`cargo metadata`); для npm-дерева эквивалент —
[`license-checker`](https://www.npmjs.com/package/license-checker) или
чтение `license`/`LICENSE` каждого пакета.

## Не входит

- OpenRouter и модель DeepSeek — облачный сервис по API-ключу из окружения,
  не поставляемый код; отношения регулируются их условиями сервиса.
- Данные QA-архива Golos Meet — собственные данные проекта, не сторонние.
