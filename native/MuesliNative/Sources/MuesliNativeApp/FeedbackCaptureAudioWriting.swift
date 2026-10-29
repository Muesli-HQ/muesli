import Foundation

protocol FeedbackCaptureAudioWriting: AnyObject {
    func setMicrophoneOrigin(at frame: Int64)
    func appendMicrophone(_ samples: [Int16], startFrame: Int64) throws
    func finishMicrophone() throws -> URL?
}
