// Muesli Cotypist input method — the thin half of Cotypist (experimental).
//
// Every key passes through to the app untouched. After a word boundary (space, punctuation) or a
// pause inside a word, the helper asks Muesli for a suggestion over a Unix socket and shows it as
// marked text after the caret ("ghost"). Tab inserts it, Option-Right inserts its next word; any
// other key clears it and passes through.
// Muesli gathers context, runs the model and journals outcomes; this process needs no permissions,
// and it never waits on Muesli while handling a key — a slow or absent Muesli means no ghost, never
// a stalled keyboard.

#import <Cocoa/Cocoa.h>
#import <InputMethodKit/InputMethodKit.h>
#import <sys/socket.h>
#import <sys/un.h>

extern NSString *NSTextInputChromaticMarkedTextAttributeName;

// Private on IMKInputController: marks a range of the marked text as "chromatic", drawn with the
// input method's own attributes (grey ghost) instead of the composition underline.
@interface IMKInputController (Chromatic)
- (id)markChromaticRange:(NSRange)range;
@end

static const NSTimeInterval kBoundaryDelay = 0.06;
// The pause before completing a half-typed word; 0 turns that off. Muesli sends the user's setting
// with every reply.
static NSTimeInterval sMidWordDelay = 0.5;
static const NSUInteger kContextChars = 1500;

// Diagnostics for the experiment: request outcomes and timings only, never typed text.
static void HelperLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *path = [@"~/Library/Logs/MuesliCotypist.log" stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    [handle seekToEndOfFile];
    [handle writeData:[[NSString stringWithFormat:@"%@ %@\n", [NSDate date], line] dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

#pragma mark - Muesli socket

static NSString *SocketPath(void) {
    NSString *support = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"MuesliSupportDirectoryName"] ?: @"Muesli";
    return [[@"~/Library/Application Support" stringByExpandingTildeInPath]
        stringByAppendingPathComponent:[support stringByAppendingPathComponent:@"cotypist.sock"]];
}

// One request per connection: a JSON line out, a JSON line back. Runs off the main thread.
static NSDictionary *SendToMuesli(NSDictionary *request, NSTimeInterval timeout) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, SocketPath().fileSystemRepresentation, sizeof(address.sun_path));
    struct timeval tv = {(long)timeout, (int)((timeout - (long)timeout) * 1e6)};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        HelperLog(@"connect failed (%s) to %@", strerror(errno), SocketPath());
        close(fd);
        return nil;
    }
    NSMutableData *out = [[NSJSONSerialization dataWithJSONObject:request options:0 error:nil] mutableCopy];
    [out appendBytes:"\n" length:1];
    if (write(fd, out.bytes, out.length) != (ssize_t)out.length) { close(fd); return nil; }
    NSMutableData *in = [NSMutableData data];
    char buffer[16384];
    ssize_t count;
    while ((count = read(fd, buffer, sizeof(buffer))) > 0) {
        [in appendBytes:buffer length:(NSUInteger)count];
        if (memchr(buffer, '\n', (size_t)count)) break;
    }
    close(fd);
    id json = in.length ? [NSJSONSerialization JSONObjectWithData:in options:0 error:nil] : nil;
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

static void AskMuesli(NSDictionary *request, void (^completion)(NSDictionary *response)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *response = SendToMuesli(request, 3.0);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(response); });
    });
}

static void TellMuesli(NSDictionary *message) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ SendToMuesli(message, 1.0); });
}

#pragma mark - Controller

@interface CotypistController : IMKInputController
@end

@implementation CotypistController {
    NSTimer *_debounce;
    NSString *_ghost;             // the suggestion on screen, nil when none
    NSUInteger _generation;       // bumped on every key: a reply for an older generation is stale
    BOOL _afterSpace;
    BOOL _midWord;
    CFAbsoluteTime _triggeredAt;
    NSMutableDictionary *_shown;  // outcome record for the suggestion on screen
    NSMutableString *_acceptedSoFar;  // words of it taken one at a time
    // What the user typed into the current field — context for clients that hand input methods no
    // text (cmux/Ghostty) when Muesli can't read the screen either.
    NSMutableString *_typed;
}

