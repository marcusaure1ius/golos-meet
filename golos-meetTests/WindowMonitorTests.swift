import Testing
@testable import golos_meet

@Suite struct WindowMonitorTests {
    @Test func matchesCallWindowsByTitle() {
        // окно встречи (Толк впереди) и PiP-оверлей (Толк на фоне)
        #expect(WindowMonitor.isCallWindow(owner: "Толк", title: "Встреча"))
        #expect(WindowMonitor.isCallWindow(owner: "Толк", title: "ktalk"))
    }

    @Test func ownerMatchVariants() {
        #expect(WindowMonitor.isCallWindow(owner: "Толк Helper", title: "ktalk"))
        #expect(WindowMonitor.isCallWindow(owner: "kontur.talk", title: "ktalk"))
        #expect(WindowMonitor.isCallWindow(owner: "TALK", title: "ktalk"))
    }

    @Test func rejectsNonCallWindows() {
        // главное окно idle Толка — НЕ звонок
        #expect(!WindowMonitor.isCallWindow(owner: "Толк", title: "Толк"))
        // чужое приложение
        #expect(!WindowMonitor.isCallWindow(owner: "Safari", title: "Встреча"))
        // лобби — отдельный заголовок, не считаем оконным сигналом (старт даёт аудио)
        #expect(!WindowMonitor.isCallWindow(owner: "Толк", title: "Подключение к встрече"))
        // nil-ы
        #expect(!WindowMonitor.isCallWindow(owner: nil, title: "ktalk"))
        #expect(!WindowMonitor.isCallWindow(owner: "Толк", title: nil))
    }
}
