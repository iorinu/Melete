import XCTest
@testable import Melete

#if DEBUG && MELETE_SCRATCH_ISOLATION
/// scratch検証ビルドの起動引数の形チェックだけを確認する。
/// 文字列はすべて合成値で、存在しないパスを使う。ファイル・ストアの読み書きはしない。
final class ScratchLaunchArgumentV1Tests: XCTestCase {
    // 実際のargv[0]と同じく先頭は実行ファイル扱いで、形チェックの対象外になる
    private let executable = "/nonexistent-synthetic/Melete.app/Contents/MacOS/Melete"
    private let rootFlag = "--melete-ui-test-root"
    private let storeFlag = "--melete-ui-test-store"
    private let v2Flag = "--melete-v2-experimental"
    private let unknownFlag = "--melete-unknown"
    private let root = "/nonexistent-synthetic/root"
    private let store = "/nonexistent-synthetic/root/store"

    // MARK: - 受け付ける形

    // V1のroot+storeだけの形を受け付ける（V2フラグは0回でよい）
    func testV1RootAndStoreWithoutV2IsAccepted() {
        let arguments = [executable, rootFlag, root, storeFlag, store]
        XCTAssertTrue(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "V1のroot+storeだけの形を受け付ける")
    }

    // 対照: 既存のV2の正しい形は受け付ける（存在しないパスでも形だけで判定される）
    func testValidV2ShapeIsAccepted() {
        let arguments = [executable, rootFlag, root, storeFlag, store, v2Flag]
        XCTAssertTrue(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "V2の正しい形を受け付ける")
    }

    // 形チェックはフラグの回数だけを見るので、並び順が変わっても受け付ける
    func testReorderedShapesAreAccepted() {
        let cases: [(String, [String])] = [
            ("V1 store→root", [executable, storeFlag, store, rootFlag, root]),
            ("V2 先頭", [executable, v2Flag, rootFlag, root, storeFlag, store]),
            ("V2 中間", [executable, rootFlag, root, v2Flag, storeFlag, store]),
            ("V2 store→root", [executable, storeFlag, store, rootFlag, root, v2Flag])
        ]
        for (name, arguments) in cases {
            XCTAssertTrue(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "\(name)を受け付ける")
        }
    }

    // MARK: - 拒否する形（V2あり）

    // 対照: V2が正しい形でも、重複や未知の--melete-フラグがあれば拒否する
    func testDuplicateOrUnknownFlagsAreRejectedWithV2() {
        let cases: [(String, [String])] = [
            ("V2重複", [executable, rootFlag, root, storeFlag, store, v2Flag, v2Flag]),
            ("V2重複（離れた位置）", [executable, v2Flag, rootFlag, root, storeFlag, store, v2Flag]),
            ("root重複", [executable, rootFlag, root, rootFlag, root, storeFlag, store, v2Flag]),
            ("store重複", [executable, rootFlag, root, storeFlag, store, storeFlag, store, v2Flag]),
            ("未知の--melete-フラグ", [executable, rootFlag, root, storeFlag, store, v2Flag, unknownFlag]),
            ("未知の--melete-フラグ（先頭）", [executable, unknownFlag, rootFlag, root, storeFlag, store, v2Flag]),
            ("=付きV2フラグ", [executable, rootFlag, root, storeFlag, store, v2Flag + "=1"])
        ]
        for (name, arguments) in cases {
            XCTAssertFalse(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "\(name)は拒否する")
        }
    }

    // V2フラグがあってもroot/storeが欠けていれば拒否する
    func testMissingRootOrStoreIsRejectedWithV2() {
        let cases: [(String, [String])] = [
            ("V2のみ", [executable, v2Flag]),
            ("root+V2", [executable, rootFlag, root, v2Flag]),
            ("store+V2", [executable, storeFlag, store, v2Flag])
        ]
        for (name, arguments) in cases {
            XCTAssertFalse(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "\(name)は拒否する")
        }
    }

    // MARK: - 拒否する形（V1）

    // V1でも重複や未知フラグは拒否し続ける（V2フラグを任意にしてもfallbackを広げないための固定）
    func testDuplicateOrUnknownFlagsAreRejectedWithoutV2() {
        let cases: [(String, [String])] = [
            ("root重複", [executable, rootFlag, root, rootFlag, root, storeFlag, store]),
            ("store重複", [executable, rootFlag, root, storeFlag, store, storeFlag, store]),
            ("未知の--melete-フラグ", [executable, rootFlag, root, storeFlag, store, unknownFlag]),
            ("未知の--melete-フラグ（先頭）", [executable, unknownFlag, rootFlag, root, storeFlag, store]),
            ("=付きrootフラグ", [executable, rootFlag + "=" + root, storeFlag, store])
        ]
        for (name, arguments) in cases {
            XCTAssertFalse(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "\(name)は拒否する")
        }
    }

    // V1でroot/storeのどちらかが欠けていれば拒否する
    func testMissingRootOrStoreIsRejectedWithoutV2() {
        let cases: [(String, [String])] = [
            ("引数なし", [executable]),
            ("rootのみ", [executable, rootFlag, root]),
            ("storeのみ", [executable, storeFlag, store])
        ]
        for (name, arguments) in cases {
            XCTAssertFalse(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "\(name)は拒否する")
        }
    }

    // MARK: - 責務の境界

    // argv[0]は形チェックの対象外。実行ファイル名が--melete-で始まっても未知フラグ扱いしない
    func testExecutableIsNotTreatedAsFlag() {
        let arguments = [unknownFlag, rootFlag, root, storeFlag, store]
        XCTAssertTrue(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "argv[0]は判定に含めない")
    }

    // フラグ直後の値の欠落は形チェックでは見ず、StartupRouteSelectionがerrorにする。
    // isolationIsValid: trueを渡しても値欠落だけでerrorになることを確認する（通常ストアへのfallbackなし）
    func testMissingValueIsRejectedByStartupRoute() {
        let cases: [(String, [String])] = [
            ("V1 root値欠落", [executable, rootFlag, storeFlag, store]),
            ("V1 store値欠落（末尾）", [executable, rootFlag, root, storeFlag]),
            ("V2 root値欠落", [executable, rootFlag, storeFlag, store, v2Flag]),
            ("V2 store値がV2フラグ", [executable, rootFlag, root, storeFlag, v2Flag]),
            ("V1 store値が空文字", [executable, rootFlag, root, storeFlag, ""])
        ]
        for (name, arguments) in cases {
            XCTAssertTrue(ScratchLaunchArgumentShape.isAccepted(arguments: arguments), "\(name)は形チェックでは回数だけを見る")
            XCTAssertEqual(
                StartupRouteSelection.select(arguments: arguments, isDebug: true, isolationIsValid: true),
                .error,
                "\(name)はStartupRouteSelectionがerrorにする"
            )
        }
    }
}
#endif
