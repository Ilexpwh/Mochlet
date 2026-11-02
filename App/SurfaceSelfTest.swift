#if DEBUG
import Foundation

extension RuntimeSelfTest {
    static func companionDisplayFixtures() throws {
        let laptop = CompanionDisplay(id: "uuid:laptop", runtimeID: 1, name: "Laptop", hasNotch: true, isMain: true)
        let external = CompanionDisplay(id: "uuid:external", runtimeID: 20, name: "Studio", hasNotch: false, isMain: false)
        let rebooted = CompanionDisplay(id: external.id, runtimeID: 90, name: external.name, hasNotch: false, isMain: false)
        try require(CompanionDisplay.preferred("", in: [external, laptop]) == laptop, "Automatic placement missed the notch display")
        try require(CompanionDisplay.preferred(external.id, in: [laptop, external]) == external, "Explicit display choice was ignored")
        try require(CompanionDisplay.preferred(external.id, in: [laptop, rebooted]) == rebooted, "Runtime ID change lost persistent preference")
        try require(CompanionDisplay.preferred(external.id, in: [laptop]) == laptop, "Disconnected display did not fall back")
        try require(CompanionDisplay.preferred(external.id, in: [laptop, external]) == external, "Reconnected display did not regain placement")
        try require(external.matches("legacy:20") && !rebooted.matches("legacy:20"), "Legacy ID migration matched another display")
        try require(CompanionDisplay.preferred("missing", in: [external]) == external, "No-notch fallback failed")
        try require(CompanionDisplay.preferred("missing", in: []) == nil, "No-display state invented a screen")
        let main = CompanionDisplay(id: "uuid:main", runtimeID: 30, name: "Studio", hasNotch: false, isMain: true)
        try require(CompanionDisplay.preferred("", in: [external, main]) == main, "Main display fallback used screen order or display name")
        print("Native display selection fixtures passed: explicit UUID, restart, disconnect/reconnect, legacy ID and no-notch fallback.")
    }
}
#endif
