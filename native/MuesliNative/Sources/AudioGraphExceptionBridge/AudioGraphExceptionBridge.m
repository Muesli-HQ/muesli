#import "AudioGraphExceptionBridge.h"

static NSString *const MuesliAudioGraphErrorDomain = @"MuesliAudioGraph";

static NSError *MuesliAudioGraphExceptionError(NSException *exception, NSString *operation) {
    return [NSError errorWithDomain:MuesliAudioGraphErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:@"%@ failed: %@", operation,
                                           exception.reason ?: exception.name]}];
}

@interface MuesliAudioInputState ()
@property(nonatomic, readwrite, nullable) AVAudioFormat *outputFormat;
@property(nonatomic, readwrite, nullable) NSError *error;
@end

@implementation MuesliAudioInputState
@end

MuesliAudioInputState *MuesliAudioGraphReadInputState(AVAudioEngine *engine) {
    MuesliAudioInputState *state = [[MuesliAudioInputState alloc] init];
    @try {
        AVAudioFormat *format = [engine.inputNode outputFormatForBus:0];
        if (format.streamDescription == NULL) {
            state.error = [NSError errorWithDomain:MuesliAudioGraphErrorDomain
                                              code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                         @"The microphone input format is unavailable"}];
        } else {
            state.outputFormat = format;
        }
    } @catch (NSException *exception) {
        state.error = MuesliAudioGraphExceptionError(exception, @"Read microphone input state");
    }
    return state;
}

NSError *MuesliAudioGraphSetInputDevice(AVAudioEngine *engine, AudioObjectID deviceID) {
    @try {
        AudioUnit audioUnit = engine.inputNode.audioUnit;
        if (audioUnit == NULL) {
            return [NSError errorWithDomain:MuesliAudioGraphErrorDomain
                                       code:4
                                   userInfo:@{NSLocalizedDescriptionKey:
                                                  @"No audio unit is available for preferred input routing"}];
        }
        OSStatus status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            sizeof(deviceID)
        );
        if (status != noErr) {
            return [NSError errorWithDomain:NSOSStatusErrorDomain
                                       code:status
                                   userInfo:@{NSLocalizedDescriptionKey:
                                                  @"Could not select the requested microphone"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Select microphone input device");
    }
}

NSError *MuesliAudioGraphInstallInputTap(
    AVAudioEngine *engine,
    AVAudioNodeBus bus,
    AVAudioFrameCount bufferSize,
    AVAudioFormat *format,
    AVAudioNodeTapBlock block
) {
    @try {
        [engine.inputNode installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Install microphone tap");
    }
}

NSError *MuesliAudioGraphPrepareEngine(AVAudioEngine *engine) {
    @try {
        [engine prepare];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Prepare audio engine");
    }
}

NSError *MuesliAudioGraphStartEngine(AVAudioEngine *engine) {
    @try {
        NSError *error = nil;
        if (![engine startAndReturnError:&error]) {
            return error ?: [NSError errorWithDomain:MuesliAudioGraphErrorDomain
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Start audio engine failed"}];
        }
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Start audio engine");
    }
}

NSError *MuesliAudioGraphRemoveInputTap(AVAudioEngine *engine, AVAudioNodeBus bus) {
    @try {
        [engine.inputNode removeTapOnBus:bus];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Remove microphone tap");
    }
}

NSError *MuesliAudioGraphStopEngine(AVAudioEngine *engine) {
    @try {
        [engine stop];
        return nil;
    } @catch (NSException *exception) {
        return MuesliAudioGraphExceptionError(exception, @"Stop audio engine");
    }
}
