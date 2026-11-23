import Foundation
import SQLite3
import XCTest

/// SQLiteMemoryBackup.serializedCopy の検証。source・復元先ともに :memory: だけを使い、
/// ファイル作成・OSのtemporary directory・アプリ起動は行わない。
/// SQLiteレベルのbackup/serializeのみを検証しており、SwiftDataの移行や復元を証明するものではない。
final class SQLiteMemoryBackupTests: XCTestCase {
    /// 比較用にSQLiteの値を型ごとに保持する。
    private enum SQLValue: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    private static let createTableSQL = """
        CREATE TABLE sample (id INTEGER PRIMARY KEY, name TEXT, amount REAL, payload BLOB);
        """
    // nil(NULL)・0・Unicode・複数行を含む合成データ。実記録は含まない。
    private static let insertRowsSQL = """
        INSERT INTO sample (id, name, amount, payload) VALUES
            (1, 'ベンチプレス 🏋️‍♀️', 0, NULL),
            (2, NULL, NULL, x'00FF10'),
            (3, 'Ünïcødé ✓ 漢字', 0.0, x''),
            (4, '', -12.5, NULL);
        """
    private static let expectedRows: [[SQLValue]] = [
        [.integer(1), .text("ベンチプレス 🏋️‍♀️"), .real(0), .null],
        [.integer(2), .null, .null, .blob(Data([0x00, 0xFF, 0x10]))],
        [.integer(3), .text("Ünïcødé ✓ 漢字"), .real(0), .blob(Data())],
        [.integer(4), .text(""), .real(-12.5), .null],
    ]

    func testSerializedCopyRoundTripsSyntheticRowsIntoSeparateMemoryDatabase() throws {
        let source = try Self.openMemoryDatabase()
        defer { sqlite3_close_v2(source) }
        try Self.exec(source, Self.createTableSQL + Self.insertRowsSQL)

        let data = try SQLiteMemoryBackup.serializedCopy(of: source)
        XCTAssertGreaterThan(data.count, 0)

        let restored = try Self.deserializeIntoNewMemoryDatabase(data)
        defer { sqlite3_close_v2(restored) }
        XCTAssertEqual(try Self.integrityCheck(restored), "ok")
        XCTAssertEqual(try Self.selectAll(restored), Self.expectedRows)
    }

    func testSerializedCopyIsIndependentOfLaterSourceChanges() throws {
        let source = try Self.openMemoryDatabase()
        defer { sqlite3_close_v2(source) }
        try Self.exec(source, Self.createTableSQL + Self.insertRowsSQL)

        let data = try SQLiteMemoryBackup.serializedCopy(of: source)
        let snapshotBytes = Data(data) // 返却Dataの内容が後から変わらないことの比較用

        let restored = try Self.deserializeIntoNewMemoryDatabase(data)
        defer { sqlite3_close_v2(restored) }

        // sourceを変更しても、取得済みバックアップと復元先DBには影響しないこと。
        try Self.exec(source, """
            UPDATE sample SET name = 'changed', amount = 99 WHERE id = 1;
            DELETE FROM sample WHERE id = 2;
            INSERT INTO sample (id, name, amount, payload) VALUES (5, 'added', 1, NULL);
            """)
        XCTAssertNotEqual(try Self.selectAll(source), Self.expectedRows) // 変更が実際に効いた前提の確認

        XCTAssertEqual(data, snapshotBytes)
        XCTAssertEqual(try Self.selectAll(restored), Self.expectedRows)

        // 同じバイト列から別のメモリDBへ再度復元しても元の内容であること。
        let restoredAgain = try Self.deserializeIntoNewMemoryDatabase(data)
        defer { sqlite3_close_v2(restoredAgain) }
        XCTAssertEqual(try Self.integrityCheck(restoredAgain), "ok")
        XCTAssertEqual(try Self.selectAll(restoredAgain), Self.expectedRows)
    }

    func testSerializedCopyLeavesSourceConnectionOpenAndUsable() throws {
        let source = try Self.openMemoryDatabase()
        defer { sqlite3_close_v2(source) }
        try Self.exec(source, Self.createTableSQL + Self.insertRowsSQL)

        _ = try SQLiteMemoryBackup.serializedCopy(of: source)

        // ヘルパーはsourceの所有権を持たないため、呼び出し後もsourceを使い続けられること。
        try Self.exec(source, "INSERT INTO sample (id, name, amount, payload) VALUES (6, 'after', 2, NULL);")
        XCTAssertEqual(try Self.selectAll(source).count, Self.expectedRows.count + 1)
    }

