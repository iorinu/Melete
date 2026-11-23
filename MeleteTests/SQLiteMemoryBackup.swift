import Foundation
import SQLite3

/// テスト専用: 既に開かれたSQLite接続の内容を、メモリDBへのオンラインbackup経由で
/// シリアライズしたバイト列として取り出す。ファイルの作成・書き込みは一切行わない。
enum SQLiteMemoryBackupError: Error, Equatable {
    case openMemoryFailed(Int32)
    case backupInitFailed(Int32)
    case backupStepFailed(Int32)
    case backupFinishFailed(Int32)
    case serializeFailed
    case invalidSerializedSize(Int64)
}

enum SQLiteMemoryBackup {
    /// `source` の `sourceDatabaseName` スキーマをメモリDBへbackupし、シリアライズ結果をDataで返す。
    /// `source` 接続の所有権は呼び出し側に残り、この関数はcloseしない。
    /// 内部で開いたメモリDB・backupハンドル・serializeバッファは、成功・失敗どちらの経路でも解放する。
    static func serializedCopy(of source: OpaquePointer, sourceDatabaseName: String = "main") throws -> Data {
        var memory: OpaquePointer?
        let openResult = sqlite3_open_v2(":memory:", &memory, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let memory else {
            // open失敗時もハンドルが返ることがあるため、必ずcloseする。
            if let memory { sqlite3_close_v2(memory) }
            throw SQLiteMemoryBackupError.openMemoryFailed(openResult)
        }
        defer { sqlite3_close_v2(memory) }

        guard let backup = sqlite3_backup_init(memory, "main", source, sourceDatabaseName) else {
            // backup_init失敗時のエラーは出力先(memory)接続に記録される。
            throw SQLiteMemoryBackupError.backupInitFailed(sqlite3_errcode(memory))
        }
        // stepの結果に関わらずfinishを必ず呼び、両方の結果を検査する。
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE else { throw SQLiteMemoryBackupError.backupStepFailed(stepResult) }
        guard finishResult == SQLITE_OK else { throw SQLiteMemoryBackupError.backupFinishFailed(finishResult) }

        var serializedSize: sqlite3_int64 = 0
        guard let serialized = sqlite3_serialize(memory, "main", &serializedSize, 0) else {
            throw SQLiteMemoryBackupError.serializeFailed
        }
        // flags=0 のserializeはsqlite3_mallocしたコピーを返すので、サイズ検証失敗時も含めて解放する。
        defer { sqlite3_free(serialized) }
        let count = try byteCount(forSerializedSize: serializedSize)
        // Data(bytes:count:) はバイト列をコピーするため、sqlite3_free後も独立して使える。
        return Data(bytes: serialized, count: count)
    }

    /// sqlite3_serializeが返したサイズを、正でIntに正確に収まる場合だけバイト数として受け入れる。
    static func byteCount(forSerializedSize size: sqlite3_int64) throws -> Int {
        guard size > 0, let count = Int(exactly: size) else {
            throw SQLiteMemoryBackupError.invalidSerializedSize(size)
        }
        return count
    }
}
