#import "IRealLibrary.h"
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>

@interface IRealLibrary () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong) NSSearchField* search;
@property (nonatomic, strong) NSTableView* table;
@property (nonatomic, strong) NSTextField* status;
@property (nonatomic, strong) NSButton* choose;
@property (nonatomic, strong) NSArray<NSDictionary*>* catalog;
@property (nonatomic, strong) NSArray<NSDictionary*>* filtered;
@property (nonatomic, strong) NSTimer* refreshTimer;
@property (nonatomic, strong) NSDate* catalogDate;
@property (nonatomic) BOOL reading;
@property (nonatomic, strong) NSTask* syncTask;
@end

@implementation IRealLibrary

+ (NSString*)libraryDirectory {
    NSString* override = NSProcessInfo.processInfo.environment[@"OPENSCRIBE_IREAL_LIBRARY"];
    if (override.length) return override;
    NSString* base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [base stringByAppendingPathComponent:@"OpenScribe/ireal-popular"];
}

- (instancetype)init {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 600)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self = [super initWithWindow:window];
    if (!self) return nil;
    window.title = @"Popular iReal Charts";
    window.contentMinSize = NSMakeSize(680, 420);
    window.releasedWhenClosed = NO;
    [window center];
    NSView* content = window.contentView;
    self.search = [[NSSearchField alloc] initWithFrame:NSMakeRect(16, 550, 788, 30)];
    self.search.placeholderString = @"Search title, composer, style or key";
    self.search.delegate = self;
    self.search.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.search];
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 100, 788, 436)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    self.table.usesAlternatingRowBackgroundColors = YES;
    self.table.rowHeight = 26;
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.target = self;
    self.table.doubleAction = @selector(chooseChart:);
    NSArray* keys = @[@"title", @"composer", @"key", @"style"];
    NSArray* labels = @[@"Title", @"Composer", @"Key", @"Style"];
    CGFloat widths[] = {310, 220, 60, 170};
    for (NSUInteger i = 0; i < keys.count; ++i) {
        NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:keys[i]];
        column.title = labels[i]; column.width = widths[i];
        [self.table addTableColumn:column];
    }
    scroll.documentView = self.table;
    [content addSubview:scroll];
    self.status = [NSTextField wrappingLabelWithString:@"Loading your library…"];
    self.status.frame = NSMakeRect(16, 58, 788, 34);
    self.status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.status.font = [NSFont systemFontOfSize:12];
    self.status.textColor = NSColor.secondaryLabelColor;
    [content addSubview:self.status];
    NSArray* titles = @[@"Update Lists", @"Pause", @"View Source", @"Use Chart"];
    SEL actions[] = {@selector(startSync:), @selector(pauseSync:), @selector(viewSource:), @selector(chooseChart:)};
    CGFloat xs[] = {16, 178, 276, 674};
    CGFloat ws[] = {156, 88, 112, 130};
    for (NSUInteger i = 0; i < titles.count; ++i) {
        NSButton* button = [NSButton buttonWithTitle:titles[i] target:self action:actions[i]];
        button.frame = NSMakeRect(xs[i], 16, ws[i], 30);
        button.autoresizingMask = (i == 3 ? NSViewMinXMargin : NSViewMaxXMargin) | NSViewMaxYMargin;
        [content addSubview:button];
        if (i == 3) { self.choose = button; button.enabled = NO; }
    }
    self.catalog = @[]; self.filtered = @[];
    __weak IRealLibrary* weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer* timer) {
        (void)timer;
        if (weakSelf.window.visible) [weakSelf refresh];
    }];
    return self;
}

- (void)dealloc { [self.refreshTimer invalidate]; }
- (void)showLibrary {
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self refresh];
    [self.window makeFirstResponder:self.search];
}

