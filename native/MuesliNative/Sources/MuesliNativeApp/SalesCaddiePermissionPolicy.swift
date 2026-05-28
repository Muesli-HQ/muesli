import Foundation

extension AppConfig {
    var salesCaddieAllowsMeetingRecording: Bool {
        salesCaddieCloudPermissions?.canRecordMeetings ?? true
    }

    var salesCaddieAllowsTranscriptSync: Bool {
        salesCaddieCloudPermissions?.canSyncMeetings ?? true
    }

    var salesCaddieAllowsAIAssist: Bool {
        salesCaddieCloudPermissions?.canUseAIAssist ?? true
    }

    var salesCaddieAllowsSalesAgent: Bool {
        salesCaddieCloudPermissions?.canUseSalesAgent ?? true
    }

    var salesCaddieAllowsComputerControl: Bool {
        salesCaddieCloudPermissions?.canUseComputerControl ?? true
    }
}
