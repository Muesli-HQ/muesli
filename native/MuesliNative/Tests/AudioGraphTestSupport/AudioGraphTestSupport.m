#import "AudioGraphTestSupport.h"

@interface MuesliFaultInjectingAudioEngine ()
@property(nonatomic) NSMutableArray<NSString *> *recordedOperations;
@property(nonatomic) BOOL testRunning;
@property(nonatomic) BOOL testTapInstalled;
- (void)recordOperation:(NSString *)operation;
@end

// AVAudioInputNode cannot be constructed independently. This test double responds
// only to the node messages used by the recorder/bridge, without touching HAL.
@interface MuesliTestInputNode : NSObject
@property(nonatomic, weak) MuesliFaultInjectingAudioEngine *owner;
@end

@implementation MuesliTestInputNode
- (AVAudioFormat *)outputFormatForBus:(AVAudioNodeBus)bus {
    [self.owner recordOperation:@"read"];
    return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:16000 channels:1];
}
- (void)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)size
                format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)block {
    [self.owner recordOperation:@"install"];
    if (self.owner.testTapInstalled) {
        [NSException raise:NSInvalidArgumentException format:@"A microphone tap is already installed"];
    }
    self.owner.testTapInstalled = YES;
}
- (void)removeTapOnBus:(AVAudioNodeBus)bus {
    [self.owner recordOperation:@"remove"];
    if (self.owner.testRunning) {
        [NSException raise:NSInvalidArgumentException format:@"Cannot remove a tap from a running engine"];
    }
    self.owner.testTapInstalled = NO;
}
@end

@implementation MuesliFaultInjectingAudioEngine {
    MuesliTestInputNode *_testInput;
}
- (instancetype)init {
    if ((self = [super init])) {
        _recordedOperations = [NSMutableArray array];
        _failingOperations = @[];
        _testInput = [MuesliTestInputNode new];
        _testInput.owner = self;
    }
    return self;
}
- (AVAudioInputNode *)inputNode { return (AVAudioInputNode *)_testInput; }
- (NSArray<NSString *> *)operations { return [self.recordedOperations copy]; }
- (BOOL)hasInstalledTap { return self.testTapInstalled; }
- (BOOL)isRunning { return self.testRunning; }
- (void)recordOperation:(NSString *)operation {
    [self.recordedOperations addObject:operation];
    if ([self.failingOperations containsObject:operation]) {
        [NSException raise:NSInvalidArgumentException format:@"Injected microphone %@ failure", operation];
    }
}
- (void)prepare { [self recordOperation:@"prepare"]; }
- (BOOL)startAndReturnError:(NSError **)error {
    [self recordOperation:@"start"];
    self.testRunning = YES;
    return YES;
}
- (void)stop {
    [self recordOperation:@"stop"];
    self.testRunning = NO;
}
@end
