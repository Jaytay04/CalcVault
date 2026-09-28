#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <sysexits.h>
#import <unistd.h>
#import "CVLPFrameworkGuest.h"

static void WriteData(NSData *data, NSString *path) {
    NSError *error = nil;
    if (![data writeToFile:path options:0 error:&error]) {
        fprintf(stderr, "fixture write failed: %s\n", error.localizedDescription.UTF8String);
        exit(EX_IOERR);
    }
}

static void WritePlist(NSDictionary *value, NSString *path) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListXMLFormat_v1_0
                                                              options:0 error:&error];
    if (!data) {
        fprintf(stderr, "fixture plist failed: %s\n", error.localizedDescription.UTF8String);
        exit(EX_DATAERR);
    }
    WriteData(data, path);
}

static void WriteInfo(NSString *guest, NSString *bundleID, NSString *version, NSString *executable) {
    WritePlist(@{@"CFBundleIdentifier": bundleID, @"CFBundleVersion": version,
                 @"CFBundleExecutable": executable, @"CFBundlePackageType": @"FMWK"},
               [guest stringByAppendingPathComponent:@"Info.plist"]);
}

static void WriteIdentity(NSString *host, NSString *guest, NSString *bundleID, NSString *version) {
    WritePlist(@{@"schema": @1, @"bundleIdentifier": bundleID,
                 @"bundleVersion": version, @"executable": @"NativeGuest"},
               [host stringByAppendingPathComponent:@"CVLPFrameworkGuest.plist"]);
    WriteInfo(guest, bundleID, version, @"NativeGuest");
}

static void ReplaceWithSymlink(NSString *path, NSString *target) {
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    WriteData([@"external synthetic target" dataUsingEncoding:NSUTF8StringEncoding], target);
    if (symlink(target.fileSystemRepresentation, path.fileSystemRepresentation) != 0) exit(EX_IOERR);
}

static NSURL *MakeFixture(NSString *root, NSString *name) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *host = [[root stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"Host.app"];
    NSString *frameworks = [host stringByAppendingPathComponent:@"Frameworks"];
    NSString *guest = [frameworks stringByAppendingPathComponent:@"NativeGuest.framework"];
    [fm createDirectoryAtPath:guest withIntermediateDirectories:YES attributes:nil error:NULL];
    WriteIdentity(host, guest, @"org.example.syntheticnativeguest.app", @"1.0");
    WriteData([@"synthetic placeholder; never executed" dataUsingEncoding:NSUTF8StringEncoding],
              [guest stringByAppendingPathComponent:@"NativeGuest"]);
    return [NSURL fileURLWithPath:host isDirectory:YES];
}

