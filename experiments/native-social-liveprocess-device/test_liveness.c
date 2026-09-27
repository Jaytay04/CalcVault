#include "CVLPLiveness.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    /* A success must ignore stale errno left by an earlier syscall. */
    assert(CVLPLivenessClassify((pid_t)42, 0, EPERM) == CVLPLivenessSuccess);
    assert(CVLPLivenessClassify((pid_t)42, 0, ESRCH) == CVLPLivenessSuccess);

    assert(CVLPLivenessClassify((pid_t)0, 0, 0) == CVLPLivenessAbsentPID);
    assert(CVLPLivenessClassify((pid_t)-1, 0, 0) == CVLPLivenessAbsentPID);
    assert(CVLPLivenessClassify((pid_t)42, -1, EPERM) == CVLPLivenessEPERM);
    assert(CVLPLivenessClassify((pid_t)42, -1, ESRCH) == CVLPLivenessESRCH);
    assert(CVLPLivenessClassify((pid_t)42, -1, EINVAL) == CVLPLivenessOther);

    CVLPLivenessSample absent = CVLPSampleLiveness((pid_t)0);
    assert(absent.pid == 0 && absent.attempted == 0);
    assert(absent.classification == CVLPLivenessAbsentPID);

    CVLPLivenessSample negative = CVLPSampleLiveness((pid_t)-1);
    assert(negative.attempted == 0 && negative.classification == CVLPLivenessAbsentPID);

    errno = EPERM;
    CVLPLivenessSample current = CVLPSampleLiveness(getpid());
    assert(current.attempted == 1 && current.result == 0);
    assert(current.errorNumber == 0 && current.classification == CVLPLivenessSuccess);

    puts("liveness diagnostics tests passed");
    return 0;
}
