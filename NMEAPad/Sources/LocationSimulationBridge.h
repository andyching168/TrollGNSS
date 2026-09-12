#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN
// Private API stays behind this boundary. A successful call is NOT a locationd ACK.
@interface LocationSimulationBridge : NSObject
- (BOOL)prepare:(NSError **)error;
- (BOOL)submit:(CLLocation *)location error:(NSError **)error;
- (BOOL)stop:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
