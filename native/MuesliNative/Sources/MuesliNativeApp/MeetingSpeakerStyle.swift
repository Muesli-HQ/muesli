import MuesliCore
import SwiftUI

enum MeetingSpeakerStyle {
    static func colour(for key: MeetingSpeakerKey?, isSelf: Bool, isPerson: Bool) -> Color {
        let token = MeetingSpeakerPalette.colour(for: key, isSelf: isSelf, isPerson: isPerson)
        return .adaptive(dark: token.dark, light: token.light)
    }
}
