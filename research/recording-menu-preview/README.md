# Изолированная проверка меню записи

Этот harness компилирует реальные MenuBarModel/Controller с маленькими подстановками типов RecordingState. Координатор, AppDelegate продукта, детекторы, библиотека, Keychain, ASR, аудио и сеть не линкуются. Действия меню — пустые closures.

1. В корне worktree: sh research/recording-menu-preview/build.sh.
2. Запустить **только напечатанный executable**. Его имя GolosRecordingPreview, bundle id com.golos.recording-menu-preview.
3. Перед CUA проверить уже работающий процесс по этому пути. Выбирать только уникальный bundle id com.golos.recording-menu-preview. Обычную Golos Meet.app не открывать.
4. Кнопками выбрать состояния и открыть «Показать меню». Проверить реальный popup и длительность в status bar. Закрыть окно harness для выхода.

Сборка не запускает harness автоматически и не меняет данные Golos Meet. Этот сценарий проверяет UI, а не живой захват.
