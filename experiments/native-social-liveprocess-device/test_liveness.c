#include "CVLPLiveness.h"

#include <assert.h>
#include <stdio.h>
#include <sys/wait.h>

static CVLPLivenessSample syntheticSample(pid_t pid, int result, int error,
    pid_t groupResult, int groupError) {
    CVLPLivenessSample sample = { pid, pid > 0, result, result == -1 ? error : 0,
        CVLPLivenessClassify(pid, result, error), groupResult,
        groupResult == -1 ? groupError : 0, CVLPProcessGroupClassify(pid, groupResult, groupError) };
    return sample;
}

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
    assert(absent.groupClassification == CVLPLivenessAbsentPID);

    CVLPLivenessSample negative = CVLPSampleLiveness((pid_t)-1);
    assert(negative.attempted == 0 && negative.classification == CVLPLivenessAbsentPID);
    assert(negative.groupClassification == CVLPLivenessAbsentPID);

    errno = EPERM;
    CVLPLivenessSample current = CVLPSampleLiveness(getpid());
    assert(current.attempted == 1 && current.result == 0);
    assert(current.errorNumber == 0 && current.classification == CVLPLivenessSuccess);
    assert(current.groupResult > 0 && current.groupErrorNumber == 0);
    assert(current.groupClassification == CVLPLivenessSuccess);

    assert(CVLPProcessGroupClassify(42, 0, EPERM) == CVLPLivenessOther);
    assert(CVLPProcessGroupClassify(42, 7, ESRCH) == CVLPLivenessSuccess);
    assert(CVLPProcessGroupClassify(42, -1, EPERM) == CVLPLivenessEPERM);
    assert(CVLPProcessGroupClassify(42, -1, ESRCH) == CVLPLivenessESRCH);
    assert(CVLPProcessGroupClassify(42, -1, EINVAL) == CVLPLivenessOther);

    CVLPLivenessSample before = syntheticSample(42, -1, EPERM, 7, 0);
    CVLPLivenessSample after = syntheticSample(42, -1, ESRCH, -1, ESRCH);
    assert(CVLPProcessPresenceObserved(before));
    assert(CVLPProcessGroupShutdownObserved(1, 1, before, after));
    assert(!CVLPProcessGroupShutdownObserved(0, 1, before, after));
    assert(!CVLPProcessGroupShutdownObserved(1, 0, before, after));
    assert(!CVLPProcessGroupShutdownObserved(1, 1, before, before));
    assert(!CVLPProcessGroupShutdownObserved(1, 1, after, after));
    assert(!CVLPProcessGroupShutdownObserved(1, 1, absent, after));
    assert(!CVLPProcessPresenceObserved(syntheticSample(42, -1, EPERM, -1, EPERM)));
    assert(!CVLPProcessPresenceObserved(syntheticSample(42, -1, ESRCH, 7, 0)));
    assert(!CVLPProcessPresenceObserved(syntheticSample(42, -1, EINVAL, 7, 0)));
    assert(!CVLPProcessPresenceObserved(syntheticSample(42, -1, EPERM, 0, 0)));
    assert(!CVLPProcessAbsenceObserved(syntheticSample(42, -1, ESRCH, 7, 0)));
    assert(!CVLPProcessAbsenceObserved(syntheticSample(42, -1, EPERM, -1, ESRCH)));
    assert(!CVLPProcessGroupShutdownObserved(1, 1, before,
        syntheticSample(43, -1, ESRCH, -1, ESRCH)));

    // macOS test-only child remains alive until its parent closes the pipe.
    // No arbitrary process is signaled, and no child process is used on iOS.
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        close(descriptors[1]);
        char byte;
        while (read(descriptors[0], &byte, 1) < 0 && errno == EINTR) {}
        close(descriptors[0]);
        _exit(0);
    }
    close(descriptors[0]);
    CVLPLivenessSample childBefore = CVLPSampleLiveness(child);
    close(descriptors[1]);
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited == -1 && errno == EINTR);
    assert(waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    CVLPLivenessSample childAfter = CVLPSampleLiveness(child);
    assert(CVLPProcessGroupShutdownObserved(1, 1, childBefore, childAfter));

    puts("liveness diagnostics and process-group shutdown tests passed");
    return 0;
}
