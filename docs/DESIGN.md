# Design notes

Every rule here exists because an earlier version broke it. The failures are described
concretely, because "don't do X" is much less convincing than "X cost us a boot and here is the
log line".

## 1. The hardware constraint that shapes everything

The eGPU is reached over a USB4 port. The GPU sits behind a PCIe tunnel that has to be trained,
and the dock in the reference setup has **no standby power** before its PSU is switched on
(`ATX PS_ON`). Consequences:

* During POST the host cannot see the dock. There is nothing to enumerate, so no B
  firmware setting, no "auto start on boot" option and no hot-plug setting can help.
* By the time the tunnel is up, firmware has finished. Software cannot make firmware wait
  retroactively.
* Therefore the only reliable arrangement is: dock PSU switch left **on**, tunnel trains during
  POST, and software enables the device once Windows is ready.

The physical press of the dock's power button cannot be removed in software. Everything below
assumes that.

## 2. Only ever enable, never remove a device node

**Rule:** `eGPU-Watch.ps1` performs exactly one mutating operation, `pnputil /enable-device`.
It has no `remove-device` path at all.

**Why:** an earlier version treated a device that failed to start (`Problem 43`,
`CM_PROB_FAILED_POST_START`) as "remove the node and let the bus re-enumerate it". If the USB4
tunnel had not finished training, this deleted the node and the GPU then stayed missing for the
rest of the boot. Observed 2026-10-15:

```
09:50:10 Watch state -> Unknown [PCI\VEN_10DE&DEV_2783&...]
09:50:10 Watch action: remove + rescan [PCI\VEN_10DE&DEV_2783&...]
09:50:18 Enable no 4070 SUPER in the device tree (dock off or not plugged)
09:50:29 Watch eGPU not present - idling
```

The GPU did not come back until the dock was power-cycled.

`enable-device` is safe and reversible. Removing a node is neither. A device that genuinely
failed its own start cannot be fixed in software — only a dock power cycle or a cold boot
clears it — so waiting is both cheaper and strictly safer.

The `Restart` action still exists in `eGPU-Guard.ps1`, but it is manual-only: a human decides
when it is warranted. The watcher refuses it and logs:

```
refusing unsupported action 'Restart' - the watcher only enables
```

## 3. A deliberate stop must be distinguishable from a fault

**Rule:** `-StayDown` writes a marker that records the **boot time** it was created in. The
watcher skips all recovery while the marker is valid, and treats it as stale once the boot time
differs.

**Why:** the watcher's whole purpose is "not started → start it", which is the exact opposite
of what the nightly disconnect wants. The two fought each other and the disconnect lost:

```
23:55:00 Disable ... Device disabled successfully
23:55:02 Watch state -> Disabled
23:55:02 Watch action: enable
23:55:05 Watch state -> Started          # the disconnect lasted 3 seconds
```

Keying the marker to the boot time, rather than to a wall-clock window, means:

* it expires by itself on the next boot, so a fresh start brings the GPU up as usual;
* a **manual** `Disable` (without `-StayDown`) does not write a marker at all, so unplugging and
  replugging the dock still gets the GPU back automatically;
* `-Action Resume` clears it early, without a reboot.

A fixed time window (for example "23:55–00:00") was considered and rejected: it cannot express
"until the machine comes back", and it would leave the GPU dark for an unpredictable part of
the following day.

## 4. Retries escalate instead of taking one long nap

**Rule:** `-BackoffSeconds 5,10,20,30,60`.

**Why:** the previous flat `ProblemBackoffSeconds = 600` applied after the **first** failure.
The log shows what that cost:

```
15:45:16 Watch state -> Problem (problem 18)
15:45:25 Enable no 4070 SUPER in the device tree
15:45:30 Watch giving up after 1 attempts - waiting for a change
15:55:34 Watch state -> Started          # 9m41s later
```

The GPU had become usable long before the watcher looked again. "Connecting after boot feels
slow" was this, not the task start delay. Escalating backoff keeps the cost of a persistent
fault bounded while picking up a device that arrives shortly after within seconds.

## 5. Single instance via an exclusive file handle

**Rule:** the watcher holds `[IO.File]::Open($lock, 'OpenOrCreate', 'ReadWrite', 'None')` for
its whole lifetime.

**Why:** the first implementation wrote its PID into a file and checked whether that PID was
alive. PIDs are reused. After the original watcher died, its PID was taken by an unrelated
process, the new watcher concluded "another instance is running" and exited — permanently
disabling the only mechanism that brings the GPU back.

