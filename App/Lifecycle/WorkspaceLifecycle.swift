import AppKit
import ProteinApplication

@MainActor
final class WorkspaceLifecycle: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WorkspaceWrites.terminationReply(for: sender)
    }
}

@MainActor
enum WorkspaceWrites {
    private static var pending = 0
    private static var queue: QueueCoordinator?
    private static var closingQueue = false
    private static var quittingApplication: NSApplication?

    static func registerQueue(_ coordinator: QueueCoordinator) {
        queue = coordinator
    }

    static func run(_ work: @escaping @MainActor () async -> Void) {
        pending += 1
        let process = ProcessInfo.processInfo
        let activity = process.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Saving local workspace changes")
        Task {
            defer {
                process.endActivity(activity)
                pending -= 1
                finishTerminationIfPossible()
            }
            await work()
        }
    }

    static func terminationReply(for application: NSApplication) -> NSApplication.TerminateReply {
        guard pending > 0 || queue != nil else { return .terminateNow }
        if quittingApplication != nil { return .terminateLater }
        quittingApplication = application
        if let queue {
            closingQueue = true
            Task {
                // Persist the cancellation receipt before exit so an in-flight effect remains auditable.
                try? await queue.cancelInFlightForExit()
                closingQueue = false
                finishTerminationIfPossible()
            }
        }
        return .terminateLater
    }

    private static func finishTerminationIfPossible() {
        guard pending == 0, !closingQueue, let application = quittingApplication else { return }
        quittingApplication = nil
        application.reply(toApplicationShouldTerminate: true)
    }
}
