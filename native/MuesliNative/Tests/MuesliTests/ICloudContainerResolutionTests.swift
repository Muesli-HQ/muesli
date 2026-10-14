import Foundation
import Testing
@testable import MuesliNativeApp

@Suite("iCloud container resolution")
struct ICloudContainerResolutionTests {
    private let fallback = MuesliICloudSyncEngine.Schema.defaultContainerIdentifier

    @Test("the container named in the app's entitlement is used")
    func fromArray() {
        #expect(MuesliICloudSyncEngine.Schema.resolveContainerIdentifier(entitled: ["iCloud.com.example.mine"]) == "iCloud.com.example.mine")
    }

    @Test("a single string entitlement works")
    func fromString() {
        #expect(MuesliICloudSyncEngine.Schema.resolveContainerIdentifier(entitled: "iCloud.com.example.mine") == "iCloud.com.example.mine")
    }

    @Test("the first iCloud container wins and non-iCloud values are ignored")
    func firstICloudWins() {
        let entitled: [String] = ["com.example.other", "iCloud.com.example.first", "iCloud.com.example.second"]
        #expect(MuesliICloudSyncEngine.Schema.resolveContainerIdentifier(entitled: entitled) == "iCloud.com.example.first")
    }

    @Test("with no usable entitlement the upstream container is the fallback")
    func fallsBack() {
        #expect(MuesliICloudSyncEngine.Schema.resolveContainerIdentifier(entitled: nil) == fallback)
        #expect(MuesliICloudSyncEngine.Schema.resolveContainerIdentifier(entitled: [String]()) == fallback)
        #expect(MuesliICloudSyncEngine.Schema.resolveContainerIdentifier(entitled: ["not-a-container"]) == fallback)
        #expect(MuesliICloudSyncEngine.Schema.resolveContainerIdentifier(entitled: 42) == fallback)
        #expect(fallback == "iCloud.com.mueslihq.muesli")
    }

    @Test("a build whose entitlement names another container still counts as entitled")
    func entitlementCheckFollowsTheResolvedContainer() {
        #expect(MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: [MuesliICloudSyncEngine.Schema.containerIdentifier], environment: "Production"))
        #expect(!MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: ["iCloud.com.example.unrelated"], environment: "Production"))
    }
}