An exclusive handle is released by the kernel on process death, so it cannot go stale. The
lock files live in a `state\` subdirectory with a permissive ACL, so a non-elevated diagnostic
run can inspect them.

## 6. No child processes

**Rule:** every action is a single in-process `pnputil` invocation. The watcher never spawns
`powershell.exe`.

**Why:** spawning a process per attempt is what made boot feel heavy while the device sat in a
retry loop. Measured cost of the primitives used instead:

| Operation | Cost |
|---|---|
| `pnputil /enum-devices` | ≈ 69 ms |
| Enumerating `Enum\PCI` in the registry | ≈ 5 ms |
| Wildcard `Get-Item` on the device key | ≈ 2 ms |
| Reading `ConfigFlags` | ≈ 2 ms |

## 7. Absence must be free

**Rule:** with no eGPU attached, the watcher does one registry lookup per tick and nothing else.

**Why:** on a machine without the dock the tool must be indistinguishable from not being
installed. Measured over 15 s with no device: **0 ms of CPU, 0 child processes**, and exactly
three log lines at startup followed by silence.

## 8. Locale-independent `pnputil` parsing

**Rule:** parse only status **values** and numeric problem codes; labels are unreliable.

**Why:** `pnputil` localises its labels. Interactively it prints `Status:`; when its output is
redirected or hidden (as under Task Scheduler) it prints `状态:`. Only the values — `Started`,
`Disabled`, `Problem`, and so on — are stable, and even those are localised, so the parser
matches against a code-point table built at runtime.

Related traps that cost real debugging time:

* `pnputil` exits **0 even when it fails**. The failure is only visible in its text
  (`Failed to ...`, localised to `无法...` / `拒绝访问`). Always verify by reading `ConfigFlags`
  or the status back.
* `Problem Code: 43 (0x2B) [CM_PROB_FAILED_POST_START]` carries the numeric code in
  parentheses; the symbolic name is dropped entirely on a localised system.

## 9. The scripts are pure ASCII

**Rule:** CI fails if any `.ps1` contains a non-ASCII byte.

**Why:** localized strings were originally written literally into the files. The encoding
round-trip corrupted them — mojibake consumed a closing quote and produced unterminated
strings and syntax errors. Localized text is now assembled from `[char]` code points, and the
rule is enforced mechanically rather than by discipline.

## 10. Safety guards, and which ones may be waived

**Rule:** `-Force` waives only the "an external display is attached" warning. The "this is the
only active display adapter" guard is **never** waivable.

**Why:** the two risks are not comparable. Blanking an external monitor is an inconvenience;
disabling the only display adapter leaves the machine with no output at all, which is exactly
the situation this tool must never create. The nightly task passes `-Force` (the monitor is
normally attached at 23:55) and cannot pass anything that defeats the second check.

This is also why the missing `-Force` on the nightly task was a silent failure rather than a
loud one — worth knowing when diagnosing:

```
23:55:00 Disable start
23:55:01 WARN an external display looks attached
23:55:01 ERROR refusing without -Force
23:55:01 Disable end (exit=5)
```

## 11. Task principal and elevation

**Rule:** the tasks that must run without a logged-in user are registered with
`-Principal SYSTEM -LogonType ServiceAccount`, which **requires** an elevated shell.

**Why:** registering a `SYSTEM` principal without administrator rights fails with "Access is
denied", and a non-elevated `Get-ScheduledTask` cannot even read `SYSTEM` tasks back — so
verification of the installed arguments must also be elevated.

Related: a toast can only be shown by an interactive caller. The nightly task runs as `SYSTEM`
in session 0, where the toast API fails with `E_ACCESSDENIED`. That is expected, so the task
does not pass `-Toast` and the failure is logged at INFO rather than WARN.

## 12. Monotonic state is not assumed

The device can pass through `Unknown` and `Disconnected` while the tunnel trains, and
`pnputil` may briefly disagree with the registry. The watcher therefore treats
`Disconnected`/`Unknown` as *wait*, clears the failure streak on any genuine state change, and
never re-fires an action for the same `(state, attempt)` pair.

## 13. Exit when there is nothing left to do

**Rule:** the watcher is installed with `-StopWhenRunning`: it exits as soon as the device is
`Started`. `-IdleExitMinutes` (default 30) bounds it further, so a dock that never appears
cannot leave a process resident.

**Why:** measured steady state on the reference machine with the GPU present:

| Metric | Value |
|---|---|
| CPU | 0.083 % of one core (≈ 72 s per day) |
| Memory | 27.8 MB |
| Poll rate | ≈ 1.5 `pnputil` spawns per minute |

Small, but it buys nothing. Once the GPU runs, the watcher's only remaining job would be
noticing a drop-out — and the scheduled `23:55` task already handles the routine stop while
`-Action Enable` covers the manual case. A process that spawns a child every 40 s forever, for
no benefit, is waste.

Two measurement traps found while establishing that baseline, both worth remembering:

* **A short sample makes the percentage meaningless.** A watcher 0.1 min old reported 82.8 %
  CPU; measured over a 75 s window the same process reported 0.083 %.
* **Do not identify the watcher by its command line.** It runs as `SYSTEM`, and a non-elevated
  `Get-CimInstance` cannot read a `SYSTEM` process's `CommandLine`, so a filter like
  `CommandLine -match 'eGPU-Watch'` matches nothing and reports "no watcher running" while it
  is running perfectly. Identify it by *who holds the lock file* — that is authoritative, and
  it is exactly the invariant the lock exists to provide.

## 14. What the remaining boot delay actually is

On the reference machine, a boot with the dock attached looks like this:

```
15:32:20  boot
15:32:43  watcher starts (23 s in) and sees "Problem 18"
15:32:54  enable attempt: device not yet in the device tree
15:33:14  Started - resolved on its own
```

Two separate components:

* **~13 s of Windows.** A boot trigger fires only once Task Scheduler is ready, roughly 13 s
  into boot. No `Delay` setting can move that, because the `Delay` is counted from the moment
  the trigger fires, not from boot. This is why a `PT10S` delay produced a start 23 s in.
  The delay is now `PT3S`, which is the only part that was ours to change.
* **~31 s of driver/tunnel initialisation**, during which the device reports a `Problem` state
  and then fixes itself. This is not software-addressable: the watcher deliberately does not
  remove the node (rule 2), and an unproven "fix" here is exactly the class of change that
  caused the failure in rule 2 in the first place.

So the honest summary is that the reachable floor is set by the hardware and the OS, and the
part that was ours has been reduced to a 3 s delay plus a 5 s detection cadence.

## 15. A toast that reports success and shows nothing

The 23:50 reminder was a WinRT `ToastNotification` shown through
`ToastNotificationManager.CreateToastNotifier(<AUMID>).Show()`. Every night the log said
`toast shown`. Nothing ever appeared on screen.

`Show()` returns normally for an AUMID that is not registered as a Start Menu shortcut for the
current user, and Windows then drops the notification silently. There is no exception, no error
code, and no way for the caller to tell the difference between "delivered" and "discarded".
Focus Assist and the per-app notification toggle produce the same silence.

**Rule:** the reminder is now a WPF window that the script draws itself, in the bottom-right
corner of the working area, with a sound. It depends on nothing from the notification stack:
no AUMID, no registration, no Focus Assist cooperation. If the process can show a window in
the user's session, the reminder is visible, and that is a condition this code can actually
check by being run at all.

`eGPU-Guard.ps1 -Toast` delegates to the same script instead of keeping a second, equally
silent copy of the toast code.

Two adjacent traps, both hit while making this change:

* **`Start-Process -ArgumentList` does not quote array elements.** A body of `4070S is up.`
  arrives as three arguments; the child fails to bind them and — started hidden — fails in
  complete silence. Pass one pre-quoted string instead.
* **Those quotes must be double quotes.** Windows command-line parsing strips `"` but not `'`,
  so `-File 'D:\...ps1'` looks for a file whose name literally starts with an apostrophe.
  The single-quoted version runs fine interactively and fails from `Start-Process`, which is
  the worst combination.

