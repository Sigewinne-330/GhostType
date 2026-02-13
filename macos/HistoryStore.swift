import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum HistoryFilter: String, CaseIterable, Identifiable {
    case last3Days = "Last 3 Days"
    case lastWeek = "Last Week"
    case lastMonth = "Last Month"

    var id: String { rawValue }

    var lookbackSeconds: TimeInterval {
        switch self {
        case .last3Days:
            return 3 * 24 * 60 * 60
        case .lastWeek:
            return 7 * 24 * 60 * 60
        case .lastMonth:
            return 30 * 24 * 60 * 60
        }
    }
}

struct HistoryEntry: Identifiable {
    let id: Int64
    let createdAt: Date
    let mode: String
    let rawText: String
    let outputText: String
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []
    @Published var filter: HistoryFilter = .last3Days {
        didSet { reload() }
    }

    private let queue = DispatchQueue(label: "ghosttype.history.sqlite", qos: .utility)
    private var db: OpaquePointer?

    private init() {
        openDatabase()
        createTableIfNeeded()
        reload()
    }

    deinit {
        sqlite3_close(db)
    }

    func insert(mode: String, rawText: String, outputText: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let sql = """
            INSERT INTO history (created_at, mode, raw_text, output_text)
            VALUES (?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return
            }
            defer { sqlite3_finalize(stmt) }

            let createdAt = ISO8601DateFormatter().string(from: Date())
            self.bindText(stmt, index: 1, value: createdAt)
            self.bindText(stmt, index: 2, value: mode)
            self.bindText(stmt, index: 3, value: rawText)
            self.bindText(stmt, index: 4, value: outputText)
            sqlite3_step(stmt)

            DispatchQueue.main.async {
                self.reload()
            }
        }
    }

    func delete(entryID: Int64) {
        queue.async { [weak self] in
            guard let self else { return }
            var stmt: OpaquePointer?
            let sql = "DELETE FROM history WHERE id = ?;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, entryID)
            sqlite3_step(stmt)

            DispatchQueue.main.async {
                self.reload()
            }
        }
    }

    func clearCurrentFilter() {
        let cutoff = Date().addingTimeInterval(-filter.lookbackSeconds)
        queue.async { [weak self] in
            guard let self else { return }
            var stmt: OpaquePointer?
            let sql = "DELETE FROM history WHERE created_at >= ?;"
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return
            }
            defer { sqlite3_finalize(stmt) }
            let cutoffText = ISO8601DateFormatter().string(from: cutoff)
            self.bindText(stmt, index: 1, value: cutoffText)
            sqlite3_step(stmt)

            DispatchQueue.main.async {
                self.reload()
            }
        }
    }

    func reload() {
        let cutoff = Date().addingTimeInterval(-filter.lookbackSeconds)
        let cutoffText = ISO8601DateFormatter().string(from: cutoff)
        queue.async { [weak self] in
            guard let self else { return }
            let sql = """
            SELECT id, created_at, mode, raw_text, output_text
            FROM history
            WHERE created_at >= ?
            ORDER BY created_at DESC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return
            }
            defer { sqlite3_finalize(stmt) }
            self.bindText(stmt, index: 1, value: cutoffText)

            var results: [HistoryEntry] = []
            let formatter = ISO8601DateFormatter()
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(stmt, 0)
                let createdAtText = stringColumn(stmt, 1)
                let mode = stringColumn(stmt, 2)
                let rawText = stringColumn(stmt, 3)
                let outputText = stringColumn(stmt, 4)
                let createdAt = formatter.date(from: createdAtText) ?? Date()
                results.append(
                    HistoryEntry(
                        id: id,
                        createdAt: createdAt,
                        mode: mode,
                        rawText: rawText,
                        outputText: outputText
                    )
                )
            }

            DispatchQueue.main.async {
                self.entries = results
            }
        }
    }

    private func openDatabase() {
        let url = databaseURL()
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        sqlite3_open(url.path, &db)
    }

    private func createTableIfNeeded() {
        let sql = """
        CREATE TABLE IF NOT EXISTS history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            mode TEXT NOT NULL,
            raw_text TEXT NOT NULL,
            output_text TEXT NOT NULL
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func databaseURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = appSupport.appendingPathComponent("GhostType", isDirectory: true)
        return folder.appendingPathComponent("history.sqlite")
    }

    private func stringColumn(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }
}
