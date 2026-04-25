#import "SettingsWindowController.h"
#import "AudioEngine.h"

static NSString* const kPrefOutputDeviceUID = @"openscribe.outputDeviceUID";

@interface SettingsWindowController ()
@property (nonatomic, assign) AudioEngine* engine;
@property (nonatomic, strong) NSPopUpButton* devicePopup;
@property (nonatomic, strong) NSTextField* statusLabel;
@end

@implementation SettingsWindowController

+ (instancetype)sharedController {
    static SettingsWindowController* s_instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s_instance = [[SettingsWindowController alloc] init]; });
    return s_instance;
}

- (instancetype)init {
    NSRect frame = NSMakeRect(0, 0, 460, 200);
    NSWindow* w = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable)
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"OpenScribe Settings";
    w.releasedWhenClosed = NO;
    w.movableByWindowBackground = YES;
    [w center];

    self = [super initWithWindow:w];
    if (!self) return nil;

    NSView* content = w.contentView;

    NSTextField* header = [NSTextField labelWithString:@"Audio Output"];
    header.font = [NSFont boldSystemFontOfSize:13];
    header.frame = NSMakeRect(20, 150, 200, 20);
    [content addSubview:header];

    NSTextField* hint = [NSTextField labelWithString:@"Choose where OpenScribe sends audio."];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.font = [NSFont systemFontOfSize:11];
    hint.frame = NSMakeRect(20, 130, 420, 16);
    [content addSubview:hint];

    self.devicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 90, 420, 28)];
    self.devicePopup.target = self;
    self.devicePopup.action = @selector(deviceChanged:);
    [content addSubview:self.devicePopup];

    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.textColor = [NSColor tertiaryLabelColor];
    self.statusLabel.font = [NSFont systemFontOfSize:11];
    self.statusLabel.frame = NSMakeRect(20, 60, 420, 16);
    [content addSubview:self.statusLabel];

    return self;
}

- (void)setEngine:(AudioEngine*)engine {
    _engine = engine;
    [self reloadDeviceList];
}

- (void)showWindow {
    [self reloadDeviceList];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)reloadDeviceList {
    [self.devicePopup removeAllItems];

    NSMenuItem* defaultItem = [[NSMenuItem alloc] initWithTitle:@"System Default Output"
                                                        action:nil keyEquivalent:@""];
    defaultItem.representedObject = @"";
    [self.devicePopup.menu addItem:defaultItem];
    [self.devicePopup.menu addItem:[NSMenuItem separatorItem]];

    auto devices = AudioEngine::listOutputDevices();
    for (const auto& d : devices) {
        NSString* name = [NSString stringWithUTF8String:d.name.c_str()];
        NSString* uid = [NSString stringWithUTF8String:d.uid.c_str()];
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""];
        item.representedObject = uid;
        [self.devicePopup.menu addItem:item];
    }

    NSString* savedUID = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefOutputDeviceUID] ?: @"";
    NSInteger selectIdx = 0;
    for (NSInteger i = 0; i < self.devicePopup.numberOfItems; ++i) {
        NSMenuItem* item = [self.devicePopup itemAtIndex:i];
        if ([(item.representedObject ?: @"") isEqualToString:savedUID]) {
            selectIdx = i;
            break;
        }
    }
    [self.devicePopup selectItemAtIndex:selectIdx];
    [self updateStatus];
}

- (void)deviceChanged:(id)sender {
    (void)sender;
    NSMenuItem* item = self.devicePopup.selectedItem;
    NSString* uid = item.representedObject ?: @"";
    [[NSUserDefaults standardUserDefaults] setObject:uid forKey:kPrefOutputDeviceUID];

    if (self.engine) {
        bool ok = self.engine->setOutputDeviceUID(std::string(uid.UTF8String));
        if (!ok) {
            self.statusLabel.stringValue = @"⚠ Couldn't switch to that device — falling back to default.";
            return;
        }
    }
    [self updateStatus];
}

- (void)updateStatus {
    if (!self.engine) { self.statusLabel.stringValue = @""; return; }
    std::string uid = self.engine->currentOutputDeviceUID();
    NSString* nsUID = [NSString stringWithUTF8String:uid.c_str()];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Active device UID: %@",
                                    nsUID.length ? nsUID : @"(unknown)"];
}

@end
