import AppKit
import Foundation
import OSLog

enum LogType {
    case debug
    case info
    case warning
    case error

    var prefix: String {
        switch self {
        case .debug:
            return "[DEBUG]"
        case .info:
            return "[INFO]"
        case .warning:
            return "[WARN]"
        case .error:
            return "[ERROR]"
        }
    }
}

extension LogType {
    var osLogType: OSLogType {
        switch self {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .default
        case .error:
            return .error
        }
    }
}

struct AppLogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let type: LogType
    let message: String
    let file: String
    let function: String
    let line: Int

    var formatted: String {
        "[\(timestamp)] \(type.prefix) [\(file):\(line)] \(message)"
    }
}

final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var entries: [AppLogEntry] = []
    @Published var logText: String = ""

    private init() {}

    func log(
        _ message: String,
        type: LogType = .info,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let shortFile = String(file.split(separator: "/").last ?? Substring(file))
        let entry = AppLogEntry(
            timestamp: timestamp,
            type: type,
            message: message,
            file: shortFile,
            function: function,
            line: line
        )

        DispatchQueue.main.async {
            self.entries.append(entry)
            self.logText += entry.formatted + "\n"
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
            self.logText = ""
        }
    }

    func copyAllToPasteboard() {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.logText, forType: .string)
        }
    }
}

final class UnifiedLogger {
    private let osLogger: Logger
    private let appLogger: AppLogger

    init(subsystem: String, category: String, appLogger: AppLogger = .shared) {
        self.osLogger = Logger(subsystem: subsystem, category: category)
        self.appLogger = appLogger
    }

    func log(_ message: String, type: LogType = .info) {
        osLogger.log(level: type.osLogType, "\(message, privacy: .public)")
        guard type == .error || type == .warning else { return }
        appLogger.log(message, type: type)
    }
}
