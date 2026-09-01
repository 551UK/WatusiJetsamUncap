# WatusiJetsamUncap

Rootless Dopamine tweak for iOS 15/16 aimed at WhatsApp/Watusi notification failures caused by the notification `ServiceExtension` being killed at its custom Jetsam memory ceiling.

## v1.2.0

v1.2.0 changes the strategy used by v1.1. Instead of writing `-1` and relying on default task-limit semantics, it uses the same `runningboardd` / `memorystatus_control()` interception method used by established WhatsApp Jetsam fixes and raises the `ServiceExtension` active/inactive custom limit to **512 MiB**.

This is intentionally limited to WhatsApp's `ServiceExtension`. It does not raise limits for every process on the phone and it does not disable global iOS memory-pressure Jetsam.

The tweak also calls `MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES` after a successful assignment and logs the effective active/inactive limit reported by the kernel. This lets us distinguish "RunningBoard requested 512 MB" from "the kernel actually has 512 MB applied".

## Target

- `WhatsApp.app/PlugIns/ServiceExtension.appex/ServiceExtension`
- WhatsApp Business equivalents
- common Watusi/duplicate app-bundle paths

It does not depend on a particular Watusi version because it does not hook Watusi classes or functions.

## Installation

1. Remove/disable other WhatsApp Jetsam tweaks such as FixWANotifs/FixWANotifications16.
2. Install the rootless `.deb`.
3. Perform a **Userspace Reboot**. A respring is not enough because this tweak injects into `runningboardd`.

## Logging

Unified-log subsystem:

`com.551.watusijetsamuncap`

Useful entries include:

- `WatusiJetsamUncap v1.2.0 loaded...`
- `SET ... requested active=24 inactive=24 -> active=512 inactive=512 rv=0`
- `VERIFY ... effective active=512 inactive=512 ...`

The `VERIFY` line is the important one: it shows what XNU reports after the assignment.

## Important

512 MiB is a deliberately high diagnostic/workaround ceiling, not a claim that ServiceExtension should normally use that much memory. If ServiceExtension still terminates well below 512 MiB while `VERIFY` confirms 512 MiB is active, the remaining problem is likely not the custom per-process Jetsam ceiling. Use WatusiServiceDiag and the corresponding iOS crash/Jetsam report to identify the actual termination reason.
