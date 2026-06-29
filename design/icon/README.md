# Иконка golos-meet — слоёвый `.icon` (Icon Composer)

Утверждённый концепт **5А**: графитовый сквиркл + белое речевое облако (мягкий хвост) + акцентная волна. Стиль — новый слоёвый Apple Icon (стекло/глубина), собирается в **Icon Composer** (входит в Xcode 26).

## Слои (в этой папке)
- `Background.svg` — фон, full-bleed градиент #34343c → #17171b → #0c0c0f (158°). Icon Composer сам скруглит и наложит стекло.
- `Bubble.svg` — белое облако со скруглённым хвостом.
- `Wave.svg` — волна, акцент `#0a84ff`.
- `Composed-preview.svg` — как должно выглядеть в сборе (для сверки).

Все слои в едином холсте 1024×1024 и уже выровнены — при импорте просто лягут друг на друга.

## Сборка в Icon Composer (≈2 минуты)
1. Открыть **Icon Composer** (в Xcode: Xcode ▸ Open Developer Tool ▸ Icon Composer).
2. New ▸ имя `AppIcon`.
3. Перетащить слои снизу вверх (порядок = z-order):
   1. `Background.svg`  (нижний слой)
   2. `Bubble.svg`
   3. `Wave.svg`  (верхний)
4. Группа переднего плана (Bubble+Wave): включить **Specular**, **Shadow** (kind: neutral, средняя непрозрачность), при желании лёгкую **Translucency**. Фон — без тени.
5. Проверить вид на светлой/тёмной/моно appearance.
6. **Save** как `AppIcon.icon` в корень проекта (рядом с `golos-meet/`).

## Подключение в проект
- Target `golos-meet` ▸ General ▸ App Icon → выбрать `AppIcon` (`.icon`),
  либо build setting `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` (уже стоит) — Xcode 26 подхватит `AppIcon.icon`.
- Старый `golos-meet/Assets.xcassets/AppIcon.appiconset` можно удалить, чтобы не конфликтовал.

После сохранения `AppIcon.icon` — скажи, я подключу его в проект, соберу и проверю, что иконка встала (Dock/About).

## Палитра (для ручной правки)
- Градиент фона: `#34343c` (0%), `#17171b` (68%), `#0c0c0f` (100%), угол 158°.
- Облако: `#ffffff`. Волна: `#0a84ff`. (Индикатор записи, если решим добавить: `#ff453a`.)
