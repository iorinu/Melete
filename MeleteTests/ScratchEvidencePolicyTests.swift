import XCTest

/// ScratchProbeUITests.safe()が呼ぶ照合関数を、合成データだけで検証する。
/// UI起動・ファイル・プロセスには触れない。ここが通ってもScratchProbeのGUIフローが安全とは扱わない。
final class ScratchEvidencePolicyTests: XCTestCase {
    // 実データではない合成値
    private let storeUUID = "00000000-0000-4000-8000-000000000001"
    private let otherUUID = "00000000-0000-4000-8000-000000000002"
    private let executable = "/synthetic/ScratchProbe/Melete.app/Contents/MacOS/Melete"
    private let ownerUID: uid_t = 501
    private let pid: pid_t = 4242
    private let storeDirectory = "/synthetic/scratch/root/store"

    private var identity: ScratchProcessIdentity {
        ScratchProcessIdentity(pid: pid, ownerUID: ownerUID, startSeconds: 1_000, startMicroseconds: 250)
    }

    private func observation(
        evidencePID: pid_t? = nil,
        running: Bool = true,
        identity: ScratchProcessIdentity?? = nil,
        executablePath: String?? = nil
    ) -> ScratchProcessObservation {
        // 引数省略時は正常値。nilを明示したい場合は .some(nil) を渡す
        ScratchProcessObservation(
            evidencePID: evidencePID ?? pid,
            isRunningScratchApplication: running,
            identity: identity ?? self.identity,
            executablePath: executablePath ?? executable
        )
    }

    private func verify(_ observation: ScratchProcessObservation, previous: ScratchProcessIdentity? = nil) -> Result<ScratchProcessIdentity, ScratchEvidenceRejection> {
        ScratchEvidencePolicy.verifiedProcess(observation, expectedOwnerUID: ownerUID, expectedExecutablePath: executable, previouslyVerified: previous)
    }

    // MARK: - UI証拠の読み取り

    func testValidMarkerIsParsed() {
        XCTAssertEqual(
            ScratchEvidencePolicy.evidence(fromMarker: "melete-scratch-evidence-\(storeUUID)-pid-4242"),
            ScratchUIEvidence(storeUUID: storeUUID, pid: 4242)
        )
    }

    func testMalformedMarkersAreRejected() {
        let markers = [
            "",
            "melete-scratch-evidence-",
            "other-evidence-\(storeUUID)-pid-4242",
            "melete-scratch-evidence-\(storeUUID)",
            "melete-scratch-evidence-\(storeUUID)-pid-",
            "melete-scratch-evidence-\(storeUUID)-pid-0",
            "melete-scratch-evidence-\(storeUUID)-pid--1",
            "melete-scratch-evidence-\(storeUUID)-pid-abc",
            "melete-scratch-evidence-\(storeUUID)-pid-99999999999",
            "melete-scratch-evidence-not-a-uuid-pid-4242",
            "melete-scratch-evidence--pid-4242",
        ]
        for marker in markers {
            XCTAssertNil(ScratchEvidencePolicy.evidence(fromMarker: marker), "不正な証拠はreject: \(marker)")
        }
    }

    // MARK: - プロセス照合

    func testMatchingProcessReturnsObservedIdentity() {
        XCTAssertEqual(verify(observation()), .success(identity))
        XCTAssertEqual(verify(observation(), previous: identity), .success(identity), "同一プロセスの再照合は通る")
    }

    func testMissingProcessEvidenceIsRejected() {
        XCTAssertEqual(verify(observation(running: false)), .failure(.notRunningScratchApplication))
        XCTAssertEqual(verify(observation(identity: .some(nil))), .failure(.identityUnavailable))
        XCTAssertEqual(verify(observation(executablePath: .some(nil))), .failure(.executablePathUnavailable))
        XCTAssertEqual(verify(observation(evidencePID: 0)), .failure(.invalidEvidencePID))
    }

    func testPIDDifferenceIsRejected() {
        // UI証拠のPIDと読み取ったプロセスのPIDが違う
        XCTAssertEqual(verify(observation(evidencePID: pid + 1)), .failure(.pidMismatch))
        // 以前に確認したプロセスとPIDが違う（再利用・差し替え）
        let previous = ScratchProcessIdentity(pid: pid + 1, ownerUID: ownerUID, startSeconds: 1_000, startMicroseconds: 250)
        XCTAssertEqual(verify(observation(), previous: previous), .failure(.processChanged))
    }

    func testProcessStartTimeDifferenceIsRejected() {
        let laterSeconds = ScratchProcessIdentity(pid: pid, ownerUID: ownerUID, startSeconds: 1_001, startMicroseconds: 250)
        let laterMicroseconds = ScratchProcessIdentity(pid: pid, ownerUID: ownerUID, startSeconds: 1_000, startMicroseconds: 251)
        XCTAssertEqual(verify(observation(), previous: laterSeconds), .failure(.processChanged))
        XCTAssertEqual(verify(observation(), previous: laterMicroseconds), .failure(.processChanged))
    }

