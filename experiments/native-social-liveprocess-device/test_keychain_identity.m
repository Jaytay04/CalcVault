#import <Foundation/Foundation.h>

#import "CVLPKeychainIdentity.h"

int main(void) {
    @autoreleasepool {
        NSString *signedApplicationIdentifier = @"TESTTEAM01.com.jaylintaylor.calcvault.TESTTEAM01";
        NSString *rewrittenBundleIdentifier = @"com.jaylintaylor.calcvault.TESTTEAM01";
        CVLPApplicationIDGroupSelectionStatus applicationStatus = CVLPApplicationIDGroupSelectionStatusUnavailable;
        NSString *applicationIDControl = CVLPSelectApplicationIDControlGroup(signedApplicationIdentifier, &applicationStatus);
        NSCAssert(applicationStatus == CVLPApplicationIDGroupSelectionStatusSelected, @"signed application identifier should select the app-ID control");
        NSCAssert([applicationIDControl isEqualToString:signedApplicationIdentifier], @"the app-ID control must preserve the signed entitlement exactly");
        NSCAssert(![applicationIDControl isEqualToString:rewrittenBundleIdentifier], @"bundle identifier rewrites must not affect app-ID selection");

        CVLPHostOnlyGroupSelectionStatus hostStatus = CVLPHostOnlyGroupSelectionStatusMissingApplicationIdentifier;
        NSCAssert(CVLPSelectHostOnlyGroup(nil, signedApplicationIdentifier, &hostStatus) == nil, @"implicit app-ID membership does not imply an explicit host-only group");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusMissingExplicitGroups, @"missing explicit groups should be reported");
        NSCAssert(CVLPSelectApplicationIDControlGroup(signedApplicationIdentifier, NULL) != nil, @"the app-ID control must remain available without an explicit group array");

        NSCAssert(CVLPSelectApplicationIDControlGroup(nil, &applicationStatus) == nil, @"missing signed identity must not select a group");
        NSCAssert(applicationStatus == CVLPApplicationIDGroupSelectionStatusUnavailable, @"missing identity status should be unavailable");
        NSCAssert(CVLPSelectApplicationIDControlGroup(@"TeamOnly", &applicationStatus) == nil, @"malformed signed identity must not select a group");
        NSCAssert(applicationStatus == CVLPApplicationIDGroupSelectionStatusMalformed, @"malformed identity status should be reported");
        NSCAssert(CVLPSelectApplicationIDControlGroup(@".com.example.app", NULL) == nil, @"empty team prefix must be rejected");
        NSCAssert(CVLPSelectApplicationIDControlGroup(@"TEAM..com.example.app", NULL) == nil, @"empty identity components must be rejected");

        NSString *expectedHostOnly = @"TESTTEAM01.com.jaylintaylor.calcvault.hostonly";
        NSArray *validGroups = @[
            @"TESTTEAM01.com.jaylintaylor.calcvault",
            expectedHostOnly,
            @"TESTTEAM01.com.kdt.livecontainer.shared"
        ];
        NSString *hostOnlyGroup = CVLPSelectHostOnlyGroup(validGroups, signedApplicationIdentifier, &hostStatus);
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusSelected, @"an exact same-prefix host-only group should be selected");
        NSCAssert([hostOnlyGroup isEqualToString:expectedHostOnly], @"host-only selection must use the signed app-ID prefix");

        NSString *mixedCaseApplicationIdentifier = @"Team-Case.com.JaylinTaylor.CalcVault";
        NSString *mixedCaseExpectedHostOnly = @"Team-Case.com.jaylintaylor.calcvault.hostonly";
        NSCAssert([CVLPSelectApplicationIDControlGroup(mixedCaseApplicationIdentifier, NULL) isEqualToString:mixedCaseApplicationIdentifier],
                  @"the exact signed identity must retain its original case");
        NSCAssert([CVLPSelectHostOnlyGroup(@[mixedCaseExpectedHostOnly], mixedCaseApplicationIdentifier, &hostStatus)
                  isEqualToString:mixedCaseExpectedHostOnly], @"the team prefix case must be preserved for exact group selection");

        NSCAssert(CVLPSelectHostOnlyGroup(@[@"OTHER.com.jaylintaylor.calcvault.hostonly"], signedApplicationIdentifier, &hostStatus) == nil,
                  @"a matching suffix under another prefix must be rejected");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusWrongPrefix, @"wrong-prefix status should be reported");
        NSCAssert(CVLPSelectHostOnlyGroup(@[@"Team-Case.com.kdt.livecontainer.shared"], signedApplicationIdentifier, &hostStatus) == nil,
                  @"a shared group must never be used as a host-only fallback");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusNotEntitled, @"missing host-only entitlement should be reported");
        NSCAssert(CVLPSelectHostOnlyGroup(@[expectedHostOnly, expectedHostOnly], signedApplicationIdentifier, &hostStatus) == nil,
                  @"duplicate host-only groups must be rejected as ambiguous");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusAmbiguous, @"duplicate group status should be ambiguous");
        NSCAssert(CVLPSelectHostOnlyGroup(@[expectedHostOnly, @"OTHER.com.jaylintaylor.calcvault.hostonly"], signedApplicationIdentifier, &hostStatus) == nil,
                  @"multiple host-only candidates must be rejected as ambiguous");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusAmbiguous, @"multiple candidates should be ambiguous");
        NSCAssert(CVLPSelectHostOnlyGroup(@[@"Team-Case..com.jaylintaylor.calcvault.hostonly"], signedApplicationIdentifier, &hostStatus) == nil,
                  @"malformed group names must be rejected");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusMalformedExplicitGroups, @"malformed explicit groups should be reported");
        NSCAssert(CVLPSelectHostOnlyGroup(@[@42], signedApplicationIdentifier, &hostStatus) == nil,
                  @"non-string group entries must fail closed");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusMalformedExplicitGroups, @"non-string group entries should be reported");
        NSCAssert(CVLPSelectHostOnlyGroup(@"Team-Case.com.jaylintaylor.calcvault.hostonly", signedApplicationIdentifier, &hostStatus) == nil,
                  @"a non-array groups entitlement must be rejected");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusMalformedExplicitGroups, @"malformed entitlement type should be reported");
        NSCAssert(![validGroups containsObject:signedApplicationIdentifier], @"rewritten app ID is implicit, not explicitly listed");
        NSCAssert(CVLPSelectHostOnlyGroup(validGroups, nil, &hostStatus) == nil, @"missing signed identity must stop host-only selection");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusMissingApplicationIdentifier, @"missing signed identity status");
        NSCAssert(CVLPSelectHostOnlyGroup(validGroups, @"TEAM..invalid", &hostStatus) == nil, @"malformed signed identity must stop host-only selection");
        NSCAssert(hostStatus == CVLPHostOnlyGroupSelectionStatusMalformedApplicationIdentifier, @"malformed signed identity status");
    }
    return 0;
}
