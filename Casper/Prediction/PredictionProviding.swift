import Foundation
import Combine

protocol PredictionProviding: AnyObject {
    var predictionsPublisher: AnyPublisher<[Prediction], Never> { get }
    var topPredictions: [Prediction] { get }
    var debugLogger: ((DebugLogCategory, String) -> Void)? { get set }
    func ingest(event: DesktopUserEvent)
    func predictActionChains(maxSteps: Int, beamWidth: Int) -> [ActionChainPrediction]
    func consumePrediction()
    func savePredictionState() throws
    var predictionStateDump: String { get }
}