- (void)refresh {
    NSString* directory = [IRealLibrary libraryDirectory];
    NSData* statusData = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"status.json"]];
    NSDictionary* status = statusData ? [NSJSONSerialization JSONObjectWithData:statusData options:0 error:nil] : nil;
    if ([status isKindOfClass:NSDictionary.class]) {
        NSString* phase = status[@"phase"];
        int pid = [status[@"pid"] intValue];
        BOOL running = pid > 0 && kill(pid, 0) == 0;
        NSString* label = @"Paused — choose Update Lists to continue";
        if ([phase isEqual:@"complete"]) label = @"Download complete";
        else if ([phase isEqual:@"incomplete"]) label = @"Some pages were unavailable — resume to retry";
        else if (running && [phase isEqual:@"downloading"]) label = @"Downloading popular playlists…";
        else if (running && [phase isEqual:@"waiting"]) label = @"Waiting before retrying the forum…";
        self.status.stringValue = [NSString stringWithFormat:@"%ld charts · %ld pages read · %ld remaining · %ld unavailable\n%@",
            [status[@"songs"] integerValue], [status[@"done"] integerValue],
            [status[@"pending"] integerValue], [status[@"failed"] integerValue], label];
    } else {
        self.status.stringValue = @"Jazz 1460, Brazilian 220, Latin 50, Blues 50, Pop 400 and Country 50. Choose Update Lists to download.";
    }
    NSString* path = [directory stringByAppendingPathComponent:@"catalog.json"];
    NSDate* modified = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileModificationDate];
    if (!modified || [modified isEqual:self.catalogDate] || self.reading) return;
    self.reading = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData* data = [NSData dataWithContentsOfFile:path];
        id catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.reading = NO;
            if ([catalog isKindOfClass:NSArray.class]) {
                self.catalog = catalog;
                self.catalogDate = modified;
                [self filterCatalog];
            }
        });
    });
}

- (void)controlTextDidChange:(NSNotification*)notification { (void)notification; [self filterCatalog]; }
- (void)filterCatalog {
    NSString* selectedID = [self selectedChart][@"id"];
    NSString* query = [self.search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!query.length) self.filtered = self.catalog;
    else self.filtered = [self.catalog filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary* chart, NSDictionary* bindings) {
        (void)bindings;
        NSString* text = [NSString stringWithFormat:@"%@ %@ %@ %@", chart[@"title"], chart[@"composer"], chart[@"style"], chart[@"key"]];
        return [text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound;
    }]];
    [self.table reloadData];
    [self.table deselectAll:nil];
    if (selectedID) {
        NSUInteger index = [self.filtered indexOfObjectPassingTest:^BOOL(NSDictionary* chart, NSUInteger i, BOOL* stop) {
            (void)i; (void)stop; return [chart[@"id"] isEqual:selectedID];
        }];
        if (index != NSNotFound) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    }
    self.choose.enabled = self.table.selectedRow >= 0;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)table { (void)table; return self.filtered.count; }
- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table;
    NSTextField* text = [NSTextField labelWithString:self.filtered[row][column.identifier] ?: @""];
    text.lineBreakMode = NSLineBreakByTruncatingTail;
    text.toolTip = text.stringValue;
    return text;
}
- (void)tableViewSelectionDidChange:(NSNotification*)notification { (void)notification; self.choose.enabled = self.table.selectedRow >= 0; }
- (NSDictionary*)selectedChart {
    NSInteger row = self.table.selectedRow;
    return row >= 0 && row < (NSInteger)self.filtered.count ? self.filtered[row] : nil;
}

- (void)startSync:(id)sender {
    (void)sender;
    if (self.syncTask.running) return;
    NSString* directory = [IRealLibrary libraryDirectory];
    NSError* error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        self.status.stringValue = error.localizedDescription; return;
    }
    NSString* resources = NSBundle.mainBundle.resourcePath;
    NSString* script = [resources stringByAppendingPathComponent:@"ireal-helper/library.py"];
    NSString* python = [resources stringByAppendingPathComponent:@"python/bin/python3.11"];
    if (![NSFileManager.defaultManager fileExistsAtPath:script] || ![NSFileManager.defaultManager isExecutableFileAtPath:python]) {
        self.status.stringValue = @"The library downloader is missing from this app. Reinstall OpenScribe."; return;
    }
    NSString* log = [directory stringByAppendingPathComponent:@"sync.log"];
    if (![NSFileManager.defaultManager fileExistsAtPath:log]) [NSFileManager.defaultManager createFileAtPath:log contents:nil attributes:nil];
    NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:log];
    [handle seekToEndOfFile];
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:python];
    task.arguments = @[@"-B", script, @"--output-dir", directory, @"--retry-failed", @"--refresh", @"--scope", @"essentials"];
    task.standardOutput = handle;
    task.standardError = handle;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:&error]) self.status.stringValue = error.localizedDescription;
    else { self.syncTask = task; self.status.stringValue = @"Starting library download…"; }
    [handle closeFile];
}
- (void)pauseSync:(id)sender {
    (void)sender;
    NSString* path = [[IRealLibrary libraryDirectory] stringByAppendingPathComponent:@"pause"];
    [NSFileManager.defaultManager createFileAtPath:path contents:[NSData data] attributes:nil];
    self.status.stringValue = @"Pausing after the current requests…";
}
- (void)viewSource:(id)sender {
    (void)sender;
    NSURL* url = [NSURL URLWithString:[self selectedChart][@"source"] ?: @""];
    if ([url.scheme isEqual:@"https"] && [url.host isEqual:@"forums.irealpro.com"]) [NSWorkspace.sharedWorkspace openURL:url];
}