static BOOL RunCase(NSString *root, NSString *name) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *hostURL = MakeFixture(root, name);
    NSString *host = hostURL.path;
    NSString *frameworks = [host stringByAppendingPathComponent:@"Frameworks"];
    NSString *guest = [frameworks stringByAppendingPathComponent:@"NativeGuest.framework"];
    NSString *descriptor = [host stringByAppendingPathComponent:@"CVLPFrameworkGuest.plist"];
    BOOL expected = [name isEqualToString:@"good"] || [name isEqualToString:@"host alias"] ||
        [name isEqualToString:@"TikTok matched contract"];
    if ([name isEqualToString:@"missing descriptor"])
        [fm removeItemAtPath:descriptor error:NULL];
    else if ([name isEqualToString:@"malformed"])
        WriteData([@"{" dataUsingEncoding:NSUTF8StringEncoding], descriptor);
    else if ([name isEqualToString:@"unknown key"])
        WritePlist(@{@"schema": @1, @"bundleIdentifier": @"org.example.syntheticnativeguest.app",
                     @"bundleVersion": @"1.0", @"executable": @"NativeGuest", @"extra": @YES}, descriptor);
    else if ([name isEqualToString:@"boolean schema"])
        WritePlist(@{@"schema": @YES, @"bundleIdentifier": @"org.example.syntheticnativeguest.app",
                     @"bundleVersion": @"1.0", @"executable": @"NativeGuest"}, descriptor);
    else if ([name isEqualToString:@"oversized descriptor"])
        WritePlist(@{@"schema": @1, @"bundleIdentifier": @"org.example.syntheticnativeguest.app",
                     @"bundleVersion": [@"v" stringByPaddingToLength:65536 withString:@"v" startingAtIndex:0],
                     @"executable": @"NativeGuest"}, descriptor);
    else if ([name isEqualToString:@"unknown ID"])
        WriteIdentity(host, guest, @"org.example.unreviewed.app", @"1.0");
    else if ([name isEqualToString:@"version mismatch"])
        WriteInfo(guest, @"org.example.syntheticnativeguest.app", @"2.0", @"NativeGuest");
    else if ([name isEqualToString:@"wrong executable"])
        WritePlist(@{@"schema": @1, @"bundleIdentifier": @"org.example.syntheticnativeguest.app",
                     @"bundleVersion": @"1.0", @"executable": @"Other"}, descriptor);
    else if ([name isEqualToString:@"TikTok matched contract"])
        WriteIdentity(host, guest, @"com.zhiliaoapp.musically", @"1.0");
    else if ([name isEqualToString:@"wrong metadata"])
        WriteInfo(guest, @"com.zhiliaoapp.musically", @"1.0", @"NativeGuest");
    else if ([name isEqualToString:@"empty code"])
        WriteData([NSData data], [guest stringByAppendingPathComponent:@"NativeGuest"]);
    else if ([name isEqualToString:@"missing code"])
        [fm removeItemAtPath:[guest stringByAppendingPathComponent:@"NativeGuest"] error:NULL];
    else if ([name isEqualToString:@"framework metadata present"])
        WriteData([NSData data], [guest stringByAppendingPathComponent:@"LCAppInfo.plist"]);
    else if ([name isEqualToString:@"descriptor symlink"] || [name isEqualToString:@"Info symlink"] ||
             [name isEqualToString:@"code symlink"]) {
        NSString *path = [name isEqualToString:@"descriptor symlink"] ? descriptor :
            ([name isEqualToString:@"Info symlink"] ? [guest stringByAppendingPathComponent:@"Info.plist"] :
             [guest stringByAppendingPathComponent:@"NativeGuest"]);
        ReplaceWithSymlink(path, [[host stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"ExternalFile"]);
    }
    else if ([name isEqualToString:@"p12 present"] || [name isEqualToString:@"pfx present"])
        WriteData([NSData data], [host stringByAppendingPathComponent:
                  [name isEqualToString:@"p12 present"] ? @"ALTCertificate.p12" : @"ALTCertificate.pfx"]);
    else if ([name isEqualToString:@"Frameworks symlink"] || [name isEqualToString:@"framework symlink"]) {
        NSString *target = [[host stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"External"];
        [fm removeItemAtPath:frameworks error:NULL];
        [fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:NULL];
        if ([name isEqualToString:@"Frameworks symlink"]) {
            if (symlink(target.fileSystemRepresentation, frameworks.fileSystemRepresentation) != 0) exit(EX_IOERR);
        } else {
            [fm createDirectoryAtPath:frameworks withIntermediateDirectories:YES attributes:nil error:NULL];
            if (symlink(target.fileSystemRepresentation,
                        [[frameworks stringByAppendingPathComponent:@"NativeGuest.framework"] fileSystemRepresentation]) != 0)
                exit(EX_IOERR);
        }
    } else if ([name isEqualToString:@"host alias"]) {
        NSString *alias = [[host stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"HostAlias.app"];
        if (symlink(host.fileSystemRepresentation, alias.fileSystemRepresentation) != 0) exit(EX_IOERR);
        hostURL = [NSURL fileURLWithPath:alias isDirectory:YES];
    }

    NSURL *selected = CVLPFrameworkGuestURL(hostURL);
    return expected ? [selected.path isEqualToString:[guest stringByResolvingSymlinksInPath]] : selected == nil;
}

int main(void) {
    @autoreleasepool {
        char temporary[] = "/tmp/cvlp-framework-guest-XXXXXX";
        char *root = mkdtemp(temporary);
        if (!root) return EX_CANTCREAT;
        NSArray *cases = @[@"good", @"missing descriptor", @"malformed", @"unknown key", @"boolean schema",
                           @"oversized descriptor", @"unknown ID", @"version mismatch", @"wrong executable",
                           @"wrong metadata", @"TikTok matched contract", @"empty code", @"missing code",
                           @"descriptor symlink", @"Info symlink", @"code symlink", @"Frameworks symlink",
                           @"framework symlink", @"p12 present", @"pfx present", @"framework metadata present",
                           @"host alias"];
        NSUInteger failures = 0;
        for (NSString *name in cases) {
            BOOL passed = RunCase([NSString stringWithUTF8String:root], name);
            printf("%s %s\n", passed ? "PASS" : "FAIL", name.UTF8String);
            if (!passed) failures++;
        }
        [NSFileManager.defaultManager removeItemAtPath:[NSString stringWithUTF8String:root] error:NULL];
        return failures ? EX_SOFTWARE : EX_OK;
    }
}
