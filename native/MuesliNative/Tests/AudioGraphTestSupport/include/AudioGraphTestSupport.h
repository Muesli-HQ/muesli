#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Hardware-free engine that raises real NSExceptions at selected graph operations.
@interface MuesliFaultInjectingAudioEngine : AVAudioEngine
@property(nonatomic, copy) NSArray<NSString *> *failingOperations;
@property(nonatomic, readonly, copy) NSArray<NSString *> *operations;
@property(nonatomic, readonly) BOOL hasInstalledTap;
@end

NS_ASSUME_NONNULL_END