    func testOwnerAndExecutableDifferencesAreRejected() {
        let otherOwner = ScratchProcessIdentity(pid: pid, ownerUID: ownerUID + 1, startSeconds: 1_000, startMicroseconds: 250)
        XCTAssertEqual(verify(observation(identity: otherOwner)), .failure(.ownerMismatch))
        XCTAssertEqual(verify(observation(executablePath: "/synthetic/Other.app/Contents/MacOS/Melete")), .failure(.executableMismatch))
        XCTAssertEqual(verify(observation(executablePath: executable + "/")), .failure(.executableMismatch))
        XCTAssertEqual(
            ScratchEvidencePolicy.verifiedProcess(observation(executablePath: ""), expectedOwnerUID: ownerUID, expectedExecutablePath: "", previouslyVerified: nil),
            .failure(.invalidExpectedExecutablePath),
            "期待値が空なら空同士でも一致扱いにしない"
        )
    }

    // MARK: - store marker照合

    func testMatchingStoreMarkerIsAccepted() {
        let evidence = ScratchUIEvidence(storeUUID: storeUUID, pid: pid)
        XCTAssertNil(ScratchEvidencePolicy.storeRejection(evidence: evidence, expectedStoreMarker: storeUUID))
    }

    func testStoreIDDifferenceIsRejected() {
        let evidence = ScratchUIEvidence(storeUUID: otherUUID, pid: pid)
        XCTAssertEqual(ScratchEvidencePolicy.storeRejection(evidence: evidence, expectedStoreMarker: storeUUID), .storeUUIDMismatch)
        // 同じUUID値でも表記が違えば一致扱いにしない
        let uppercase = "ABCDEF00-0000-4000-8000-000000000001"
        let lowercased = ScratchUIEvidence(storeUUID: uppercase.lowercased(), pid: pid)
        XCTAssertEqual(ScratchEvidencePolicy.storeRejection(evidence: lowercased, expectedStoreMarker: uppercase), .storeUUIDMismatch)
    }

    func testInvalidStoreMarkersAreRejected() {
        let evidence = ScratchUIEvidence(storeUUID: storeUUID, pid: pid)
        for marker in ["", "not-a-uuid", storeUUID + "\n"] {
            XCTAssertEqual(ScratchEvidencePolicy.storeRejection(evidence: evidence, expectedStoreMarker: marker), .invalidExpectedStoreMarker)
        }
        let forged = ScratchUIEvidence(storeUUID: "not-a-uuid", pid: pid)
        XCTAssertEqual(ScratchEvidencePolicy.storeRejection(evidence: forged, expectedStoreMarker: storeUUID), .invalidEvidenceStoreUUID)
        let empty = ScratchUIEvidence(storeUUID: "", pid: pid)
        XCTAssertEqual(ScratchEvidencePolicy.storeRejection(evidence: empty, expectedStoreMarker: storeUUID), .invalidEvidenceStoreUUID)
    }

    // MARK: - 開いているstoreファイルの照合

    private var allowedStoreFiles: Set<String> {
        Set(["Melete.store", "Melete.store-wal", "Melete.store-shm"].map { "\(storeDirectory)/\($0)" })
    }

    private func openStoreRejection(_ paths: [String]?, allowed: Set<String>? = nil) -> ScratchEvidenceRejection? {
        ScratchEvidencePolicy.openStoreRejection(
            openFilePaths: paths,
            allowedStoreFilePaths: allowed ?? allowedStoreFiles,
            requiredStoreFilePath: "\(storeDirectory)/Melete.store"
        )
    }

    func testOpenIsolatedStoreIsAccepted() {
        let paths = ["\(storeDirectory)/Melete.store", "\(storeDirectory)/Melete.store-wal", "/synthetic/lib/other.dylib"]
        XCTAssertNil(openStoreRejection(paths))
    }

    func testOpenStoreEvidenceProblemsAreRejected() {
        XCTAssertEqual(openStoreRejection(nil), .openFilesUnavailable)
        XCTAssertEqual(openStoreRejection([]), .isolatedStoreNotOpen)
        XCTAssertEqual(openStoreRejection(["\(storeDirectory)/Melete.store-wal"]), .isolatedStoreNotOpen)
        XCTAssertEqual(
            openStoreRejection(["\(storeDirectory)/Melete.store", "/synthetic/regular/Melete.store", "/synthetic/regular/Other.SQLITE"]),
            .storeFilesOutsideIsolatedStore(count: 2)
        )
        XCTAssertEqual(
            openStoreRejection(["\(storeDirectory)/Melete.store"], allowed: []),
            .invalidAllowedStoreFiles,
            "必須storeが許可パスに無い設定は一致扱いにしない"
        )
    }

    func testAllowedStoreFilesWithNonStoreFilesAreAccepted() {
        // 許可された3ファイルすべてと、拡張子が末尾に来ない非storeファイルは通る
        let paths = Array(allowedStoreFiles) + ["/synthetic/lib/Melete.sqlite3.dylib", "/synthetic/lib/store"]
        XCTAssertNil(openStoreRejection(paths))
        XCTAssertNil(openStoreRejection(["\(storeDirectory)/Melete.store"]), "必須storeだけでも通る")
    }