    func testSerializedCopyRejectsUnknownSourceDatabaseName() throws {
        let source = try Self.openMemoryDatabase()
        defer { sqlite3_close_v2(source) }
        try Self.exec(source, Self.createTableSQL)

        XCTAssertThrowsError(try SQLiteMemoryBackup.serializedCopy(of: source, sourceDatabaseName: "no_such_schema")) { error in
            guard case SQLiteMemoryBackupError.backupInitFailed(let code)? = error as? SQLiteMemoryBackupError else {
                return XCTFail("予期しないエラー: \(error)")
            }
            XCTAssertNotEqual(code, SQLITE_OK)
        }
        // 失敗後もsourceは閉じられておらず使えること。
        try Self.exec(source, "INSERT INTO sample (id) VALUES (1);")
    }

    func testByteCountRejectsNonPositiveSizes() {
        for size: sqlite3_int64 in [0, -1, .min] {
            XCTAssertThrowsError(try SQLiteMemoryBackup.byteCount(forSerializedSize: size)) { error in
                XCTAssertEqual(error as? SQLiteMemoryBackupError, .invalidSerializedSize(size))
            }
        }
    }

    func testByteCountAcceptsSizesRepresentableAsInt() throws {
        XCTAssertEqual(try SQLiteMemoryBackup.byteCount(forSerializedSize: 1), 1)
        XCTAssertEqual(try SQLiteMemoryBackup.byteCount(forSerializedSize: 4096), 4096)
        // Intが64bitの環境ではInt64.maxも正確に変換できる。32bit環境なら拒否されるべき値。
        // 実行時のifだと定数分岐の片側がunreachable警告になるため、コンパイル条件で分ける
        #if arch(x86_64) || arch(arm64)
        XCTAssertEqual(try SQLiteMemoryBackup.byteCount(forSerializedSize: .max), Int(Int64.max))
        #else
        XCTAssertThrowsError(try SQLiteMemoryBackup.byteCount(forSerializedSize: .max))
        #endif
    }

    // MARK: - :memory: 専用のテスト補助

    private enum TestSQLiteError: Error { case open(Int32), exec(Int32, String), prepare(Int32), step(Int32), malloc, deserialize(Int32) }

    private static func openMemoryDatabase() throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw TestSQLiteError.open(result)
        }
        return database
    }

    private static func exec(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw TestSQLiteError.exec(result, message.map { String(cString: $0) } ?? "")
        }
    }

    /// Dataのコピーをsqlite3_mallocしたバッファへ移し、新しいメモリDBへdeserializeする。
    private static func deserializeIntoNewMemoryDatabase(_ data: Data) throws -> OpaquePointer {
        let database = try openMemoryDatabase()
        guard let buffer = sqlite3_malloc64(sqlite3_uint64(data.count)) else {
            sqlite3_close_v2(database)
            throw TestSQLiteError.malloc
        }
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        data.copyBytes(to: bytes, count: data.count)
        // FREEONCLOSE指定時は、失敗時も含めてSQLite側がbufferを解放する。
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let size = sqlite3_int64(data.count)
        let result = sqlite3_deserialize(database, "main", bytes, size, size, flags)
        guard result == SQLITE_OK else {
            sqlite3_close_v2(database)
            throw TestSQLiteError.deserialize(result)
        }
        return database
    }

    private static func integrityCheck(_ database: OpaquePointer) throws -> String? {
        try query(database, "PRAGMA integrity_check").first.flatMap { row in
            if case .text(let text)? = row.first { return text }
            return nil
        }
    }

    private static func selectAll(_ database: OpaquePointer) throws -> [[SQLValue]] {
        try query(database, "SELECT id, name, amount, payload FROM sample ORDER BY id")
    }

    private static func query(_ database: OpaquePointer, _ sql: String) throws -> [[SQLValue]] {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw TestSQLiteError.prepare(prepareResult)
        }
        defer { sqlite3_finalize(statement) }

        var rows: [[SQLValue]] = []
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW else { throw TestSQLiteError.step(stepResult) }
            rows.append((0..<sqlite3_column_count(statement)).map { column(statement, $0) })
        }
        return rows
    }

    private static func column(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, index) else { return .text("") }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let blob = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: blob, count: count))
        default:
            return .null
        }
    }
}
