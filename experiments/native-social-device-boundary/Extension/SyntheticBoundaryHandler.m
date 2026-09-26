#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <unistd.h>

@interface SyntheticBoundaryHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation SyntheticBoundaryHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSDictionary *input = [context.inputItems.firstObject userInfo];
    NSString *hostFile = input[@"hostFile"];
    NSString *keychainService = input[@"keychainService"];
    if (![hostFile isKindOfClass:NSString.class] ||
        ![keychainService isKindOfClass:NSString.class]) {
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

    NSExtensionItem *result = [NSExtensionItem new];
    result.userInfo = @{
        @"fileReadable": @(fileReadable),
        @"fileErrorCode": @(fileError == nil ? 0 : fileError.code),
        @"keychainStatus": @(keychainStatus),
        @"extensionPID": @(getpid())
    };
    [context completeRequestReturningItems:@[result] completionHandler:nil];
}

@end