- (NSUInteger)recognizedEvents:(id)sender {
    return NSEventMaskKeyDown | NSEventMaskFlagsChanged | NSEventMaskLeftMouseDown;
}

- (BOOL)handleEvent:(NSEvent *)event client:(id)sender {
    if (event.type == NSEventTypeFlagsChanged) return NO;
    _generation++;
    if (event.type == NSEventTypeLeftMouseDown) {
        [self finishShown:@"dismissed"];
        [self clearGhost:sender];
        return NO;
    }
    if (event.type != NSEventTypeKeyDown) return NO;

    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL plainTab = event.keyCode == 48 && (mods & (NSEventModifierFlagShift | NSEventModifierFlagCommand |
                                                    NSEventModifierFlagControl | NSEventModifierFlagOption)) == 0;
    if (_ghost && plainTab) {
        [self accept:_ghost rest:nil client:sender];
        return YES;  // consumed: the app never sees this Tab
    }
    BOOL optionRight = event.keyCode == 124 && (mods & (NSEventModifierFlagShift | NSEventModifierFlagCommand |
                                                        NSEventModifierFlagControl | NSEventModifierFlagOption)) == NSEventModifierFlagOption;
    if (_ghost && optionRight) {
        NSUInteger length = NextWordLength(_ghost);
        NSString *rest = [_ghost substringFromIndex:length];
        BOOL more = [rest stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length > 0;
        [self accept:[_ghost substringToIndex:length] rest:more ? rest : nil client:sender];
        return YES;
    }

    if (_shown) [self finishShown:@"ignored"];
    [self clearGhost:sender];
    [self trackKey:event];

    if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return NO;
    NSString *chars = event.characters;
    if (chars.length != 1) return NO;
    static NSCharacterSet *boundary, *wordCharacters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        boundary = [NSCharacterSet characterSetWithCharactersInString:@" .,;:!?)"];
        NSMutableCharacterSet *word = [NSMutableCharacterSet alphanumericCharacterSet];
        [word addCharactersInString:@"'-"];
        wordCharacters = word;
    });
    unichar typed = [chars characterAtIndex:0];
    // Word boundary: suggest the next words almost at once. Inside a word: wait for a pause, then
    // complete the word and continue.
    NSTimeInterval delay;
    if ([boundary characterIsMember:typed]) {
        _midWord = NO;
        delay = kBoundaryDelay;
    } else if ([wordCharacters characterIsMember:typed] && sMidWordDelay > 0) {
        _midWord = YES;
        delay = sMidWordDelay;
    } else {
        return NO;
    }
    _afterSpace = typed == ' ';
    _triggeredAt = CFAbsoluteTimeGetCurrent();
    // The app inserts the character after we return; read the context once it has.
    __weak typeof(self) weakSelf = self;
    _debounce = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        [weakSelf requestSuggestion];
    }];
    return NO;
}

// Leading spaces, then up to the next space: " of" from " of a word.", "dle" from "dle of".
static NSUInteger NextWordLength(NSString *text) {
    NSUInteger index = 0;
    while (index < text.length && [text characterAtIndex:index] == ' ') index++;
    while (index < text.length && [text characterAtIndex:index] != ' ') index++;
    return index;
}

