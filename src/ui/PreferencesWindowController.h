#pragma once
#import <AppKit/AppKit.h>

@interface PreferencesWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate>

+ (instancetype)sharedController;

@end