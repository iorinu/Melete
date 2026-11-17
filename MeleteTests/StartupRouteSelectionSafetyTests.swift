import XCTest
@testable import Melete

final class StartupRouteSelectionSafetyTests: XCTestCase {
    private let rootFlag = "--melete-ui-test-root"
    private let storeFlag = "--melete-ui-test-store"
    private let v2Flag = "--melete-v2-experimental"

    func testNoDedicatedArgumentsSelectRegularV1InDebugAndRelease() {
        for isDebug in [true, false] {
            XCTAssertEqual(
                StartupRouteSelection.select(arguments: [], isDebug: isDebug, isolationIsValid: false),
                .regularV1,
                "通常引数なしはV1を選択する (isDebug: \(isDebug))"
            )
        }
    }

    func testIncompleteDedicatedArgumentsNeverSelectRegularStore() {
        let cases: [(String, [String])] = [
            ("rootのみ", [rootFlag, "/tmp/root"]),
            ("storeのみ", [storeFlag, "/tmp/root/store"]),
            ("V2のみ", [v2Flag]),
            ("V2とrootのみ", [v2Flag, rootFlag, "/tmp/root"]),
            ("V2とstoreのみ", [v2Flag, storeFlag, "/tmp/root/store"])
        ]

        for isDebug in [true, false] {
            for (name, arguments) in cases {
                XCTAssertEqual(
                    StartupRouteSelection.select(arguments: arguments, isDebug: isDebug, isolationIsValid: false),
                    .error,
                    "\(name)は通常storeへfallbackせずエラー (isDebug: \(isDebug))"
                )
            }
        }
    }

    func testDuplicateMalformedAndInvalidDedicatedArgumentsReturnError() {
        let cases: [(String, [String], Bool, Bool)] = [
            ("root重複", [rootFlag, "/tmp/root", rootFlag, "/tmp/other", storeFlag, "/tmp/root/store"], true, true),
            ("store重複", [rootFlag, "/tmp/root", storeFlag, "/tmp/root/store", storeFlag, "/tmp/other"], true, true),
            ("V2重複", [rootFlag, "/tmp/root", storeFlag, "/tmp/root/store", v2Flag, v2Flag], true, true),
            ("root値なし", [rootFlag, storeFlag, "/tmp/root/store"], true, true),
            ("store値なし", [rootFlag, "/tmp/root", storeFlag], true, true),
            ("隔離検証失敗", [rootFlag, "/tmp/root", storeFlag, "/tmp/root/store"], false, true),
            ("Releaseで専用引数あり", [rootFlag, "/tmp/root", storeFlag, "/tmp/root/store"], true, false),
            ("ReleaseでV2専用引数あり", [rootFlag, "/tmp/root", storeFlag, "/tmp/root/store", v2Flag], true, false)
        ]

        for (name, arguments, isolationIsValid, isDebug) in cases {
            XCTAssertEqual(
                StartupRouteSelection.select(arguments: arguments, isDebug: isDebug, isolationIsValid: isolationIsValid),
                .error,
                "\(name)は通常storeへfallbackせずエラー"
            )
        }
    }

    func testValidDebugIsolationSelectsV1OrExplicitV2() {
        let v1Arguments = [rootFlag, "/tmp/root", storeFlag, "/tmp/root/store"]
        let v2Arguments = v1Arguments + [v2Flag]

        XCTAssertEqual(
            StartupRouteSelection.select(arguments: v1Arguments, isDebug: true, isolationIsValid: true),
            .isolatedV1
        )
        XCTAssertEqual(
            StartupRouteSelection.select(arguments: v2Arguments, isDebug: true, isolationIsValid: true),
            .isolatedV2
        )
        XCTAssertEqual(
            StartupRouteSelection.select(arguments: v2Arguments, isDebug: false, isolationIsValid: true),
            .error,
            "Releaseでは隔離引数が完全でも専用routeを許可しない"
        )
    }
}
