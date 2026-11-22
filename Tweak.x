// RainMhz x ChargeLimiter compatibility bridge (runs inside SpringBoard, same process as RainMhz).
// When "Compatibility Mode" is ON it keeps the RainMhz options that can fight ChargeLimiter's
// thermal-simulation charge holding switched OFF, remembers the user's original values, and
// restores them when Compatibility Mode is turned OFF again.
#import <Foundation/Foundation.h>
#import <notify.h>
#import <dispatch/dispatch.h>

static NSString *const kOur  = @"com.zidaneadam.rainclcompat";
static NSString *const kRain = @"com.rain.rainmhz";
static const char *kRainNote = "com.rain.rainmhz/prefsChanged";
static const char *kOurNote  = "com.zidaneadam.rainclcompat/changed";

// toggle = our per-rule switch, key = RainMhz pref key, bad = value we must not leave in place, good = value we force
static NSArray<NSDictionary *> *Rules(void) {
    return @[
        @{@"toggle": @"disableThermalBypass", @"key": @"thermalSpoofEnabled",  @"bad": @YES, @"good": @NO},
        @{@"toggle": @"disableChargingTurbo", @"key": @"chargingTurboEnabled", @"bad": @YES, @"good": @NO},
        @{@"toggle": @"disableActiveCooling", @"key": @"activeCoolingEnabled", @"bad": @YES, @"good": @NO},
        @{@"toggle": @"capExtremeMode",       @"key": @"cpuLevel",             @"bad": @3,   @"good": @4},
        @{@"toggle": @"muteThermalAlerts",    @"key": @"notifyOnThrottle",     @"bad": @YES, @"good": @NO},
        @{@"toggle": @"muteThermalAlerts",    @"key": @"notifyOnTempHigh",     @"bad": @YES, @"good": @NO},
    ];
}

static id PGet(NSString *dom, NSString *key) {
    CFPropertyListRef v = CFPreferencesCopyValue((__bridge CFStringRef)key, (__bridge CFStringRef)dom,
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return v ? (__bridge_transfer id)v : nil;
}
static void PSet(NSString *dom, NSString *key, id val) {
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)val, (__bridge CFStringRef)dom,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}
static void PSync(NSString *dom) {
    CFPreferencesSynchronize((__bridge CFStringRef)dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}
static BOOL ToggleOn(NSString *key, BOOL def) {
    id v = PGet(kOur, key);
    return v ? [v boolValue] : def;
}

static void ApplyCompat(void) {
    @autoreleasepool {
        PSync(kOur);
        PSync(kRain);
        BOOL master = ToggleOn(@"compatEnabled", NO);
        BOOL changed = NO;
        for (NSDictionary *r in Rules()) {
            NSString *key = r[@"key"];
            NSString *savedKey = [@"saved." stringByAppendingString:key];
            id saved = PGet(kOur, savedKey);              // non-nil => we are currently holding this option off
            BOOL want = master && ToggleOn(r[@"toggle"], YES);
            id cur = PGet(kRain, key);
            if (want) {
                if (cur && [cur isEqual:r[@"bad"]]) {
                    if (!saved) PSet(kOur, savedKey, r[@"bad"]);   // remember what the user had
                    PSet(kRain, key, r[@"good"]);
                    changed = YES;
                }
            } else if (saved) {
                if (cur && [cur isEqual:r[@"good"]]) {             // only restore if user did not change it meanwhile
                    PSet(kRain, key, saved);
                    changed = YES;
                }
                PSet(kOur, savedKey, nil);
            }
        }
        PSync(kOur);
        if (changed) {
            PSync(kRain);
            notify_post(kRainNote);                               // tell RainMhz to reload
        }
    }
}

static int gPending = 0;
static void Schedule(double delay) {
    int token = ++gPending;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != gPending) return;                            // a newer request replaced this one
        ApplyCompat();
    });
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        if (![bid isEqualToString:@"com.apple.springboard"]) return;
        static int t1, t2;
        notify_register_dispatch(kOurNote, &t1, dispatch_get_main_queue(), ^(int t) { Schedule(0.3); });
        notify_register_dispatch(kRainNote, &t2, dispatch_get_main_queue(), ^(int t) { Schedule(0.6); });
        Schedule(8.0);                                            // apply once after boot/respring
    }
}
