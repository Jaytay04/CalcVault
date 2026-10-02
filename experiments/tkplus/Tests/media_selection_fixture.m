#import <Foundation/Foundation.h>
#import "../Guest/TKPMediaSelection.h"
#include <stdio.h>

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "check failed at line %d\n", __LINE__); return 1; \
} } while (0)

int main(void) {
    @autoreleasepool {
        NSSet *hosts = [NSSet setWithObject:@"cdn.media.example"];
        NSError *error = nil;
        NSString *original = @"https://cdn.media.example/original.mp4?synthetic=1";
        TKPSelectedMedia *selected = TKPSelectOriginalMedia(@[original], TKPSelectedMediaMP4, hosts, &error);
        CHECK(selected != nil && error == nil);
        CHECK([selected.originalURL.absoluteString isEqualToString:original]);
        CHECK(selected.kind == TKPSelectedMediaMP4);
        NSArray *blocked = @[@"http://cdn.media.example/a.mp4", @"file:///tmp/a.mp4",
                             @"https://user:pass@cdn.media.example/a.mp4",
                             @"https://@cdn.media.example/a.mp4",
                             @"https://cdn.media.example/a.mp4#fragment",
                             @"https://cdn.media.example:444/a.mp4",
                             @"https://cdn.media.example.attacker.example/a.mp4",
                             @"https://localhost/a.mp4", @"https://127.0.0.1/a.mp4"];
        for (NSString *URL in blocked) {
            CHECK(TKPSelectOriginalMedia(@[URL], TKPSelectedMediaMP4, hosts, &error) == nil);
            CHECK(error.code == TKPMediaSelectionNoApprovedOriginal);
            CHECK(error.userInfo.count == 0);
        }
        selected = TKPSelectOriginalMedia(@[@"https://other.example/a.mp4", original],
                                         TKPSelectedMediaMP4, hosts, &error);
        CHECK(selected != nil && [selected.originalURL.absoluteString isEqualToString:original]);
        NSArray *malformed = @[original, @42];
        CHECK(TKPSelectOriginalMedia(malformed, TKPSelectedMediaMP4, hosts, &error) == nil);
        CHECK(error.code == TKPMediaSelectionInvalidInput);
        for (NSString *invalid in @[@"https://cdn.media.example/a b.mp4",
                                    @"https://cdn.media.example/a\n.mp4",
                                    @"https://cdn.media.example/a\t.mp4",
                                    @"https://cdn.media.example/a\001.mp4", @""]) {
            CHECK(TKPSelectOriginalMedia(@[invalid], TKPSelectedMediaMP4, hosts, &error) == nil);
            CHECK(error.code == TKPMediaSelectionInvalidInput && error.userInfo.count == 0);
        }
        NSString *oversized = [original stringByPaddingToLength:8193 withString:@"x" startingAtIndex:0];
        CHECK(TKPSelectOriginalMedia(@[oversized], TKPSelectedMediaMP4, hosts, &error) == nil);
        CHECK(error.code == TKPMediaSelectionInvalidInput);
        CHECK(TKPSelectOriginalMedia(@[original], TKPSelectedMediaJPEG, hosts, &error).kind == TKPSelectedMediaJPEG);
        CHECK(TKPSelectOriginalMedia(@[original], TKPSelectedMediaPNG, hosts, &error).kind == TKPSelectedMediaPNG);
        CHECK(TKPSelectOriginalMedia(@[], TKPSelectedMediaMP4, hosts, &error) == nil);
        CHECK(TKPSelectOriginalMedia(@[original], 255, hosts, &error) == nil);
        CHECK(error.code == TKPMediaSelectionUnsupportedKind);
        CHECK(TKPSelectOriginalMedia(@[original], TKPSelectedMediaMP4, [NSSet set], &error) == nil);
        CHECK(error.code == TKPMediaSelectionInvalidHostPolicy);
        CHECK(TKPSelectOriginalMedia(@[original], TKPSelectedMediaMP4,
                                    [NSSet setWithObject:@"CDN.MEDIA.EXAMPLE"], &error) == nil);
        CHECK(TKPSelectOriginalMedia(@[original], TKPSelectedMediaMP4,
                                    [NSSet setWithObject:@"127.0.0.1"], &error) == nil);
        CHECK(TKPSelectOriginalMedia(@[original], TKPSelectedMediaMP4,
                                    [NSSet setWithObject:@"cdn.media.local"], &error) == nil);
        CHECK(TKPSelectOriginalMedia(@[original], TKPSelectedMediaMP4,
                                    [NSSet setWithObject:@"-cdn.media.example"], &error) == nil);
        CHECK(TKPSelectOriginalMedia(@[original], TKPSelectedMediaMP4, hosts, NULL) != nil);
        NSMutableArray *large = [NSMutableArray array];
        for (NSUInteger i = 0; i < 33; i++) [large addObject:original];
        CHECK(TKPSelectOriginalMedia(large, TKPSelectedMediaMP4, hosts, &error) == nil);
        puts("PASS: media selection synthetic checks");
    }
    return 0;
}
