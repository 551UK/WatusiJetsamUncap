# WatusiJetsamUncap

Rootless Dopamine tweak for iOS 15/16 that removes WhatsApp/Watusi's custom per-process Jetsam memory ceilings, with particular focus on WhatsApp's `ServiceExtension`.

## Why

Watusi can make WhatsApp's notification `ServiceExtension` use substantially more memory. If the extension reaches its small custom Jetsam limit, iOS can terminate it while handling an incoming push. A typical symptom is that incoming messages stop/delay until another push causes the extension to launch again. Disabling Watusi injection for the extension can make the symptom disappear because the extension's memory footprint falls back below the stock limit.

## What this version does

The tweak injects **only into `runningboardd`** and hooks `memorystatus_control()`.

For supported WhatsApp/Watusi processes, it intercepts:

- `MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK` (5)
- `MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT` (6)
- `MEMORYSTATUS_CMD_SET_MEMLIMIT_PROPERTIES` (7)

Instead of merely swallowing RunningBoard's assignment, v1.1 passes the assignment to XNU with active/inactive limits of `-1`. On XNU, `-1` means the default system-wide task memory limit is used instead of a smaller custom per-process limit.

This is deliberate: it removes the small extension-specific/custom ceiling without disabling global memory-pressure Jetsam for the phone.

## Targets

- Main WhatsApp/Watusi executable
- `ServiceExtension` **(primary target)**
- `NotificationExtension`
- `ShareExtension`
- Standard WhatsApp, WhatsApp Business, and common Watusi/duplicate bundle names

The tweak does not depend on a specific Watusi version because it does not hook Watusi internals.

## Installation

1. Remove/disable other WhatsApp Jetsam-limit tweaks such as FixWANotifs/FixWANotifications16.
2. Install the rootless `.deb`.
3. Perform a **Userspace Reboot**. A respring is not sufficient because the tweak must reload into `runningboardd`.

## Verification

After the userspace reboot, the tweak logs when it changes a target limit. From an iPhone terminal, unified logs can be inspected for the subsystem:

`com.551.watusijetsamuncap`

Expected entries contain `UNCAPPED` and should show the `ServiceExtension` path when RunningBoard assigns its memory limit.

You can also watch `ServiceExtension` in CocoaTop64. If the tweak is working, the extension should be able to pass the old fixed extension ceiling without being killed for `per-process-limit` at that point.

## Important limitation

This does **not** make ServiceExtension immortal. It can still terminate because of:

- a Watusi/WhatsApp crash or exception,
- watchdog timeout,
- code-signing/injection failure,
- system-wide low-memory pressure,
- another non-memory process termination reason.

If it still dies after its custom Jetsam cap is removed, collect the crash/Jetsam log. The termination reason will tell us whether the remaining problem is Watusi itself rather than the per-process memory ceiling.
