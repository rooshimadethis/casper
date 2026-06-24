import Foundation

enum IndexKind: String, Codable, CaseIterable, Identifiable {
    case people

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .people: return "People"
        }
    }

    /// Subdirectory name under `<save dir>/.indexes/`.
    var subdirectory: String {
        switch self {
        case .people: return "people"
        }
    }

    /// SF Symbol used in the sidebar and plus menu.
    var iconSystemName: String {
        switch self {
        case .people: return "person.3"
        }
    }
}
