import Foundation
import os

/// Тонкая обёртка над os.Logger c единым subsystem.
enum Log {
    private static let subsystem = "com.golos.meet"
    static let detector = Logger(subsystem: subsystem, category: "detector")
    static let recorder = Logger(subsystem: subsystem, category: "recorder")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let asr      = Logger(subsystem: subsystem, category: "asr")
    static let llm      = Logger(subsystem: subsystem, category: "llm")
    static let library  = Logger(subsystem: subsystem, category: "library")
    static let ui       = Logger(subsystem: subsystem, category: "ui")
    static let sidecar  = Logger(subsystem: subsystem, category: "sidecar")
}
