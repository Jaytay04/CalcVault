#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <unistd.h>
#import "../Shared/SyntheticProbeReport.h"

@interface SyntheticBoundaryHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation SyntheticBoundaryHandler

static NSXPCConnection *activeConnection;

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSDictionary *input = [context.inputItems.firstObject userInfo];
    NSString *hostFile = input[@"hostFile"];
    NSString *keychainService = input[@"keychainService"];
    NSXPCListenerEndpoint *endpoint = input[@"reportEndpoint"];
    if (![hostFile isKindOfClass:NSString.class] ||
        ![keychainService isKindOfClass:NSString.class] ||
        ![endpoint isKindOfClass:NSXPCListenerEndpoint.class]) {
        [context cancelRequestWithError:[NSError errorWithDomain:@"SyntheticBoundaryProbe" code:1 userInfo:nil]];
        return;
    }

    NSError *fileError = nil;
    NSData *hostData = [NSData dataWithContentsOfFile:hostFile options:0 error:&fileError];
    BOOL fileReadable = hostData != nil;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: keychainService,
        (__bridge id)kSecAttrAccount: @"synthetic-host-only",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef keychainValue = NULL;
    OSStatus keychainStatus = SecItemCopyMatching((__bridge CFDictionaryRef)query, &keychainValue);
    if (keychainValue != NULL) {
        CFRelease(keychainValue);
    }

    activeConnection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
    activeConnection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(SyntheticProbeReport)];
    [activeConnection activate];
    id<SyntheticProbeReport> reporter = [activeConnection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"SYNTHETIC_DEVICE_PROBE_XPC_ERROR code=%ld", (long)error.code);
    }];
    [reporter reportFileReadable:fileReadable
                   fileErrorCode:fileError == nil ? 0 : fileError.code
                  keychainStatus:keychainStatus
                   extensionPID:getpid()
                          reply:^{
        [context completeRequestReturningItems:@[] completionHandler:nil];
        [activeConnection invalidate];
        activeConnection = nil;
    }];
}

@end
