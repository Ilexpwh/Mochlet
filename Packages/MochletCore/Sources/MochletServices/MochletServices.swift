// Headless Apple-framework services (speech, audio taps, embeddings, local servers) arrive with
// their milestones. The module exists so the app can depend on it from the start.
import Foundation
import MochletCore

public enum MochletServicesVersion {
    public static let current = "0.1"
}
