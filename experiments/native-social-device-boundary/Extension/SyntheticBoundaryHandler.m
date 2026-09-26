#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <unistd.h>

@interface SyntheticBoundaryHandler : NSObject <NSExtensionRequestHandling>
@end

static OSStatus QuerySyntheticItem(NSString *service, NSString *account, NSString *group) {
    NSMutableDictionary *query = [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    } mutableCopy];
    if (group.length > 0) {
        query[(__bridge id)kSecAttrAccessGroup] = group;
    }
    CFTypeRef value = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &value);
    if (value != NULL) { CFRelease(value); }
    return status;
}

@implementation SyntheticBoundaryHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSDictionary *input = [context.inputItems.firstObject userInfo];
    NSString *hostFile = input[@"hostFile"];
    NSData *guestBookmark = input[@"guestBookmark"];
    NSString *keychainService = input[@"keychainService"];
    NSString *sharedGroup = input[@"sharedGroup"];
    NSString *hostOnlyGroup = input[@"hostOnlyGroup"];
    if (![hostFile isKindOfClass:NSString.class] ||
        ![guestBookmark isKindOfClass:NSData.class] ||
        ![keychainService isKindOfClass:NSString.class] ||
        ![sharedGroup isKindOfClass:NSString.class] ||
        ![hostOnlyGroup isKindOfClass:NSString.class]) {
        [context cancelRequestWithError:[NSError errorWithDomain:@"SyntheticBoundaryProbe" code:1 userInfo:nil]];
        return;
    }

    NSError *beforeError = nil;
    NSData *beforeData = [NSData dataWithContentsOfFile:hostFile options:0 error:&beforeError];
    OSStatus hostOnlyBefore = hostOnlyGroup.length > 0
        ? QuerySyntheticItem(keychainService, @"synthetic-host-explicit-group", hostOnlyGroup)
        : errSecItemNotFound;

    BOOL isStale = NO;
    NSError *bookmarkError = nil;
    NSURL *guestURL = [NSURL URLByResolvingBookmarkData:guestBookmark options:0 relativeToURL:nil
                              bookmarkDataIsStale:&isStale error:&bookmarkError];
    BOOL bookmarkResolved = guestURL != nil;
    BOOL bookmarkActive = bookmarkResolved && [guestURL startAccessingSecurityScopedResource];
    NSURL *guestMarkerURL = [guestURL URLByAppendingPathComponent:@"guest-marker.txt"];
    NSError *guestReadError = nil;
    NSData *guestData = bookmarkResolved
        ? [NSData dataWithContentsOfURL:guestMarkerURL options:0 error:&guestReadError] : nil;
    NSString *guestValue = guestData == nil ? nil : [[NSString alloc] initWithData:guestData encoding:NSUTF8StringEncoding];
    BOOL guestMarkerReadable = [guestValue isEqualToString:@"Synthetic guest bookmark fixture"];

    NSError *afterError = nil;
    NSData *afterData = [NSData dataWithContentsOfFile:hostFile options:0 error:&afterError];
    OSStatus sharedAfter = QuerySyntheticItem(keychainService, @"synthetic-host-only", sharedGroup);
    OSStatus hostOnlyAfter = hostOnlyGroup.length > 0
        ? QuerySyntheticItem(keychainService, @"synthetic-host-explicit-group", hostOnlyGroup)
        : errSecItemNotFound;
    NSData *mutation = [@"Synthetic extension write attempt" dataUsingEncoding:NSUTF8StringEncoding];
    BOOL hostWriteSucceeded = bookmarkActive && [mutation writeToFile:hostFile options:NSDataWritingAtomic error:nil];
    if (bookmarkActive) { [guestURL stopAccessingSecurityScopedResource]; }

    NSExtensionItem *result = [NSExtensionItem new];
    result.userInfo = @{
        @"bookmarkActive": @(bookmarkActive),
        @"bookmarkResolved": @(bookmarkResolved),
        @"bookmarkStale": @(isStale),
        @"bookmarkError": @(bookmarkError == nil ? 0 : bookmarkError.code),
        @"guestMarkerReadable": @(guestMarkerReadable),
        @"guestReadError": @(guestReadError == nil ? 0 : guestReadError.code),
        @"fileReadableBefore": @(beforeData != nil),
        @"fileErrorBefore": @(beforeError == nil ? 0 : beforeError.code),
        @"fileReadableAfter": @(afterData != nil),
        @"fileErrorAfter": @(afterError == nil ? 0 : afterError.code),
        @"fileWriteSucceeded": @(hostWriteSucceeded),
        @"sharedStatusAfter": @(sharedAfter),
        @"hostOnlyStatusBefore": @(hostOnlyBefore),
        @"hostOnlyStatusAfter": @(hostOnlyAfter),
        @"extensionPID": @(getpid())
    };
    [context completeRequestReturningItems:@[result] completionHandler:nil];
}

@end
