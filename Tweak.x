// WatusiJetsamUncap v1.2.0
// Made by 551
//
// Raises WhatsApp's notification ServiceExtension custom Jetsam memory limit
// to 512 MiB. This deliberately uses the same runningboardd ->
// memorystatus_control interception point as known working WhatsApp Jetsam
// fixes, but uses a high ceiling instead of -1/default-limit semantics.
//
// Global iOS memory-pressure Jetsam remains untouched.

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <os/log.h>
#import <dispatch/dispatch.h>

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <mach-o/dyld.h>

#define PROC_PIDPATHINFO_MAXSIZE 4096
#define WJU_TARGET_MIB 512

#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK 5
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT      6
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES    7
#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES    8

typedef struct memorystatus_memlimit_properties {
    int32_t  memlimit_active;
    uint32_t memlimit_active_attr;
    int32_t  memlimit_inactive;
    uint32_t memlimit_inactive_attr;
} memorystatus_memlimit_properties_t;

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
extern int memorystatus_control(uint32_t command,
                                int32_t pid,
                                uint32_t flags,
                                void *buffer,
                                size_t buffersize);

static int (*orig_memorystatus_control)(uint32_t command,
                                        int32_t pid,
                                        uint32_t flags,
                                        void *buffer,
                                        size_t buffersize);

static os_log_t wju_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.551.watusijetsamuncap", "jetsam");
    });
    return log;
}

static const char *basename_ptr(const char *path) {
    if (!path) return NULL;
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static bool is_service_extension_path(const char *path) {
    if (!path) return false;

    const char *base = basename_ptr(path);
    if (!base || strcmp(base, "ServiceExtension") != 0) return false;
    if (!strstr(path, "/ServiceExtension.appex/ServiceExtension")) return false;

    if (strstr(path, "/WhatsApp.app/") ||
        strstr(path, "/WhatsApp Business.app/") ||
        strstr(path, "/Watusi.app/")) {
        return true;
    }

    if (strstr(path, ".app/") &&
        (strstr(path, "/WhatsApp") || strstr(path, "/Watusi"))) {
        return true;
    }

    return false;
}

static bool get_service_extension_path(int32_t pid,
                                       char path[PROC_PIDPATHINFO_MAXSIZE]) {
    if (pid < 2) return false;

    memset(path, 0, PROC_PIDPATHINFO_MAXSIZE);
    int n = proc_pidpath(pid, path, PROC_PIDPATHINFO_MAXSIZE);
    if (n <= 0) return false;

    return is_service_extension_path(path);
}

static void log_effective_limit(int32_t pid, const char *path) {
    memorystatus_memlimit_properties_t verify = {0};
    int rv = orig_memorystatus_control(MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,
                                       pid,
                                       0,
                                       &verify,
                                       sizeof(verify));

    if (rv == 0) {
        os_log(wju_log(),
               "VERIFY %{public}s pid=%d effective active=%d inactive=%d activeAttr=0x%x inactiveAttr=0x%x",
               path, pid,
               verify.memlimit_active,
               verify.memlimit_inactive,
               verify.memlimit_active_attr,
               verify.memlimit_inactive_attr);
    } else {
        os_log_error(wju_log(),
                     "VERIFY FAILED %{public}s pid=%d rv=%d",
                     path, pid, rv);
    }
}

static int hooked_memorystatus_control(uint32_t command,
                                       int32_t pid,
                                       uint32_t flags,
                                       void *buffer,
                                       size_t buffersize) {
    bool isLimitCommand =
        command == MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES ||
        command == MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK ||
        command == MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT;

    if (!isLimitCommand) {
        return orig_memorystatus_control(command, pid, flags, buffer, buffersize);
    }

    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (!get_service_extension_path(pid, path)) {
        return orig_memorystatus_control(command, pid, flags, buffer, buffersize);
    }

    if (command == MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES) {
        if (buffer == NULL || buffersize != sizeof(memorystatus_memlimit_properties_t)) {
            os_log_error(wju_log(),
                         "UNEXPECTED cmd=7 layout %{public}s pid=%d size=%lu; passing through",
                         path, pid, (unsigned long)buffersize);
            return orig_memorystatus_control(command, pid, flags, buffer, buffersize);
        }

        memorystatus_memlimit_properties_t original =
            *(memorystatus_memlimit_properties_t *)buffer;
        memorystatus_memlimit_properties_t local = original;

        if (local.memlimit_active > 0 && local.memlimit_active < WJU_TARGET_MIB) {
            local.memlimit_active = WJU_TARGET_MIB;
        }
        if (local.memlimit_inactive > 0 && local.memlimit_inactive < WJU_TARGET_MIB) {
            local.memlimit_inactive = WJU_TARGET_MIB;
        }

        int rv = orig_memorystatus_control(command, pid, flags,
                                           &local, sizeof(local));

        os_log(wju_log(),
               "SET %{public}s pid=%d cmd=7 requested active=%d inactive=%d -> active=%d inactive=%d rv=%d",
               path, pid,
               original.memlimit_active,
               original.memlimit_inactive,
               local.memlimit_active,
               local.memlimit_inactive,
               rv);

        if (rv == 0) log_effective_limit(pid, path);
        return rv;
    }

    int32_t requested = (int32_t)flags;
    uint32_t replacement = flags;
    if (requested > 0 && requested < WJU_TARGET_MIB) {
        replacement = (uint32_t)WJU_TARGET_MIB;
    }

    int rv = orig_memorystatus_control(command, pid, replacement,
                                       buffer, buffersize);

    os_log(wju_log(),
           "SET %{public}s pid=%d cmd=%u requested=%d -> %d rv=%d",
           path, pid, command, requested, (int32_t)replacement, rv);

    if (rv == 0) log_effective_limit(pid, path);
    return rv;
}

static bool running_inside_runningboardd(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    uint32_t size = (uint32_t)sizeof(path);

    if (_NSGetExecutablePath(path, &size) != 0) return false;
    const char *base = basename_ptr(path);
    return base && strcmp(base, "runningboardd") == 0;
}

%ctor {
    @autoreleasepool {
        if (!running_inside_runningboardd()) return;

        MSHookFunction((void *)memorystatus_control,
                       (void *)hooked_memorystatus_control,
                       (void **)&orig_memorystatus_control);

        os_log(wju_log(),
               "WatusiJetsamUncap v1.2.0 loaded in runningboardd; ServiceExtension target=%d MiB",
               WJU_TARGET_MIB);
    }
}
