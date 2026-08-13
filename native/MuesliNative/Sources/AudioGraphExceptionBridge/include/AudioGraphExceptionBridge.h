#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Result of reading AVAudioEngine's input node while inside the Objective-C
/// exception boundary. Swift cannot catch the NSExceptions AVFAudio may raise
/// while a hardware route is settling.
@interface MuesliAudioInputState : NSObject
@property(nonatomic, readonly, nullable) AVAudioFormat *outputFormat;
@property(nonatomic, readonly, nullable) NSError *error;
@end

FOUNDATION_EXPORT MuesliAudioInputState *MuesliAudioGraphReadInputState(
    AVAudioEngine *engine
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphSetInputDevice(
    AVAudioEngine *engine,
    AudioObjectID deviceID
);

FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat * _Nullable format,
    AVAudioNodeTapBlock block
);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphPrepareEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphStartEngine(AVAudioEngine *engine);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus);
FOUNDATION_EXPORT NSError * _Nullable MuesliAudioGraphStopEngine(AVAudioEngine *engine);

NS_ASSUME_NONNULL_END
