import Foundation
import AppKit

final class DefaultActionExecutor: ActionExecuting {
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    func execute(_ prediction: Prediction) async {
        if prediction.token.hasPrefix("a:") {
            let bundleID = prediction.suggestedContent
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.open(appURL)
                debugLogger?(.prediction, "Launched app: \(bundleID)")
            } else {
                debugLogger?(.prediction, "Failed to find app for bundle: \(bundleID)")
            }
        }
    }

    func canExecute(_ prediction: Prediction) -> Bool {
        prediction.token.hasPrefix("a:")
    }
}
