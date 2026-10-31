# Synthetic UI API-режима и меню (#41)

Сборка без запуска: `sh research/talk-runtime-preview/build.sh`.

- App: `/tmp/golos-talk-runtime-preview/Golos Talk Runtime Preview.app`.
- Executable: `Contents/MacOS/GolosTalkRuntimePreview`.
- Bundle: `com.golos.talk-runtime-preview`.
- Окно: **Golos Talk Runtime Preview — synthetic**.

Включены реальные settings/model/Palette/MenuBarModel/MenuBarController/RecordingState. НЕ линкуются production AppDelegate/AppCoordinator/Recorder/audio/library/ASR/LLM/Keychain/AppPaths. Keychain/AppPaths stubs fail-fast, mode/preferences/credential — память, lookup/profile — fake. Observer класс присутствует для типов, но не запускается; default transport testHost заблокирован. Никакой реальной записи/сети/рабочих defaults.

Preset confirmed сохраняет синтетические комнаты, показывает выбранный синтетический аккаунт. Прокрутить вниз к переключателю. Он меняет только memory mode и не включает runtime в host. Другие presets показывают missing/empty/loading/multiple/error/invalid. Тёмная тема локальная. Верхние кнопки «Ожидание API», «Запись + unknown», «Подавлен автостарт», «Сон» задают синтетический MenuBarModel; «Показать меню» открывает настоящий NSMenu с пустыми actions.

Осмотр 31 октября: переключатель off/on, подтверждение, пояснения muted/single-Mac, светлая/тёмная тема, запись+unknown текст подтверждены AX+bitmap/AX. CUA.scroll/keyboard вернули noWindowsAvailable; переход вниз выполнен через AX scrollbar.setValue. Popup bitmap/полный visual pass **не подтверждены**. Содержимое реального NSMenu, его hidden rows и status button проверены отдельно MenuBarRenderTests (opt-in).

Host штатно пытались закрыть CUA; из-за недоступного native input завершён TERM по проверенному PID 92857, отсутствие процесса подтверждено. При повторении использовать только уникальный host, не production Golos Meet и не чужие preview. CUA.getApp для нового bundle в этой сессии занял ~30 мин, дальнейший AX доступ быстрый; не повторять blind rebind при подобных задержках.
