import Foundation
import UIKit
import BackgroundTasks

class PipeSyncIOSManager {
    static let shared = PipeSyncIOSManager()
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "org.pipesync.bg_processing",
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self.handleNightlyProcessing(task: processingTask)
        }
    }

    func beginShortBufferTask(cleanup: @escaping () -> Void) {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PipeSyncShortBuffer") {
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid
        }
    }

    func endShortBufferTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }

    private func handleNightlyProcessing(task: BGProcessingTask) {
        task.expirationHandler = {}
        task.setTaskCompleted(success: true)
    }

    func startLocalDesktopPullServer(port: UInt16) {}
}
