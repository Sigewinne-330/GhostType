import Foundation

struct DerivedDataCleanupReport {
    let removedCount: Int
    let failures: [String]
    let enumerationFailed: Bool
}

enum DerivedDataAppCleaner {
    static func removeDuplicateGhostTypeBundles(canonicalAppPath: String) -> DerivedDataCleanupReport {
        let currentBundlePath = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        guard currentBundlePath == canonicalAppPath else {
            return DerivedDataCleanupReport(removedCount: 0, failures: [], enumerationFailed: false)
        }

        let derivedDataURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        guard FileManager.default.fileExists(atPath: derivedDataURL.path) else {
            return DerivedDataCleanupReport(removedCount: 0, failures: [], enumerationFailed: false)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: derivedDataURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return DerivedDataCleanupReport(removedCount: 0, failures: [], enumerationFailed: true)
        }

        var removedCount = 0
        var removedPaths: [String] = []
        var failures: [String] = []
        for case let candidateURL as URL in enumerator {
            guard candidateURL.lastPathComponent == "GhostType.app" else {
                continue
            }

            let candidatePath = candidateURL.resolvingSymlinksInPath().path
            if candidatePath == canonicalAppPath {
                continue
            }

            do {
                try FileManager.default.removeItem(at: candidateURL)
                removedCount += 1
                removedPaths.append(candidateURL.path)
                enumerator.skipDescendants()
            } catch {
                failures.append("\(candidateURL.path): \(error.localizedDescription)")
            }
        }

        if !removedPaths.isEmpty {
            refreshLaunchServicesRegistration(
                removedBundlePaths: removedPaths,
                canonicalAppPath: canonicalAppPath,
                failures: &failures
            )
        }

        return DerivedDataCleanupReport(
            removedCount: removedCount,
            failures: failures,
            enumerationFailed: false
        )
    }

    private static func refreshLaunchServicesRegistration(
        removedBundlePaths: [String],
        canonicalAppPath: String,
        failures: inout [String]
    ) {
        let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        guard FileManager.default.isExecutableFile(atPath: lsregisterPath) else {
            return
        }

        for path in removedBundlePaths {
            let status = runProcess(
                toolPath: lsregisterPath,
                arguments: ["-u", path]
            )
            if status != 0 {
                failures.append("lsregister -u \(path) exited with status \(status)")
            }
        }

        let reRegisterStatus = runProcess(
            toolPath: lsregisterPath,
            arguments: ["-f", canonicalAppPath]
        )
        if reRegisterStatus != 0 {
            failures.append("lsregister -f \(canonicalAppPath) exited with status \(reRegisterStatus)")
        }
    }

    @discardableResult
    private static func runProcess(toolPath: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = arguments
        process.qualityOfService = .utility

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
