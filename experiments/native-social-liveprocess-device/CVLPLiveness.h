#ifndef CVLP_LIVENESS_H
#define CVLP_LIVENESS_H

#include <errno.h>
#include <sys/types.h>
#include <signal.h>
#include <unistd.h>

typedef enum {
    CVLPLivenessAbsentPID = 0,
    CVLPLivenessSuccess,
    CVLPLivenessEPERM,
    CVLPLivenessESRCH,
    CVLPLivenessOther
} CVLPLivenessClassification;

typedef struct {
    pid_t pid;
    int attempted;
    int result;
    int errorNumber;
    CVLPLivenessClassification classification;
    pid_t groupResult;
    int groupErrorNumber;
    CVLPLivenessClassification groupClassification;
} CVLPLivenessSample;

static inline CVLPLivenessClassification
CVLPLivenessClassify(pid_t pid, int result, int errorNumber) {
    if (pid <= 0) return CVLPLivenessAbsentPID;
    if (result == 0) return CVLPLivenessSuccess;
    if (result == -1 && errorNumber == EPERM) return CVLPLivenessEPERM;
    if (result == -1 && errorNumber == ESRCH) return CVLPLivenessESRCH;
    return CVLPLivenessOther;
}

static inline CVLPLivenessClassification
CVLPProcessGroupClassify(pid_t pid, pid_t result, int errorNumber) {
    if (pid <= 0) return CVLPLivenessAbsentPID;
    // The bounded guest fixture accepts only a positive group ID, matching the
    // pinned host's running check; a zero result remains inconclusive here.
    if (result > 0) return CVLPLivenessSuccess;
    if (result == 0) return CVLPLivenessOther;
    return CVLPLivenessClassify(pid, (int)result, errorNumber);
}

static inline const char *CVLPLivenessClassificationName(CVLPLivenessClassification value) {
    switch (value) {
        case CVLPLivenessAbsentPID: return "absentPID";
        case CVLPLivenessSuccess: return "success";
        case CVLPLivenessEPERM: return "EPERM";
        case CVLPLivenessESRCH: return "ESRCH";
        case CVLPLivenessOther: return "other";
    }
    return "other";
}

static inline CVLPLivenessSample CVLPSampleLiveness(pid_t pid) {
    CVLPLivenessSample sample = { pid, 0, 0, 0, CVLPLivenessAbsentPID,
                                 0, 0, CVLPLivenessAbsentPID };
    if (pid <= 0) return sample;
    sample.attempted = 1;
    int result = kill(pid, 0);
    if (result == -1) {
        int savedError = errno;
        sample.result = result;
        sample.errorNumber = savedError;
    } else {
        sample.result = result;
        sample.errorNumber = 0;
    }
    sample.classification = CVLPLivenessClassify(pid, sample.result, sample.errorNumber);
    pid_t groupResult = getpgid(pid);
    int groupError = groupResult == -1 ? errno : 0;
    sample.groupResult = groupResult;
    sample.groupErrorNumber = groupError;
    sample.groupClassification = CVLPProcessGroupClassify(pid, groupResult, groupError);
    return sample;
}

// A successful read-only lookup establishes PID presence, not execution or identity
// against PID reuse. Signal permission denial alone never establishes presence.
static inline int CVLPProcessPresenceObserved(CVLPLivenessSample sample) {
    return sample.pid > 0 && sample.attempted &&
        sample.groupClassification == CVLPLivenessSuccess &&
        (sample.classification == CVLPLivenessSuccess || sample.classification == CVLPLivenessEPERM);
}

static inline int CVLPProcessAbsenceObserved(CVLPLivenessSample sample) {
    return sample.pid > 0 && sample.attempted &&
        sample.classification == CVLPLivenessESRCH &&
        sample.groupClassification == CVLPLivenessESRCH;
}

static inline int CVLPProcessGroupShutdownObserved(int revoked, int beginCompleted,
    CVLPLivenessSample before, CVLPLivenessSample after) {
    return revoked && beginCompleted && CVLPProcessPresenceObserved(before) &&
        before.pid == after.pid && CVLPProcessAbsenceObserved(after);
}

#endif
