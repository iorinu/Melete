import Foundation

// ScratchProbe UIテストの起動後・再起動中の照合のうち、渡された値だけで判定できる部分。
//
// - 副作用なし: ファイル・プロセス・UIを読まず、何も書かない。値の読み取りは呼び出し側が行う。
// - 証拠を生成しない: 読み取れなかった値はnil/falseのまま渡され、必ずrejectされる。
// - rejectされなかったことは「渡された値どうしが矛盾しない」ことだけを意味し、隔離の安全性の証明ではない。
//   fixture検証、隔離表示・V2表示の確認、待機前後の再照合など、ScratchProbeUITests.safe()の他の確認は置き換えない。
// - MeleteTestsとMeleteUITestsの両方に同じソースとしてコンパイルされる（project.ymlで明示追加）。

/// プロセスの同一性。PIDの再利用を見分けるため開始時刻も含める
struct ScratchProcessIdentity: Equatable {
    let pid: pid_t
    let ownerUID: uid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt32
}

/// アプリがUIに表示したscratch証拠（store marker UUIDとPID）
struct ScratchUIEvidence: Equatable {
    let storeUUID: String
    let pid: pid_t
}

/// ある時点で呼び出し側が読み取った値。読み取れなかった項目はnil/falseにする
struct ScratchProcessObservation: Equatable {
    /// UI証拠が示すPID
    let evidencePID: pid_t
    /// そのPIDが同じbundle IDの実行中アプリとして見つかったか
    let isRunningScratchApplication: Bool
    let identity: ScratchProcessIdentity?
    let executablePath: String?
}

enum ScratchEvidenceRejection: Error, Equatable {
    case invalidEvidencePID
    case notRunningScratchApplication
    case identityUnavailable
    case pidMismatch
    case ownerMismatch
    case invalidExpectedExecutablePath
    case executablePathUnavailable
    case executableMismatch
    /// 以前に確認したプロセスとPIDまたは開始時刻が異なる
    case processChanged
    case invalidExpectedStoreMarker
    case invalidEvidenceStoreUUID
    case storeUUIDMismatch
    case openFilesUnavailable
    /// 読み取ったパスに空・相対・NUL入り・`.`/`..`入りなど、判定できない要素がある
    case invalidOpenFilePath(count: Int)
    case invalidAllowedStoreFiles
    case storeFilesOutsideIsolatedStore(count: Int)
    case isolatedStoreNotOpen
}

enum ScratchEvidencePolicy {
    static let markerPrefix = "melete-scratch-evidence-"
    /// ストア本体とSQLite補助ファイル（WAL・共有メモリ・rollback journal）の拡張子
    static let storeFileSuffixes = [
        ".store", ".store-wal", ".store-shm", ".store-journal",
        ".sqlite", ".sqlite-wal", ".sqlite-shm", ".sqlite-journal",
        ".sqlite3", ".sqlite3-wal", ".sqlite3-shm", ".sqlite3-journal",
    ]

