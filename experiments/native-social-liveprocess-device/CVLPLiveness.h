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
} CVLPLivenessSample;

static inline CVLPLivenessClassification
CVLPLivenessClassify(pid_t pid, int result, int errorNumber) {
    if (pid <= 0) return CVLPLivenessAbsentPID;
    if (result == 0) return CVLPLivenessSuccess;
    if (result == -1 && errorNumber == EPERM) return CVLPLivenessEPERM;
    if (result == -1 && errorNumber == ESRCH) return CVLPLivenessESRCH;
    return CVLPLivenessOther;
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
    CVLPLivenessSample sample = { pid, 0, 0, 0, CVLPLivenessAbsentPID };
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
    return sample;
}

#endif
