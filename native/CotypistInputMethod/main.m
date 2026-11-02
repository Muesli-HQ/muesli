#import <Cocoa/Cocoa.h>
#import <InputMethodKit/InputMethodKit.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *connection = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"InputMethodConnectionName"];
        IMKServer *server = [[IMKServer alloc] initWithName:connection
                                           bundleIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
        (void)server;
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
