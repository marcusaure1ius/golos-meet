# Изолированная проверка меню записи

Этот harness компилирует реальные MenuBarModel/Controller и перечисление сообщений TalkAudioCaptureError с маленькими подстановками типов RecordingState. Координатор, AppDelegate продукта, детекторы/монитор процессов, библиотека, Keychain, ASR, аудио и сеть не линкуются. Действия меню — пустые closures.

1. В корне worktree: sh research/recording-menu-preview/build.sh.
2. Запустить **только напечатанный executable**. Его имя GolosTalkSourcePreview, bundle id com.golos.talk-source-preview.
3. Перед CUA проверить уже работающий процесс по этому пути. Выбирать только уникальный bundle id com.golos.talk-source-preview. Обычную Golos Meet.app не открывать.
4. Кнопками выбрать состояния и открыть «Показать меню». Дополнительные сценарии: «Нет Толка», «Источник исчез», «Ошибка доступа». Проверить реальный popup и длительность в status bar. Закрыть окно harness для выхода.

Сборка не запускает harness автоматически и не меняет данные Golos Meet. Этот сценарий проверяет UI, а не живой захват.
