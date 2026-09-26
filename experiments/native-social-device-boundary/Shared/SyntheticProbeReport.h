#import <Foundation/Foundation.h>

@protocol SyntheticProbeReport <NSObject>
- (void)reportFileReadable:(BOOL)fileReadable
             fileErrorCode:(NSInteger)fileErrorCode
            keychainStatus:(NSInteger)keychainStatus
             extensionPID:(int)extensionPID
                    reply:(void (^)(void))reply;
@end