// Inserts `text` from the ghost; `rest`, when given, stays on screen as the remaining suggestion.
- (void)accept:(NSString *)text rest:(NSString *)rest client:(id)sender {
    [_debounce invalidate];
    _ghost = nil;
    if (!_acceptedSoFar) _acceptedSoFar = [NSMutableString string];
    [_acceptedSoFar appendString:text];
    [_typed appendString:text];
    // Clear the composition now and insert once this key event has finished: inserting during
    // the keyDown lets clients like Ghostty fold the text into the consumed key.
    [sender setMarkedText:@"" selectionRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    id client = sender;
    NSUInteger generation = _generation;
    dispatch_async(dispatch_get_main_queue(), ^{
        [client insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        if (rest && generation == self->_generation) [self showGhost:rest client:client];
    });
    if (!rest) [self finishShown:@"accepted"];
}

- (void)trackKey:(NSEvent *)event {
    if (!_typed) _typed = [NSMutableString string];
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    switch (event.keyCode) {
        case 51:  // Backspace
            if (mods & (NSEventModifierFlagOption | NSEventModifierFlagCommand)) { [_typed setString:@""]; return; }
            if (_typed.length) [_typed deleteCharactersInRange:[_typed rangeOfComposedCharacterSequenceAtIndex:_typed.length - 1]];
            return;
        case 36: case 76: case 53:                // Return, Enter, Escape: sent or abandoned
        case 123: case 124: case 125: case 126:   // arrows: the record no longer matches the caret
            [_typed setString:@""];
            return;
    }
    if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) return;
    NSString *chars = event.characters;
    if (chars.length && [chars characterAtIndex:0] >= 0x20) [_typed appendString:chars];
}

- (void)requestSuggestion {
    id client = [self client];
    if (!client) return;
    NSString *bundleID = [client respondsToSelector:@selector(bundleIdentifier)] ? [client bundleIdentifier] : @"";
    NSString *field = @"";
    NSRange selection = [client selectedRange];
    if (selection.location != NSNotFound && selection.length == 0) {
        NSUInteger start = selection.location > kContextChars ? selection.location - kContextChars : 0;
        field = [client attributedSubstringFromRange:NSMakeRange(start, selection.location - start)].string ?: @"";
    } else if (selection.length > 0) {
        return;  // a selection: typing would replace it, nothing to continue
    }
    HelperLog(@"request app=%@ field=%lu typed=%lu midWord=%d", bundleID, (unsigned long)field.length, (unsigned long)_typed.length, _midWord);
    NSDictionary *base = @{
        @"type": @"suggest",
        @"app": bundleID ?: @"",
        @"field": field,
        @"typed": [_typed copy] ?: @"",
        @"midWord": @(_midWord),
        @"afterSpace": @(_afterSpace),
    };
    NSUInteger generation = _generation;
    CFAbsoluteTime triggeredAt = _triggeredAt;
    NSString *trigger = _midWord ? @"mid-word" : @"boundary";

    // Stage 1: the first word alone, shown as soon as it clears the gate.
    NSMutableDictionary *first = [base mutableCopy];
    first[@"firstWordOnly"] = @YES;
    AskMuesli(first, ^(NSDictionary *one) {
        [CotypistController applySettings:one];
        HelperLog(@"stage1 %@ text=%lu rejection=%@ source=%@ model=%@ms", generation == self->_generation ? @"current" : @"stale",
                  (unsigned long)[one[@"text"] length], one[@"rejection"], one[@"source"], one[@"modelMs"]);
        if (generation != self->_generation) return;
        NSString *firstText = one[@"text"];
        if (firstText.length) {
            [self showGhost:firstText client:[self client]];
            self->_shown = [@{@"app": bundleID ?: @"", @"trigger": trigger, @"text": firstText,
                              @"source": one[@"source"] ?: @"", @"first_ms": @(round((CFAbsoluteTimeGetCurrent() - triggeredAt) * 1000)),
                              @"first_word_logprob": one[@"firstWordLogProb"] ?: @0} mutableCopy];
        } else if (![one[@"rejection"] isEqual:@"first word not complete yet"]) {
            return;  // the gate said no (or Muesli isn't there): don't spend a second request
        }
        if ([one[@"complete"] boolValue]) return;  // one-word suggestions: nothing more to fetch
        // Stage 2: the full suggestion, extending the ghost in place if nothing changed meanwhile.
        NSMutableDictionary *full = [base mutableCopy];
        full[@"firstWordOnly"] = @NO;
        AskMuesli(full, ^(NSDictionary *two) {
            if (generation != self->_generation) return;
            NSString *fullText = two[@"text"];
            if (!fullText.length) return;
            if (firstText.length && (![fullText hasPrefix:firstText] || fullText.length <= firstText.length)) return;
            [self showGhost:fullText client:[self client]];
            double ms = round((CFAbsoluteTimeGetCurrent() - triggeredAt) * 1000);
            if (!self->_shown) {
                self->_shown = [@{@"app": bundleID ?: @"", @"trigger": trigger, @"source": two[@"source"] ?: @"",
                                  @"first_ms": @(ms), @"first_word_logprob": two[@"firstWordLogProb"] ?: @0} mutableCopy];
            }
            self->_shown[@"text"] = fullText;
            self->_shown[@"full_ms"] = @(ms);
        });
    });
}

+ (void)applySettings:(NSDictionary *)reply {
    NSNumber *delay = reply[@"midWordDelay"];
    if ([delay isKindOfClass:[NSNumber class]]) sMidWordDelay = delay.doubleValue;
}

// `accepted` covers all of it; otherwise words taken one at a time make it "partial".
- (void)finishShown:(NSString *)outcome {
    NSString *accepted = [_acceptedSoFar copy] ?: @"";
    _acceptedSoFar = nil;
    if (!_shown) return;
    NSMutableDictionary *record = _shown;
    record[@"type"] = @"outcome";
    record[@"outcome"] = accepted.length && ![outcome isEqual:@"accepted"] ? @"partial" : outcome;
    record[@"accepted"] = accepted;
    TellMuesli(record);
    _shown = nil;
}

- (BOOL)clientSupportsChromatic:(id)client {
    SEL sel = NSSelectorFromString(@"supportsChromaticMarkedText");
    if (![client respondsToSelector:sel]) return NO;
    return ((BOOL (*)(id, SEL))[client methodForSelector:sel])(client, sel);
}

- (void)showGhost:(NSString *)text client:(id)client {
    if (!client || !text.length) return;
    NSMutableDictionary *attrs = [@{
        NSForegroundColorAttributeName: [NSColor colorWithWhite:0.5 alpha:1.0],
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleNone),
        NSUnderlineColorAttributeName: [NSColor clearColor],
    } mutableCopy];
    // The chromatic flag also sets NSMarkedClauseSegment, which Chromium draws as a highlighted
    // "selected clause": only clients that support chromatic text get it (they draw grey ghosts).
    if ([self clientSupportsChromatic:client]) {
        id chromatic = [self markChromaticRange:NSMakeRange(0, text.length)];
        if ([chromatic isKindOfClass:[NSDictionary class]]) [attrs addEntriesFromDictionary:chromatic];
        attrs[NSTextInputChromaticMarkedTextAttributeName] = @YES;
    }
    NSAttributedString *ghost = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    // The caret stays at the start of the marked text, so the ghost reads as ahead of the caret.
    [client setMarkedText:ghost selectionRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
    _ghost = text;
}

- (void)clearGhost:(id)sender {
    [_debounce invalidate];
    if (!_ghost) return;
    _ghost = nil;
    [sender setMarkedText:@"" selectionRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
}

// Focus changes call commitComposition: the ghost must vanish, never be committed.
- (void)commitComposition:(id)sender {
    _generation++;
    [_typed setString:@""];
    if (_shown) [self finishShown:@"dismissed"];
    [self clearGhost:sender];
}

- (void)deactivateServer:(id)sender {
    _generation++;
    if (_shown) [self finishShown:@"dismissed"];
    [self clearGhost:sender];
    [super deactivateServer:sender];
}

@end
