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
        let mine = "iCloud.com.example.mine"
        #expect(MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: [mine], environment: "Production", container: mine))
        #expect(MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: mine, environment: "Development", container: mine))
        #expect(!MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: ["iCloud.com.example.unrelated"], environment: "Production", container: mine))
        // A longer identifier that merely starts with ours is a different container.
        #expect(!MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: ["\(mine).dev"], environment: "Production", container: mine))
        // Upstream's container does not satisfy a build that resolved to another one.
        #expect(!MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: [fallback], environment: "Production", container: mine))
    }

    @Test("without an explicit container the check uses the resolved one")
    func entitlementCheckDefaultsToTheResolvedContainer() {
        #expect(MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: [MuesliICloudSyncEngine.Schema.containerIdentifier], environment: "Production"))
        #expect(!MuesliICloudSyncEngine.hasRequiredCloudEntitlements(
            containers: ["iCloud.com.example.unrelated"], environment: "Production"))
    }
}

@Suite("iCloud saved sync state is scoped to the container")
struct ICloudSyncStateScopeTests {
    private let upstream = MuesliICloudSyncEngine.Schema.defaultContainerIdentifier
    private let mine = "iCloud.com.example.mine"
    private let other = "iCloud.com.example.other"

    @Test("upstream's container keeps the keys saved by earlier releases byte for byte")
    func upstreamKeysAreUnchanged() {
        for environment in ["production", "development", "unspecified"] {
            #expect(MuesliCKSyncEngine.stateKey(environment: environment, container: upstream)
                == "cksyncengine.private.MuesliSyncZone.\(environment).v1")
            #expect(MuesliCKSyncEngine.accountScopeKey(environment: environment, container: upstream)
                == "cksyncengine.private.MuesliSyncZone.\(environment).account-owner.v1")
        }
        #expect(UserDefaultsICloudChangeTokenStore.defaultKey(container: upstream)
            == "muesli.icloud.textRecords.MuesliSyncZone.serverChangeToken.v1")
    }

    @Test("another container gets its own state and owner keys")
    func otherContainersGetOwnKeys() {
        let upstreamState = MuesliCKSyncEngine.stateKey(environment: "production", container: upstream)
        let mineState = MuesliCKSyncEngine.stateKey(environment: "production", container: mine)
        let otherState = MuesliCKSyncEngine.stateKey(environment: "production", container: other)
        #expect(Set([upstreamState, mineState, otherState]).count == 3)
        #expect(mineState.contains(mine))

        let upstreamOwner = MuesliCKSyncEngine.accountScopeKey(environment: "production", container: upstream)
        let mineOwner = MuesliCKSyncEngine.accountScopeKey(environment: "production", container: mine)
        let otherOwner = MuesliCKSyncEngine.accountScopeKey(environment: "production", container: other)
        #expect(Set([upstreamOwner, mineOwner, otherOwner]).count == 3)
        #expect(mineOwner.contains(mine))
    }

    @Test("a state key never collides with an owner key")
    func stateAndOwnerKeysStayDistinct() {
        for container in [upstream, mine] {
            for environment in ["production", "development", "unspecified"] {
                #expect(MuesliCKSyncEngine.stateKey(environment: environment, container: container)
                    != MuesliCKSyncEngine.accountScopeKey(environment: environment, container: container))
            }
        }
    }

    @Test("the same container in the other environment still gets separate keys")
    func environmentsStaySeparate() {
        #expect(MuesliCKSyncEngine.stateKey(environment: "production", container: mine)
            != MuesliCKSyncEngine.stateKey(environment: "development", container: mine))
        #expect(MuesliCKSyncEngine.accountScopeKey(environment: "production", container: mine)
            != MuesliCKSyncEngine.accountScopeKey(environment: "development", container: mine))
    }

    @Test("legacy unscoped state belongs to upstream's production container only")
    func legacyMigrationIsUpstreamProductionOnly() {
        let migration = MuesliCKSyncEngine.productionLegacyScopeMigration(environment: "production", container: upstream)
        #expect(migration?.stateKey == "cksyncengine.private.MuesliSyncZone.unspecified.v1")
        #expect(migration?.accountScopeKey == "cksyncengine.private.MuesliSyncZone.unspecified.account-owner.v1")
        #expect(MuesliCKSyncEngine.productionLegacyScopeMigration(environment: "production", container: mine) == nil)
        #expect(MuesliCKSyncEngine.productionLegacyScopeMigration(environment: "development", container: upstream) == nil)
    }

    @Test("the legacy change token is kept per container")
    func changeTokenKeyIsPerContainer() {
        #expect(UserDefaultsICloudChangeTokenStore.defaultKey(container: mine)
            != UserDefaultsICloudChangeTokenStore.defaultKey(container: upstream))
        #expect(UserDefaultsICloudChangeTokenStore.defaultKey(container: mine)
            != UserDefaultsICloudChangeTokenStore.defaultKey(container: other))
        #expect(UserDefaultsICloudChangeTokenStore.defaultKey(container: mine).contains(mine))
    }
}
