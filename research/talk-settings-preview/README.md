# Изолированная проверка настроек Толка (#40)

Сборка: `sh research/talk-settings-preview/build.sh`.

Выход: `/tmp/golos-talk-settings-preview/Golos Talk Settings Preview.app/Contents/MacOS/GolosTalkSettingsPreview`.
Bundle ID: `com.golos.talk-settings-preview`. Окно: **Golos Talk Settings Preview — synthetic**.

Скрипт только собирает. Для ручного осмотра запустить именно этот executable/app; обычную Golos Meet/Debug app не запускать. Уникальные имя/ID позволяют не привязать CUA к production. После проверки завершить этот host через его меню Quit. Не закрывать чужие preview-процессы.

Host компилирует реальные TalkConnectionModel/TalkMeetingSettingsModel и SwiftUI settings/design-system, но не production AppDelegate, AppCoordinator, audio, библиотеку, ASR/LLM или production Keychain/AppPaths. Credentials и preferences хранятся в памяти, lookup/profile подставные. Default lookup заблокирован флагом testHost; любые попытки обратиться к stub Keychain/AppPaths заканчиваются fail-fast. Синтетический PAT/почта/комнаты не относятся к реальному пространству. Рабочие defaults/Keychain/записи не используются.

Кнопки верхней панели:
- missing — несохранённая замена ключа, rooms/lookup заблокированы;
- empty — пустой API-результат;
- loading — отложенный подставной lookup, есть «Отменить»;
- multiple — два одноимённых пользователя с разными login/email/key;
- error — безопасная ошибка 403;
- confirmed — явное подтверждение синтетической карточки;
- invalid — комната другого origin, ошибка строки и неактивное сохранение;
- «Тёмная» — переключение palette/colorScheme только этого host.

Настройки длиннее окна, поэтому прокрутить к секции «Мой аккаунт» при осмотре результатов. Кнопки поиска/сохранения/подтверждения используют настоящую модель, но меняют только память host. Смена preset создаёт новую модель/память.

31 октября выполнены два ограниченных прохода: осмотр состояний с AX + bitmap в светлой/тёмной теме; после исправления same-value invalidation и disabled opacity — подтверждение финального UI, реальная кнопка сохранения комнат, выбор карточки и отмена loading. Финальный host завершён, отсутствие его процесса проверено. Это synthetic UI, не проверка живого PAT, сетевых прав или звонка.
