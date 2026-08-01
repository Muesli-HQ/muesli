enum MeetingStartPresentation: Equatable {
    case foregroundNotes
    case backgroundPill

    var opensMeetingDocument: Bool {
        self == .foregroundNotes
    }

    var presentsHistoryWindow: Bool {
        self == .foregroundNotes
    }
}