    func testMissingStoreFilesAreRejected() {
        // storeファイルが1つも無い（非storeファイルだけ）
        XCTAssertEqual(openStoreRejection(["/synthetic/lib/other.dylib", "/synthetic/lib/another.dylib"]), .isolatedStoreNotOpen)
        // 補助ファイルだけで本体が無い
        XCTAssertEqual(
            openStoreRejection(["\(storeDirectory)/Melete.store-wal", "\(storeDirectory)/Melete.store-shm"]),
            .isolatedStoreNotOpen
        )
    }

    func testUnjudgeableOpenFilePathsAreRejected() {
        let required = "\(storeDirectory)/Melete.store"
        // 必須storeを開いていても、判定できない要素が混ざれば拡張子に関係なくreject
        let invalidPaths = [
            "",
            "Melete.store",
            "relative/lib/other.dylib",
            "./Melete.sqlite",
            "~/Melete.store",
            "/synthetic/lib/other\0.dylib",
            "\(storeDirectory)/Melete.store\0/../../regular/Melete.store",
            "\(storeDirectory)/../../regular/Melete.store",
            "\(storeDirectory)/./Melete.store-wal",
            "/synthetic/lib/..",
        ]
        for path in invalidPaths {
            XCTAssertEqual(openStoreRejection([required, path]), .invalidOpenFilePath(count: 1), "判定できないパスはreject: \(path.debugDescription)")
        }
        XCTAssertEqual(openStoreRejection(["", "relative.dylib"]), .invalidOpenFilePath(count: 2))
        // 不正パスの検査は必須store・許可パスの照合より先に行う
        XCTAssertEqual(openStoreRejection([""], allowed: []), .invalidOpenFilePath(count: 1))
    }

    // MARK: - OSから読んだパスバイト列の変換（ProcessProbe.openFilePathsが使う）

    private func bytes(_ string: String) -> [UInt8] { Array(string.utf8) }

    func testOpenFilePathKeepsRawStringWithoutNormalization() {
        let raw = [
            "\(storeDirectory)/Melete.store",
            "\(storeDirectory)/../../regular/Melete.store",
            "\(storeDirectory)/./Melete.store-wal",
            "relative/Melete.store",
            "/synthetic//lib/other.dylib",
        ]
        for path in raw {
            // NUL以降の残りバイトは無視され、NUL前の文字列が一切変換されずに返る
            XCTAssertEqual(ScratchEvidencePolicy.openFilePath(fromNULTerminatedBytes: bytes(path) + [0, 0x41, 0]), path)
        }
    }

    func testRelativeAndDotDotPathsFromBytesAreRejected() throws {
        let required = "\(storeDirectory)/Melete.store"
        for path in ["\(storeDirectory)/../../regular/Melete.store", "\(storeDirectory)/./Melete.store-wal", "relative/Melete.store"] {
            let converted = try XCTUnwrap(ScratchEvidencePolicy.openFilePath(fromNULTerminatedBytes: bytes(path) + [0]))
            XCTAssertEqual(converted, path)
            // 変換結果をそのまま照合に渡すと、正規化で隠れずにrejectされる
            XCTAssertEqual(openStoreRejection([required, converted]), .invalidOpenFilePath(count: 1), "正規化せずreject: \(path)")
        }
    }

    func testUnreadableOpenFilePathBytesYieldNil() {
        // NUL終端が無い（切れている可能性がある）
        XCTAssertNil(ScratchEvidencePolicy.openFilePath(fromNULTerminatedBytes: bytes("\(storeDirectory)/Melete.store")))
        XCTAssertNil(ScratchEvidencePolicy.openFilePath(fromNULTerminatedBytes: [UInt8]()))
        // UTF-8として不正なバイト列
        XCTAssertNil(ScratchEvidencePolicy.openFilePath(fromNULTerminatedBytes: bytes("/synthetic/") + [0xFF, 0xFE, 0]))
        // 先頭がNULなら空文字列になり、照合でrejectされる
        XCTAssertEqual(ScratchEvidencePolicy.openFilePath(fromNULTerminatedBytes: [0]), "")
    }

    func testEveryStoreSuffixOutsideIsolatedStoreIsRejected() {
        let required = "\(storeDirectory)/Melete.store"
        // storeFileSuffixesを参照せず明示列挙し、一覧からの削除も検出する
        let suffixes = [
            ".store", ".store-wal", ".store-shm", ".store-journal",
            ".sqlite", ".sqlite-wal", ".sqlite-shm", ".sqlite-journal",
            ".sqlite3", ".sqlite3-wal", ".sqlite3-shm", ".sqlite3-journal",
        ]
        for suffix in suffixes {
            for outside in ["/synthetic/regular/Melete\(suffix)", "/synthetic/regular/Melete\(suffix.uppercased())", "\(storeDirectory)/Other\(suffix)"] {
                XCTAssertEqual(
                    openStoreRejection([required, outside]),
                    .storeFilesOutsideIsolatedStore(count: 1),
                    "許可外のstore系ファイルはreject: \(outside)"
                )
            }
        }
    }
}
