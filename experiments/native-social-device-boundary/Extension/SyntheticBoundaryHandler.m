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
    NSString *sharedGroup = input[@"sharedGroup"];
    NSString *hostOnlyGroup = input[@"hostOnlyGroup"];
    if (![hostFile isKindOfClass:NSString.class] ||
        ![keychainService isKindOfClass:NSString.class] ||
        ![sharedGroup isKindOfClass:NSString.class] ||
        ![hostOnlyGroup isKindOfClass:NSString.class]) {
        [context cancelRequestWithError:[NSError errorWithDomain:@"SyntheticBoundaryProbe" code:1 userInfo:nil]];
        return;
    }

    NSError *fileError = nil;
    NSData *hostData = [NSData dataWithContentsOfFile:hostFile options:0 error:&fileError];
    BOOL fileReadable = hostData != nil;

    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: keychainService,
        (__bridge id)kSecAttrAccount: @"synthetic-host-only",
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    } mutableCopy];
    if (sharedGroup.length > 0) {
        query[(__bridge id)kSecAttrAccessGroup] = sharedGroup;
    }
    CFTypeRef keychainValue = NULL;
    OSStatus keychainStatus = SecItemCopyMatching((__bridge CFDictionaryRef)query, &keychainValue);
    if (keychainValue != NULL) {
        CFRelease(keychainValue);
    }

    OSStatus hostOnlyStatus = errSecItemNotFound;
    BOOL extensionClaimsHostGroup = NO;
    if (hostOnlyGroup.length > 0) {
        NSMutableDictionary *hostOnlyQuery = [query mutableCopy];
        hostOnlyQuery[(__bridge id)kSecAttrAccount] = @"synthetic-host-explicit-group";
        hostOnlyQuery[(__bridge id)kSecAttrAccessGroup] = hostOnlyGroup;
        CFTypeRef hostOnlyValue = NULL;
        hostOnlyStatus = SecItemCopyMatching((__bridge CFDictionaryRef)hostOnlyQuery, &hostOnlyValue);
        if (hostOnlyValue != NULL) { CFRelease(hostOnlyValue); }

        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (task != NULL) {
            CFTypeRef groupsValue = SecTaskCopyValueForEntitlement(task, CFSTR("keychain-access-groups"), NULL);
            CFRelease(task);
            if (groupsValue != NULL) {
                id groups = CFBridgingRelease(groupsValue);
                extensionClaimsHostGroup = [groups isKindOfClass:NSArray.class] && [groups containsObject:hostOnlyGroup];
            }
        }
    }

    NSExtensionItem *result = [NSExtensionItem new];
    result.userInfo = @{
        @"fileReadable": @(fileReadable),
        @"fileErrorCode": @(fileError == nil ? 0 : fileError.code),
        @"keychainStatus": @(keychainStatus),
        @"hostOnlyStatus": @(hostOnlyStatus),
        @"extensionClaimsHostGroup": @(extensionClaimsHostGroup),
        @"extensionPID": @(getpid())
    };
    [context completeRequestReturningItems:@[result] completionHandler:nil];
}

@end
