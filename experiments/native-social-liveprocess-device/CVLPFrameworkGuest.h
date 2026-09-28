#pragma once
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <sys/stat.h>
#import <unistd.h>

NS_ASSUME_NONNULL_BEGIN

// Selects only a fixed, host-bundled research guest from the reviewed ID allowlist.
// This is not signature validation, trust evaluation, or malware scanning; OS code-signature
// validation must remain enabled when the executable is loaded.
static inline BOOL CVLPGuestIsDirectory(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode);
}

static inline BOOL CVLPGuestPathIsAbsent(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) != 0 && errno == ENOENT;
}

static inline NSData * _Nullable CVLPGuestReadRegularFile(NSString *path, NSUInteger limit) {
    struct stat before, opened, after;
    if (lstat(path.fileSystemRepresentation, &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_size < 0 || (uint64_t)before.st_size > limit) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    NSData *result = nil;
    if (fstat(fd, &opened) == 0 && S_ISREG(opened.st_mode) && opened.st_dev == before.st_dev &&
        opened.st_ino == before.st_ino && opened.st_size >= 0 && (uint64_t)opened.st_size <= limit) {
        NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)opened.st_size];
        NSUInteger offset = 0;
        BOOL okay = YES;
        while (offset < bytes.length) {
            ssize_t count = read(fd, (uint8_t *)bytes.mutableBytes + offset, bytes.length - offset);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) { okay = NO; break; }
            offset += (NSUInteger)count;
        }
        uint8_t extra;
        ssize_t extraCount;
        do { extraCount = read(fd, &extra, 1); } while (extraCount < 0 && errno == EINTR);
        if (extraCount != 0 || fstat(fd, &after) != 0 || after.st_size != opened.st_size ||
            after.st_dev != opened.st_dev || after.st_ino != opened.st_ino) okay = NO;
        if (okay) result = [bytes copy];
    }
    close(fd);
    return result;
}

static inline BOOL CVLPGuestIsNonemptyRegularFile(NSString *path) {
    struct stat before, opened;
    if (lstat(path.fileSystemRepresentation, &before) != 0 || !S_ISREG(before.st_mode) || before.st_size <= 0)
        return NO;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    BOOL okay = fstat(fd, &opened) == 0 && S_ISREG(opened.st_mode) && opened.st_size > 0 &&
        opened.st_dev == before.st_dev && opened.st_ino == before.st_ino;
    close(fd);
    return okay;
}

static inline NSDictionary * _Nullable CVLPGuestPropertyList(NSString *path, NSUInteger limit) {
    NSData *data = CVLPGuestReadRegularFile(path, limit);
    if (!data) return nil;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
                                                           format:NULL error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static inline BOOL CVLPGuestHasKeys(NSDictionary *dictionary, NSArray<NSString *> *keys) {
    return dictionary.count == keys.count &&
        [[NSSet setWithArray:dictionary.allKeys] isEqualToSet:[NSSet setWithArray:keys]];
}

static inline NSURL * _Nullable CVLPFrameworkGuestURL(NSURL * _Nullable hostURL) {
    if (!hostURL.isFileURL || hostURL.path.length == 0) return nil;

    // Resolve the host bundle first so the normal /var -> /private/var alias is accepted.
    NSString *hostPath = [[hostURL.path stringByStandardizingPath] stringByResolvingSymlinksInPath];
    if (!hostPath.isAbsolutePath || !CVLPGuestIsDirectory(hostPath)) return nil;
    if (!CVLPGuestPathIsAbsent([hostPath stringByAppendingPathComponent:@"ALTCertificate.p12"]) ||
        !CVLPGuestPathIsAbsent([hostPath stringByAppendingPathComponent:@"ALTCertificate.pfx"])) return nil;

    NSString *frameworksPath = [hostPath stringByAppendingPathComponent:@"Frameworks"];
    NSString *guestPath = [frameworksPath stringByAppendingPathComponent:@"NativeGuest.framework"];
    if (!CVLPGuestIsDirectory(frameworksPath) || !CVLPGuestIsDirectory(guestPath)) return nil;
    NSString *descriptorPath = [hostPath stringByAppendingPathComponent:@"CVLPFrameworkGuest.plist"];
    NSDictionary *descriptor = CVLPGuestPropertyList(descriptorPath, 64 * 1024);
    NSArray *keys = @[@"schema", @"bundleIdentifier", @"bundleVersion", @"executable"];
    if (!descriptor || !CVLPGuestHasKeys(descriptor, keys)) return nil;

    id schema = descriptor[@"schema"];
    if (![schema isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)schema) != CFNumberGetTypeID() ||
        CFNumberIsFloatType((__bridge CFNumberRef)schema) || [schema longLongValue] != 1) return nil;
    NSString *bundleID = descriptor[@"bundleIdentifier"];
    NSString *version = descriptor[@"bundleVersion"];
    NSString *executable = descriptor[@"executable"];
    NSSet *allowedIDs = [NSSet setWithObjects:@"org.example.syntheticnativeguest.app", @"com.zhiliaoapp.musically", nil];
    if (![bundleID isKindOfClass:NSString.class] || ![allowedIDs containsObject:bundleID] ||
        ![version isKindOfClass:NSString.class] || version.length == 0 || version.length > 64 ||
        ![executable isKindOfClass:NSString.class] || ![executable isEqualToString:@"NativeGuest"]) return nil;

    NSString *infoPath = [guestPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = CVLPGuestPropertyList(infoPath, 1024 * 1024);
    if (![info[@"CFBundleIdentifier"] isEqual:bundleID] || ![info[@"CFBundleVersion"] isEqual:version] ||
        ![info[@"CFBundleExecutable"] isEqual:executable] || ![info[@"CFBundlePackageType"] isEqual:@"FMWK"])
        return nil;
    if (!CVLPGuestPathIsAbsent([guestPath stringByAppendingPathComponent:@"LCAppInfo.plist"]) ||
        !CVLPGuestIsNonemptyRegularFile([guestPath stringByAppendingPathComponent:executable])) return nil;
    return [NSURL fileURLWithPath:guestPath isDirectory:YES];
}

NS_ASSUME_NONNULL_END