    /// 拡張子で分類してよい形のパスか。空・相対・NUL入り・`.`/`..`入りは何を指すか確定できないのでfalse
    static func isJudgeableOpenFilePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !components.contains(where: { $0 == "." || $0 == ".." })
    }

    /// OSから読んだNUL終端のパスバイト列を、正規化せずそのまま文字列にする。
    /// `.`/`..`や相対パスを正規化すると判定できない要素が隠れるため、判定はisJudgeableOpenFilePathに任せる。
    /// NUL終端が無い（途中で切れている可能性がある）・UTF-8として不正な場合は、何を指すか確定できないのでnil
    static func openFilePath<Bytes: Collection>(fromNULTerminatedBytes bytes: Bytes) -> String? where Bytes.Element == UInt8 {
        guard let terminator = bytes.firstIndex(of: 0) else { return nil }
        return String(bytes: bytes[..<terminator], encoding: .utf8)
    }

    /// `melete-scratch-evidence-<UUID>-pid-<PID>` 形式のUI証拠を読む。形式が違えばnil
    static func evidence(fromMarker marker: String) -> ScratchUIEvidence? {
        guard marker.hasPrefix(markerPrefix),
              let separator = marker.range(of: "-pid-", range: marker.index(marker.startIndex, offsetBy: markerPrefix.count)..<marker.endIndex),
              let pid = Int32(marker[separator.upperBound...]), pid > 0 else { return nil }
        let uuid = String(marker[marker.index(marker.startIndex, offsetBy: markerPrefix.count)..<separator.lowerBound])
        guard UUID(uuidString: uuid) != nil else { return nil }
        return ScratchUIEvidence(storeUUID: uuid, pid: pid_t(pid))
    }

    /// 読み取ったプロセス情報が、UI証拠のPID・所有者・実行ファイル・以前に確認した同一性とすべて一致するか。
    /// 一致すれば読み取った同一性をそのまま返す（新しい値は作らない）
    static func verifiedProcess(
        _ observation: ScratchProcessObservation,
        expectedOwnerUID: uid_t,
        expectedExecutablePath: String,
        previouslyVerified: ScratchProcessIdentity?
    ) -> Result<ScratchProcessIdentity, ScratchEvidenceRejection> {
        guard observation.evidencePID > 0 else { return .failure(.invalidEvidencePID) }
        guard observation.isRunningScratchApplication else { return .failure(.notRunningScratchApplication) }
        guard let identity = observation.identity else { return .failure(.identityUnavailable) }
        guard identity.pid == observation.evidencePID else { return .failure(.pidMismatch) }
        guard identity.ownerUID == expectedOwnerUID else { return .failure(.ownerMismatch) }
        guard expectedExecutablePath.hasPrefix("/") else { return .failure(.invalidExpectedExecutablePath) }
        guard let executablePath = observation.executablePath else { return .failure(.executablePathUnavailable) }
        guard executablePath == expectedExecutablePath else { return .failure(.executableMismatch) }
        if let previouslyVerified, previouslyVerified != identity {
            return .failure(.processChanged)
        }
        return .success(identity)
    }

    /// UI証拠のstore UUIDが、fixtureのstore markerと完全一致するか。一致すればnil
    static func storeRejection(evidence: ScratchUIEvidence, expectedStoreMarker: String) -> ScratchEvidenceRejection? {
        guard UUID(uuidString: expectedStoreMarker) != nil else { return .invalidExpectedStoreMarker }
        guard UUID(uuidString: evidence.storeUUID) != nil else { return .invalidEvidenceStoreUUID }
        // 大文字小文字の違いも許さないよう、UUID値ではなく文字列で比較する
        guard evidence.storeUUID == expectedStoreMarker else { return .storeUUIDMismatch }
        return nil
    }

    /// プロセスが開いているストア系ファイルがすべて許可パス内にあり、必須のstoreファイルを開いているか。一致すればnil
    static func openStoreRejection(
        openFilePaths: [String]?,
        allowedStoreFilePaths: Set<String>,
        requiredStoreFilePath: String
    ) -> ScratchEvidenceRejection? {
        guard let openFilePaths else { return .openFilesUnavailable }
        // 拡張子で絞り込む前に検査する。判定できない要素を捨てると、不完全な証拠でも通ってしまうため
        let invalidPaths = openFilePaths.filter { !isJudgeableOpenFilePath($0) }
        guard invalidPaths.isEmpty else { return .invalidOpenFilePath(count: invalidPaths.count) }
        guard allowedStoreFilePaths.contains(requiredStoreFilePath) else { return .invalidAllowedStoreFiles }
        let storePaths = openFilePaths.filter { path in
            storeFileSuffixes.contains(where: { path.lowercased().hasSuffix($0) })
        }
        let outside = storePaths.filter { !allowedStoreFilePaths.contains($0) }
        guard outside.isEmpty else { return .storeFilesOutsideIsolatedStore(count: outside.count) }
        guard storePaths.contains(requiredStoreFilePath) else { return .isolatedStoreNotOpen }
        return nil
    }
}
