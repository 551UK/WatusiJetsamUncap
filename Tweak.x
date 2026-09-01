// WatusiJetsamUncap
// Made by 551
//
// Removes WhatsApp/Watusi's custom per-process Jetsam memory ceilings by
// rewriting RunningBoard's memlimit assignments to <= 0. On iOS/XNU this
// means: no custom high-water mark / per-task limit; use the normal system-wide
// task memory limit instead. Global system memory-pressure Jetsam still works.
//
// The primary reason for this tweak is WhatsApp's ServiceExtension. Watusi can
// increase that extension's footprint enough for the stock extension-specific
// cap to terminate it, causing delayed/missing incoming messages until the
// extension is launched again.

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <os/log.h>
#import <dispatch/dispatch.h>

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <mach-o/dyld.h>

#define PROC_PIDPATHINFO_MAXSIZE 4096

// XNU memorystatus_control commands used to set per-process memory ceilings.
#define MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK 5
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT      6
#define MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES    7
#define MEMORYSTATUS_MEMLIMIT_ATTR_FATAL            0x1

// iOS 16 structure used with MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES.
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

static bool range_contains(const char *start, size_t length, const char *needle) {
    if (!start || !needle) return false;
    size_t nlen = strlen(needle);
    if (nlen == 0 || nlen > length) return false;

    for (size_t i = 0; i + nlen <= length; i++) {
        if (memcmp(start + i, needle, nlen) == 0) return true;
    }
    return false;
}

static bool path_is_whatsapp_or_watusi_bundle(const char *path) {
    if (!path || !strstr(path, ".app/")) return false;

    // Standard WhatsApp / Watusi-on-App-Store-WhatsApp installation.
    if (strstr(path, "/WhatsApp.app/")) return true;

    // WhatsApp Business and common duplicate/renamed Watusi bundles.
    if (strstr(path, "/WhatsApp Business.app/")) return true;
    if (strstr(path, "/Watusi.app/")) return true;

    // Tolerate duplicate packaging that keeps WhatsApp/Watusi in the bundle
    // name but does not use one of the exact names above.
    const char *app = strstr(path, ".app/");
    if (app) {
        // Only inspect the app bundle name itself. Do not let a later path
        // component such as an extension name cause a false-positive match.
        const char *bundleStart = app;
        while (bundleStart > path && bundleStart[-1] != '/') bundleStart--;
        size_t bundleNameLen = (size_t)(app - bundleStart);

        if (range_contains(bundleStart, bundleNameLen, "WhatsApp") ||
            range_contains(bundleStart, bundleNameLen, "Watusi")) {
            return true;
        }
    }

    return false;
}

static bool path_is_supported_target(const char *path) {
    if (!path_is_whatsapp_or_watusi_bundle(path)) return false;

    const char *base = basename_ptr(path);
    if (!base) return false;

    // Main application process.
    if (strcmp(base, "WhatsApp") == 0 ||
        strcmp(base, "WhatsApp Business") == 0 ||
        strcmp(base, "Watusi") == 0) {
        return true;
    }

    // WhatsApp extensions. ServiceExtension is the critical target for
    // incoming message handling / notification decryption.
    if (strcmp(base, "ServiceExtension") == 0 &&
        strstr(path, "/ServiceExtension.appex/")) {
        return true;
    }

    if (strcmp(base, "NotificationExtension") == 0 &&
        strstr(path, "/NotificationExtension.appex/")) {
        return true;
    }

    if (strcmp(base, "ShareExtension") == 0 &&
        strstr(path, "/ShareExtension.appex/")) {
        return true;
    }

    return false;
}

static bool get_target_path(int32_t pid, char path[PROC_PIDPATHINFO_MAXSIZE]) {
    if (pid < 2) return false;

    memset(path, 0, PROC_PIDPATHINFO_MAXSIZE);
    int n = proc_pidpath(pid, path, PROC_PIDPATHINFO_MAXSIZE);
    if (n <= 0) return false;

    return path_is_supported_target(path);
}

static int hooked_memorystatus_control(uint32_t command,
                                       int32_t pid,
                                       uint32_t flags,
                                       void *buffer,
                                       size_t buffersize) {
    char path[PROC_PIDPATHINFO_MAXSIZE];

    // Don't do the proc lookup for unrelated memorystatus operations.
    bool isLimitCommand =
        command == MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES ||
        command == MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK ||
        command == MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT;

    if (!isLimitCommand || !get_target_path(pid, path)) {
        return orig_memorystatus_control(command, pid, flags, buffer, buffersize);
    }

    // Primary iOS 15/16 path: active/inactive limits are supplied in a struct.
    // Use a local copy so RunningBoard's original buffer is never mutated.
    if (command == MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES) {
        if (buffer != NULL && buffersize == sizeof(memorystatus_memlimit_properties_t)) {
            memorystatus_memlimit_properties_t original =
                *(memorystatus_memlimit_properties_t *)buffer;
            memorystatus_memlimit_properties_t local = original;

            // XNU interprets <= 0 as "no custom HWM / no per-task custom limit"
            // and installs the normal system-wide task limit instead.
            local.memlimit_active = -1;
            local.memlimit_inactive = -1;
            local.memlimit_active_attr = MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;
            local.memlimit_inactive_attr = MEMORYSTATUS_MEMLIMIT_ATTR_FATAL;

            int rv = orig_memorystatus_control(command, pid, flags,
                                               &local, sizeof(local));
            os_log(wju_log(),
                   "UNCAPPED %{public}s pid=%d cmd=7 active=%d inactive=%d -> system task limit (rv=%d)",
                   path, pid, original.memlimit_active,
                   original.memlimit_inactive, rv);
            return rv;
        }

        // Unknown layout: fail open rather than pretending success. This avoids
        // breaking RunningBoard if Apple changes the ABI on another iOS build.
        os_log_error(wju_log(),
                     "Target %{public}s pid=%d used unexpected cmd=7 buffer size=%{public}lu; passing through",
                     path, pid, (unsigned long)buffersize);
        return orig_memorystatus_control(command, pid, flags, buffer, buffersize);
    }

    // Legacy/single-value path. XNU reads the requested MiB limit from flags as
    // int32_t. UINT32_MAX therefore becomes -1 and selects the system task limit.
    int32_t oldLimit = (int32_t)flags;
    int rv = orig_memorystatus_control(command, pid, UINT32_MAX,
                                       buffer, buffersize);
    os_log(wju_log(),
           "UNCAPPED %{public}s pid=%d cmd=%u limit=%d -> system task limit (rv=%d)",
           path, pid, command, oldLimit, rv);
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
               "WatusiJetsamUncap loaded in runningboardd; WhatsApp/Watusi custom memlimits will be replaced with the system task limit");
    }
}
