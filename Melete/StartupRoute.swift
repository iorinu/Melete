enum StartupRoute: Equatable {
    case regularV1
    case isolatedV1
    case isolatedV2
    case error
}

enum StartupRouteSelection {
    private static let rootFlag = "--melete-ui-test-root"
    private static let storeFlag = "--melete-ui-test-store"
    private static let v2Flag = "--melete-v2-experimental"

    static func select(arguments: [String], isDebug: Bool, isolationIsValid: Bool) -> StartupRoute {
        let rootCount = arguments.filter { $0 == rootFlag }.count
        let storeCount = arguments.filter { $0 == storeFlag }.count
        let v2Count = arguments.filter { $0 == v2Flag }.count
        let hasDedicatedArgument = rootCount > 0 || storeCount > 0 || v2Count > 0

        guard hasDedicatedArgument else { return .regularV1 }
        guard isDebug,
              rootCount == 1,
              storeCount == 1,
              v2Count <= 1,
              isolationIsValid,
              hasSingleValue(after: rootFlag, in: arguments),
              hasSingleValue(after: storeFlag, in: arguments) else { return .error }

        return v2Count == 1 ? .isolatedV2 : .isolatedV1
    }

    private static func hasSingleValue(after flag: String, in arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else { return false }
        let value = arguments[index + 1]
        return !value.isEmpty && !value.hasPrefix("--")
    }
}