## 16. Acting on a state that is no longer true

The watcher reads the device state, decides to enable, and *then* waits for the action lock.
Between those two points another actor — the single-shot `Boot-Enable` task, or a manual
`-Action Enable` — can do the job first. The stale plan then issues a second
`/enable-device` against a device that is already started:

```
13:27:58  Enable  pnputil /enable-device ... Device enabled successfully
13:27:59  Watch   Enable failed: ... 设备已启用 (device is already enabled)
13:28:03  Watch   state -> Started
```

A scary WARN for a no-op, produced by the two halves of the same system fighting over the same
device. Two fixes, because either alone would leave a gap:

1. **Re-read the state once the lock is held**, and skip if the device is already `Started`.
   The plan is a guess; only the state under the lock is a fact. One extra `pnputil` call
   (~34 ms) on a path that runs at most a couple of times per boot.
2. **Treat "already in the requested state" as success.** `pnputil` exits non-zero and prints
   a complaint when the end state already holds. That is an idempotent no-op, not a failure,
   and the benign spelling is checked before the failure verdict is finalised.

The single-shot `Boot-Enable` task was also demoted to a genuine fallback (`PT2M`) so the two
cannot race at boot in the first place: the watcher starts 3 s after the boot trigger and owns
the job, while the fallback only matters if the watcher never started at all.

Verified by reproducing the race deliberately — disable the device, then start both actors
together — which produced the dedup branch and no false warning.

## 17. A reminder must not contradict what actually happens

With no dock attached the `23:55` task finds no device and does nothing. The `23:50` reminder
used to appear regardless, announcing a disconnect that was not going to happen, and the log
recorded the absence as `[ERROR]` — a red line on every such night, which is how a log stops
being read.

**Rules:**

* The reminder is skipped when no matching eGPU is attached. This is the **default**, not an
  opt-in flag, for two reasons: the scheduled task then needs no argument, and the behaviour
  cannot be left half-applied by a task that was never re-registered. `-Always` overrides it.
* "No device attached" is `[INFO]`, not `[ERROR]`. Exit code 2 still marks *not found* for
  callers; only the log level changed.
* The presence check is **delegated** to `eGPU-Guard.ps1 -Action Status` (exit 0 = present,
  2 = absent) instead of being reimplemented in the reminder. One device-matching rule, in one
  place: a second copy would drift the day `-MatchDescription` or `-MatchDeviceId` changed.
* The check **fails open**. A missing helper script, an unexpected exit code or an exception
  all end in the reminder being shown, because a cancelled reminder is a silently lost one.
  Only an explicit "absent" skips it.

All four branches are covered by an isolated test (a stub `eGPU-Guard.ps1` returning 2, 0, 1,
and absent), so the fail-open behaviour is verified rather than assumed.
