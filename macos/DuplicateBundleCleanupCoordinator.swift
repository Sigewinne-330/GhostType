import Foundation

@MainActor
final class DuplicateBundleCleanupCoordinator {
    private let appLogger: AppLogger
    private let isTestingEnvironment: () -> Bool
    private var timer: Timer?

    init(appLogger: AppLogger, isTestingEnvironment: @escaping () -> Bool) {
        self.appLogger = appLogger
        self.isTestingEnvironment = isTestingEnvironment
    }

    func start() {
        performCleanup(logWhenNoChanges: false)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.performCleanup(logWhenNoChanges: false)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func performCleanup(logWhenNoChanges: Bool) {
        guard !isTestingEnvironment() else { return }

        let cleanupReport = DerivedDataAppCleaner.removeDuplicateGhostTypeBundles(
            canonicalAppPath: "/Applications/GhostType.app"
        )
        if cleanupReport.enumerationFailed {
            appLogger.log("Unable to enumerate DerivedData for duplicate app cleanup.", type: .warning)
        }
        for failure in cleanupReport.failures {
            appLogger.log("Failed to remove duplicate app bundle at \(failure)", type: .warning)
        }
        if cleanupReport.removedCount > 0 {
            appLogger.log(
                "Removed \(cleanupReport.removedCount) duplicate GhostType.app bundle(s) from DerivedData.",
                type: .warning
            )
        } else if logWhenNoChanges {
            appLogger.log("No duplicate GhostType.app bundle found in DerivedData.", type: .debug)
        }
    }
}
