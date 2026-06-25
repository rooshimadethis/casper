import Foundation

protocol ActionExecuting: AnyObject {
    var debugLogger: ((DebugLogCategory, String) -> Void)? { get set }
    func execute(_ prediction: Prediction) async
    func canExecute(_ prediction: Prediction) -> Bool
}