static void drawText(NSString* text, NSRect rect, CGFloat size, BOOL bold, NSColor* color) {
    CGContextSetFillColorWithColor(NSGraphicsContext.currentContext.CGContext, color.CGColor);
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:[NSFont fontWithName:bold ? @"Helvetica-Bold" : @"Helvetica" size:size],
        NSForegroundColorAttributeName:color}];
}

- (NSURL*)renderChart:(NSDictionary*)chart error:(NSError**)error {
    NSString* directory = [[IRealLibrary libraryDirectory] stringByAppendingPathComponent:@"pdf"];
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSString* path = [directory stringByAppendingPathComponent:[chart[@"id"] stringByAppendingPathExtension:@"pdf"]];
    NSURL* url = [NSURL fileURLWithPath:path];
    CGRect media = CGRectMake(0, 0, 612, 792);
    CGContextRef context = CGPDFContextCreateWithURL((__bridge CFURLRef)url, &media, NULL);
    if (!context) return nil;
    NSArray* cells = chart[@"cells"];
    NSUInteger pages = MAX(1, (cells.count + 111) / 112);
    for (NSUInteger page = 0; page < pages; ++page) {
        CGPDFContextBeginPage(context, NULL);
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
        [NSColor.whiteColor setFill]; NSRectFill(NSMakeRect(0, 0, 612, 792));
        drawText(chart[@"title"], NSMakeRect(36, 722, 540, 38), 24, YES, NSColor.blackColor);
        NSString* subtitle = [NSString stringWithFormat:@"%@  ·  %@  ·  %@", chart[@"composer"], chart[@"key"], chart[@"style"]];
        drawText(subtitle, NSMakeRect(36, 692, 540, 28), 12, NO, NSColor.darkGrayColor);
        for (NSUInteger i = page * 112; i < MIN(cells.count, (page + 1) * 112); ++i) {
            NSUInteger column = i % 16, row = (i - page * 112) / 16;
            CGFloat x = 36 + column * 33.75, y = 604 - row * 80;
            NSDictionary* cell = cells[i];
            // Each symbol stays in its original cell, including empty cells.
            for (NSString* side in @[@"left", @"right"]) {
                NSString* mark = cell[side];
                if (!mark.length) continue;
                BOOL right = [side isEqual:@"right"];
                if (right && [mark isEqual:@"|"] && column != 15) continue;
                CGFloat bx = x + (right ? 33.75 : 0);
                BOOL multiple = ![mark isEqual:@"|"];
                BOOL repeat = [mark isEqual:@"{"] || [mark isEqual:@"}"];
                [NSColor.blackColor setStroke];
                CGContextSetRGBStrokeColor(context, 0, 0, 0, 1);
                for (int n = 0; n < (multiple ? 2 : 1); ++n) {
                    CGFloat offset = n ? (right ? -4 : 4) : 0;
                    NSBezierPath* line = [NSBezierPath bezierPath];
                    line.lineWidth = (n == 0 && (repeat || [mark isEqual:@"Z"])) ? 2.5 : 0.8;
                    [line moveToPoint:NSMakePoint(bx + offset, y + 5)];
                    [line lineToPoint:NSMakePoint(bx + offset, y + 34)];
                    [line stroke];
                }
                if (repeat) {
                    [NSColor.blackColor setFill];
                    CGContextSetRGBFillColor(context, 0, 0, 0, 1);
                    CGFloat dx = bx + (right ? -9 : 9);
                    for (int dot = 0; dot < 2; ++dot)
                        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(dx - 1.5, y + 14 + dot * 9, 3, 3)] fill];
                }
            }
            NSMutableArray* annotations = [NSMutableArray array];
            for (NSString* token in cell[@"annotations"]) {
                NSString* label = token;
                if ([token hasPrefix:@"*"]) label = [token substringFromIndex:1];
                else if ([token hasPrefix:@"T"] && token.length == 3)
                    label = [token isEqual:@"T12"] ? @"12/8" : [NSString stringWithFormat:@"%@/%@", [token substringWithRange:NSMakeRange(1,1)], [token substringFromIndex:2]];
                else if ([token hasPrefix:@"N"]) label = [NSString stringWithFormat:@"%@.", [token substringFromIndex:1]];
                else label = @{@"S":@"Segno", @"Q":@"Coda", @"f":@"Fermata", @"U":@"End"}[token] ?: token;
                [annotations addObject:label];
            }
            drawText([annotations componentsJoinedByString:@" · "], NSMakeRect(x + 4, y + 42, 130, 20), 10, YES, NSColor.darkGrayColor);
            for (NSString* comment in cell[@"comments"]) {
                BOOL raised = [comment hasPrefix:@"*"] && comment.length >= 3;
                CGFloat offset = raised ? [[comment substringWithRange:NSMakeRange(1,2)] doubleValue] * 0.65 - 16 : -16;
                drawText(raised ? [comment substringFromIndex:3] : comment, NSMakeRect(x + 4, y + offset, 160, 18), 9, NO, NSColor.darkGrayColor);
            }
            NSString* chord = cell[@"chord"] ?: @"";
            NSUInteger span = 1;
            while (column + span < 16 && i + span < cells.count) {
                NSDictionary* next = cells[i + span];
                if ([cells[i + span - 1][@"right"] length] || [next[@"left"] length] || [next[@"chord"] length]) break;
                ++span;
            }
            CGFloat inset = [cell[@"left"] isEqual:@"{"] ? 14 : 5;
            CGFloat width = span * 33.75 - inset - 5;
            CGFloat fontSize = 16;
            CGFloat naturalWidth = [chord sizeWithAttributes:@{NSFontAttributeName:[NSFont fontWithName:@"Helvetica-Bold" size:fontSize]}].width;
            if (naturalWidth > width) fontSize *= width / naturalWidth;
            drawText(chord, NSMakeRect(x + inset, y + 7, width + 1, 27), fontSize, YES, NSColor.blackColor);
            drawText(cell[@"alternate"] ?: @"", NSMakeRect(x + inset, y + 29, 100, 15), 9, NO, NSColor.darkGrayColor);
        }
        drawText([NSString stringWithFormat:@"iReal chord chart · forums.irealpro.com · %lu / %lu", (unsigned long)page + 1, (unsigned long)pages],
            NSMakeRect(36, 38, 540, 18), 9, NO, NSColor.grayColor);
        if ([chart[@"unsupported"] count]) drawText(@"Some notation symbols could not be displayed. Check the original source.", NSMakeRect(36, 18, 540, 18), 9, NO, NSColor.darkGrayColor);
        [NSGraphicsContext restoreGraphicsState];
        CGPDFContextEndPage(context);
    }
    CGPDFContextClose(context); CGContextRelease(context);
    return url;
}

- (void)chooseChart:(id)sender {
    (void)sender;
    NSDictionary* summary = [self selectedChart];
    NSString* identifier = summary[@"id"];
    if (identifier.length != 64 || [identifier rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location != NSNotFound) return;
    NSString* path = [[[IRealLibrary libraryDirectory] stringByAppendingPathComponent:@"charts"] stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];
    NSData* data = [NSData dataWithContentsOfFile:path];
    NSDictionary* chart = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSError* error = nil;
    NSURL* url = [chart isKindOfClass:NSDictionary.class] ? [self renderChart:chart error:&error] : nil;
    if (!url) { self.status.stringValue = error.localizedDescription ?: @"This chart could not be opened. Try downloading it again."; return; }
    if (self.selectionHandler) self.selectionHandler(url);
    [self.window orderOut:nil];
}
@end
