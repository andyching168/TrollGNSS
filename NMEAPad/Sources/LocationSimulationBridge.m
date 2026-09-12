#import "LocationSimulationBridge.h"
#import <objc/message.h>
#import <mach/mach.h>
#import <dlfcn.h>

@implementation LocationSimulationBridge {
    id _manager;
}
static NSError *BridgeError(NSString *message) {
    return [NSError errorWithDomain:@"NMEAPad.LocationSimulation" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSString *BridgeText(NSString *key) {
    return NSLocalizedStringFromTableInBundle(key, nil, NSBundle.mainBundle, @"");
}
static void Call(id object, NSString *name) {
    ((void (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}
- (BOOL)prepare:(NSError **)error {
    @try {
        if (_manager) return YES;
        // iOS SDK omits servers/bootstrap.h. Signature checked against Apple's macOS header.
        kern_return_t (*lookup)(mach_port_t, const char *, mach_port_t *) = dlsym(RTLD_DEFAULT, "bootstrap_look_up");
        mach_port_t *bootstrap = dlsym(RTLD_DEFAULT, "bootstrap_port");
        if (!lookup || !bootstrap) {
            if (error) *error = BridgeError(BridgeText(@"bridge.bootstrap_unavailable"));
            return NO;
        }
        mach_port_t service = MACH_PORT_NULL;
        kern_return_t result = lookup(*bootstrap, "com.apple.locationd.simulation", &service);
        if (result != KERN_SUCCESS) {
            if (error) *error = BridgeError([NSString stringWithFormat:BridgeText(@"bridge.lookup_failed"), result]);
            return NO;
        }
        mach_port_deallocate(mach_task_self(), service);
        Class type = NSClassFromString(@"CLSimulationManager");
        if (!type) { if (error) *error = BridgeError(BridgeText(@"bridge.manager_unavailable")); return NO; }
        id manager = [[type alloc] init];
        for (NSString *name in @[@"stopLocationSimulation", @"clearSimulatedLocations",
                                 @"appendSimulatedLocation:", @"flush", @"startLocationSimulation",
                                 @"setLocationRepeatBehavior:", @"setLocationDeliveryBehavior:"]) {
            if (![manager respondsToSelector:NSSelectorFromString(name)]) {
                if (error) *error = BridgeError([NSString stringWithFormat:BridgeText(@"bridge.selector_missing"), name]);
                return NO;
            }
        }
        _manager = manager;
        // Values documented in udevsharold/locsim main.m: pass-through, unavailable at end.
        ((void (*)(id, SEL, uint8_t))objc_msgSend)(_manager, NSSelectorFromString(@"setLocationDeliveryBehavior:"), 0);
        ((void (*)(id, SEL, uint8_t))objc_msgSend)(_manager, NSSelectorFromString(@"setLocationRepeatBehavior:"), 0);
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = BridgeError([NSString stringWithFormat:@"%@: %@", exception.name, exception.reason]);
        return NO;
    }
}
- (BOOL)submit:(CLLocation *)location error:(NSError **)error {
    if (![self prepare:error]) return NO;
    @try {
        // Conservative Geranium/LocSim transaction; actual delivery cadence must be measured.
        Call(_manager, @"stopLocationSimulation");
        Call(_manager, @"clearSimulatedLocations");
        ((void (*)(id, SEL, id))objc_msgSend)(_manager, NSSelectorFromString(@"appendSimulatedLocation:"), location);
        Call(_manager, @"flush");
        Call(_manager, @"startLocationSimulation");
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = BridgeError([NSString stringWithFormat:@"submit %@: %@", exception.name, exception.reason]);
        return NO;
    }
}
- (BOOL)stop:(NSError **)error {
    if (![self prepare:error]) return NO;
    @try {
        Call(_manager, @"stopLocationSimulation");
        Call(_manager, @"clearSimulatedLocations");
        Call(_manager, @"flush");
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = BridgeError([NSString stringWithFormat:@"stop %@: %@", exception.name, exception.reason]);
        return NO;
    }
}
@end
