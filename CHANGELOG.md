# Changelog

All notable changes to `thermal-guard` and `luci-app-thermal-guard`.
Versions follow `Major.Minor.Patch` up to 2.0.0 and
`Major.Minor.Build.Revision` from 2.1.0.0; both packages are released
together and carry the same number.

## 2.1.2.0

A fix release for the status page of `luci-app-thermal-guard`. The daemon is
unchanged apart from its version number.

### Notes for operators

- **Security relevant: the rpcd ACL of `luci-app-thermal-guard` grants one more
  call for reading, `luci.getUnixtime`** (the router's clock). LuCI's own
  status pages use the same call.
- After the upgrade, reload the status page with the browser cache emptied (or
  open it in a private window). LuCI loads the page script separately, and a
  browser that had the page open before may keep showing the old one, with the
  modem in one row, even after a forced reload.

### Fixed

- **A router without NTP no longer looks stopped.** The status page measured
  the age of the last reading, whether the status file was still written and
  how long a clear had been running against the browser's clock, while every
  time in the status file comes from the router's. On a router hours or days
  behind, the page said "The service is not running" and "Last reading: 2789
  min ago" while the daemon ran. It now reads the router's clock through
  `luci.getUnixtime` with every poll; where that fails, the browser's clock
  stands in as before.

### Changed

- The modem shows in two rows: "Modem model" with the model alone, and "Modem
  profile" with the profile's thresholds and its pattern, `85 / 95 °C
  (RM520N-GL*)`. Without a profile the row gives the thresholds in force:
  `none, defaults 80 / 88 °C` while neither is set in the configuration,
  otherwise `none, configured 80 / 95 °C`, also when only one is. The single row
  repeated the model in the profile pattern (`FM350-GL, profile FM350-GL*`).

## 2.1.1.0

A hardening release on top of 2.1.0.0, which was never published. It fixes
what two code reviews of 2.1.0.0 found, and the decisions taken on the way are
stated in plain words below.

### Notes for operators

- **Security relevant: the rpcd ACL of `luci-app-thermal-guard` has one new
  line**, `/usr/sbin/thermal-guard reset-start` with `exec`, next to `reset`
  and `trips-keep`. It is an exact command line with a fixed argument: nothing
  from the page or from UCI reaches it, and it grants no access to the hook
  directory. The package reloads rpcd when it is installed; if the Clear
  button reports a permission error afterwards, run `/etc/init.d/rpcd reload`
  and reload the page.
- **Fan values a stage saved before this version are not handed back on their
  own.** 2.0.0 and 2.1.0.0 saved the fan's values whenever a stage forced the
  fan, but recorded no identity of it, so nothing tells which fan they belong
  to. Such a state, kept from any stage that forced the fan, is unresolved:
  reset writes nothing to the fan for it, ends with `could not undo: fan`, lists
  `fan` in `reset_failed` and keeps the values (`fan_restore_pending=1`). Check
  the fan by hand, run `thermal-guard fan-forget` over SSH, then clear again.
  Only a state without saved fan values is handed back as before.
- In `pwm` mode an empty `pwm_enable_path` means the output's own
  `pwmN_enable` (`<pwm_path>_enable`) wherever the chip has one, also on a chip
  that is not found by its hwmon name, and never the mode file of another chip.
  Before, a `pwm_path` on one chip could be paired with the `pwm1_enable` of the
  `pwmfan` chip, which switched that chip to manual and left the configured
  output alone. Where `pwm_path` is unusable and the detected chip takes its
  place, a configured `pwm_enable_path` goes with the configured output: the
  detected output's own mode file is used. A `pwm_enable_path` that resolves to
  another file than `<pwm_path>_enable` cannot be recorded: the fan is still
  forced, its record is unresolved. The same file named through `/sys/class`
  and `/sys/devices` counts as the same.
- With an unresolved fan record kept, a new stage forces the configured fan
  without a record or saved values of its own. That fan stays forced past a
  reset until `thermal-guard fan-forget` and a second reset, which hands it to
  `fan_governor` or, for `pwm`, to mode 2. The automatic recovery does not apply
  while the record is unresolved (`recover_state=fan`).
- `thermal-guard reset` can now exit 1: when something it undid could not be
  confirmed, and when the daemon is busy with a stage action and the lock does
  not free up within `RESET_WAIT` (240 seconds). A script that calls it has to
  look at the exit code. Entries an earlier reset left in `reset_failed` do not
  make it exit 1; it says on stderr that they are still in force. While another
  reset runs, `reset` joins it instead of running a second one: it prints that
  request on stdout and exits by its result.
- **`flock` is required.** It is an applet of the default OpenWrt BusyBox.
  Without it, or where `/var/run/thermal-guard/lock` cannot be opened, the
  daemon does not start (`crit`, `<reason>, not starting`), and `thermal-guard
  reset`, `reset-start` and `fan-forget` exit 1 and change nothing (`<reason>,
  nothing was changed`). `status`, `test` and `selftest` still work.
- Out of range or off list values in `/etc/config/thermal-guard` are replaced
  at load and logged once: `interval` is held to 5 to 300 (the nearest limit),
  `hold_minutes` to 1 to 60, `hysteresis` to 0 to 40, and `fan_mode`,
  `modem_source`, `stage1_action`, `stage2_action` fall back to their defaults.
  A configuration that relied on a value outside these ranges changes behaviour.
- A stage state that recorded no action (written by 2.0.0, and the second
  stage of one written by 2.1.0.0) is undone with the configured action by
  `thermal-guard reset`, and the log says so.
- A stage state written by 2.1.0.0 records no interface for `interface_down`:
  reset and the restore after a reboot use the configured interface for it
  (`action_interface`, else `uplink_interface`). An `IFACE1` or `IFACE2` key
  that is there but empty still means nothing was taken down. Such a state also
  has no `CPU_SEEN`; a stage loads as processor involved then, so it is not
  undone automatically and waits for `thermal-guard reset`.
- The automatic recovery count lives in the new file
  `/etc/thermal-guard/recover` from now on. Without it the count from the
  stage file is used, so nothing is lost on the upgrade.

### Decisions

- **A processor warm at any point blocks automatic recovery.** Until now the
  cause was judged on the readings at the moment stage 1 began. A stage the
  processor had started, followed by a hot modem at a cool processor, counted
  as caused by the modem and could clear itself. Now any processor reading at
  or above `cpu_warn` while a stage is active marks the incident as processor
  involved (`cpu_seen`, `recover_state=cpu`), and such a stage waits for
  `thermal-guard reset`. The cost: an incident in which the processor was
  briefly warm and the modem then dominated needs a manual reset.
- **Missing readings do not escalate stage 2 of 3 to stage 3 of 3.** The
  documentation said a missing reading always counts as "condition met", but
  the code never did that. It is now described as it works, per transition:
  thresholds need a reading; from stage 1 of 3 to 2 of 3 on time alone a
  missing reading counts as no drop; from stage 2 of 3 to 3 of 3 on time alone
  only a rise above the reference counts; the cooled report counts a missing
  reading as cool and the automatic recovery never does. A selftest pins the
  stage 2 of 3 to 3 of 3 transition: a box in stage 2 of 3 whose sensors both
  fail stays there.
  Switching Wi-Fi off on no data would be a second guess on top of the radio
  already being off, and a blind box is reported anyway.
- **Without `curl`, a notification address must not carry a secret in its
  path.** `uclient-fetch` and `wget` take the address as a command argument,
  which `/proc` shows to every local process. An address with a query string or
  user info is refused for them, as before, but a secret in the path (ntfy
  topic, Slack or Discord webhook) cannot be recognised and is sent. The README
  says so; refusing HTTP without `curl` altogether would silently remove
  notifications from small images.
- **A reset that cannot undo everything still clears the stage, and says
  so.** Reset is the operator's command and must stay possible when the
  hardware is gone, so it clears the stage, logs and notifies at `crit`, exits
  1 and publishes what is still in force as `reset_failed`. A later reset
  without a stage tries only the fan release again; `wifi_off`,
  `modem_radio_off` and `interface_down` stay listed until the next stage or a
  reboot and have to be put right by hand. They are not that reset's failure:
  it exits 0 with `reset_state=done` and says once at `notice` "still in force
  from an earlier reset: <list>"; "could not undo" (`crit`, exit 1) names only
  what the reset itself tried, a fan that fails again included. The cost: after
  a failed undo the stage reads idle while an effect remains, which only
  `reset_failed` shows.
- **The Clear button starts the reset detached and reads the result from the
  status file.** rpcd ends a command after its timeout (30 seconds on the
  GL-X3000), the page gives up after about 20, and a reset that waits for the
  lock or retries Wi-Fi can take longer. Killed in the middle of an undo, the
  stage was still shown while part of its effect was already gone. The new
  command `thermal-guard reset-start` returns at once, and the page polls
  the request record in the status file for the request it printed.

### Security

- The rpcd ACL line named above. The line for `/usr/sbin/thermal-guard reset`
  stays, so a status page an earlier version left in the browser cache still
  clears; the page of this version no longer runs it, so it could go in a later
  release.
- A failed `chmod 600` on the temporary curl configuration now aborts the
  notification before the address or the header is written to it.
- A modem temperature file must be a regular file, is read under the AT time
  limit and at most 32 bytes. A fifo without a writer used to stop the daemon
  for good.
- Every command that can wait under the state lock (hooks and `wifi` included),
  and every background job or waiting subshell, runs without the lock's file
  descriptor, so a process left running cannot keep the lock held after its
  holder is gone. Short one shot tools may keep it.

### Fixed

- **No more bare `Killed` lines in the log.** A command that ignored its time
  limit and had to be killed (a hook, `wifi`, `ubus`, `sync`) ended `timeout`
  itself with SIGKILL, and ash printed `Killed` to the daemon's stderr, which
  procd passes to syslog; `thermal-guard reset` printed it on the terminal.
  Every time limit now runs through one helper that waits in a subshell with
  stderr discarded and passes the exit status on.
- **A record rename that outlives its caller can no longer undo a later
  request.** The rename of the request record and of `reset.gen` ran without
  the admission lock's descriptor. With its caller killed before the rename
  landed, a second Clear was admitted, wrote its record, and the old rename then
  put back the older one. The rename now keeps the descriptor, so admission
  stays held until it has landed.
- **The page keeps the failure list of its own clear.** The status file
  published only the warning list `reset_failed`, which a stage entered after
  the clear empties. A page that polled late then reported the clear as failed
  with nothing in force. The request's own list is now `reset_req_failed`, and
  the page reads that one.
- **The stage 1 banner and the fan readings follow the fan in control.** With a
  pwm fan taken over and `fan_mode none` set during the stage, the fan stays
  forced, as designed, but the page said it was left to its own controller. The
  status now publishes `fan_control`, and while a takeover record is kept the
  fan readings come from the recorded fan; the configured scale applies only
  while the settings still describe it, otherwise the raw value is shown.
- **Reset undoes what ran, not what the options say now.** The actions and
  interfaces of both stages are recorded when the stage begins (new state keys
  `ACTION2`, `IFACE1`, `IFACE2`); reset, the restore after a reboot and the
  automatic recovery use them. Before, a changed `stage1_action` or
  `action_interface` made reset undo the wrong thing and report success.
- Every undo and the fan release are confirmed by reading the result back, and
  failures are collected, reported and published as `reset_failed` (status file,
  `thermal-guard status`, warning on the status page). A fan that could not be
  handed back keeps its saved values so the next reset can try again.
- **The fan taken over at stage entry is the one handed back.** Reset and the
  automatic recovery used the fan settings of their own moment: a `fan_mode`
  changed to `none` during a stage left the fan forced while reset reported
  success and dropped the saved values, and a `pwm_path` moved to a second chip
  would have written the first chip's values to the second. A takeover now
  records the fan by identity (hwmon `name` or cooling device `type`, the
  resolved `device` link, the pwm output and the full speed value written to it,
  the `type` of the zone) with the boot id and the saved values, and saves that
  before its first write; a failed or partial takeover keeps it. Forcing, the
  reassert and the release work on that fan until a release reads back, found
  again by scanning only, so a renumbered `hwmonN` is found and a second chip is
  never written. The reassert writes the recorded full speed value, so a
  polarity set during the stage for an inverted chip cannot stop the fan taken
  over, and clearing `pwm_full` does not stop the reassert. Changed fan
  settings, `none` and the polarity included, apply from the next takeover and
  are logged once at `warning`. Where no fan or several fit the record,
  nothing is written, `fan` is listed in `reset_failed` and the record stays
  for the next try. A record of an earlier boot is dropped at load (`notice`)
  and a restored stage takes the fan over afresh. A record without a valid
  boot id, with a part that fails its check, or saved values without any
  identity are unresolved: nothing is written from them, and they stay until
  `thermal-guard fan-forget`. Every record key is checked where it is written
  and where it is read.
- The save of a takeover changes only the fan keys of the file and leaves the
  stage as it was loaded. A daemon killed while the stage actions run (a slow
  hook, Wi-Fi retries) therefore decides and enters that stage again after its
  restart, with the values the fan had before the takeover, instead of finding
  the stage recorded as in force with its actions never run. During a restore
  after a reboot the record goes to the persisted copy, where the stage comes
  from, so a daemon killed in the middle of the restore starts it again.
- **Reset and the daemon cycle no longer run over each other.** A reset used to
  land in the middle of a stage action and be written over by the cycle that
  had loaded the state before, which left the radio off with the stage cleared.
  They now take one lock (`/var/run/thermal-guard/lock`, `flock`). A reset waits
  for it up to `RESET_WAIT` seconds, a cycle that finds it held skips its
  decision.
- A forced fan is read back: the cooling device's `cur_state` and the zone
  policy, or the PWM mode and duty cycle. A missing output path or a write the
  driver ignored is a failed action instead of success: at stage 1 of 3 it is
  notified at `crit` (`could not force the fan`), and a reassert of a fan that
  another controller took over is notified once when it fails, again only after
  a reassert has worked or the stage has been cleared, instead of a `crit` line
  every cycle.
- The automatic recovery, when the stage action is undone but the fan cannot be
  handed back, applies the stage action again and forces the fan again (a
  release can fail halfway, with the duty cycle already handed back), so the
  stage keeps what it claims, and counts the attempt.
- The automatic recovery count, its 24 hour window and the "limit reached" flag
  survive a reboot (`/etc/thermal-guard/recover`). They reached the flash only
  with a stage change before.
- A UCI integer with more than six digits no longer makes a range check fail
  open; it is read as 999999 and rejected.
- **Numbers with leading zeros from outside the configuration are read as
  decimals too.** A modem reading of `09000` in `modem_temp_file` was an
  arithmetic error that ended the daemon in its first cycle, and `010000` was
  read as octal (4 degrees instead of 10). The same held for the state file,
  the recovery count in `/etc/thermal-guard/recover`, the warn and crit columns
  of the modem table, `trip_active`, `trip_boost_offset` and the readings given
  to `thermal-guard test`. All of them now go through one conversion that drops
  leading zeros. A `trip_boost_offset` longer than two digits is rejected
  instead of passing the range check. The `modem-temp` hook gets the same seven
  digit limit as `modem_temp_file`: a number of more than seven significant
  digits (leading zeros are dropped first) is no reading.
- Temporary files of the state, the persisted state, the status file, the
  recovery count, the reset request record and the curl configuration of a
  notification are named after the writer's own process ID, so a detached reset
  and the daemon posting at the same moment no longer share one curl
  configuration. At start the daemon removes the leftovers of a killed writer
  of the state, the persisted state, the status file, the recovery count and
  the event log trim (also named after its writer now), and the curl
  configuration of a poster that is gone, which holds the notification address
  and header and stayed in `/var/run/thermal-guard` until a reboot; one whose
  poster still runs (a detached reset, say) stays. Those of the reset request
  record go with the next request, once their writer is gone.
- A reset leaves the outbox alone. When its own message went out it emptied the
  queue, and with it an alert the daemon had queued while the reset blocked it,
  so that alert was never delivered. The daemon delivers the queue as before.
  A queued message that is also among the recent events in the reset's message
  now arrives twice: in that list and from the queue.
- A reset that finds no working state reads the persisted copy. A daemon killed
  during the restore after a reboot, after it had saved the fan record there,
  left no working state; a reset taking the lock before the restarted daemon
  then handed back the configured or detected fan, after a renumbering perhaps
  another chip, and removed the persisted copy with the record. A record of an
  earlier boot found there is dropped as at load.
- **One reset at a time, with request ids that cannot repeat.** Two Clear
  clicks within one second shared one `reset_ts`, so a page could take the
  result of another request for its own, and a later result could overwrite one
  the page had not read yet. Now `reset-start` and `reset` are admitted one at a
  time under `/var/run/thermal-guard/reset.admit`: a Clear or a `reset` while a
  request lives joins it, otherwise a new request gets the next generation of
  this boot and the id `<generation>-<pid>`, and the one before it stays in the
  record with its own result and failure list. The worker of a request is
  recorded by pid and start time before reset-start lets go, so a later start
  joins even a worker that has not taken its first step, and never a process
  that only reuses its pid. A request whose process is gone shows as `aborted`
  and is recorded so by the next request; a worker that finds its request
  aborted or replaced leaves without taking the state lock or writing, and a
  result is only written over its own running request. A busy `reset` typed by
  hand no longer overwrites the mark of a running detached reset. The detached
  reset uses its own process ID for temporary file names (a subshell shares
  `$$` with its parent).
- **The status page takes only its own request as the result of a Clear.** It
  matched by `reset_ts`, so a clock step or a second request in the same second
  could end its wait with another request's result. It now waits for the
  `reset_boot` and `reset_id` that `reset-start` printed (also when it joined a
  running request) and finds them as the current or the previous request, with
  that request's own failure list. The status file gains `boot_id`, the boot it
  was written in, so a reboot ends the wait as a restart with unknown result
  as soon as the new boot writes its first status (a request record of another
  boot does the same). Two later requests of the same boot end it as "no
  longer available" at once, `aborted` as aborted, and the final timeout says
  the outcome is unknown instead of "still running". None of these reads as
  success. New check `tests/check-monitor-clear.js` (Node, in CI) feeds the wait
  with status sequences.
- Status page after a reset that could not undo everything: the Clear button
  stays while `reset_failed` names `fan`, so the fan release can be tried
  again. For the other entries there is no button, since a clear without a
  stage does not try them again, and the page says they stay listed until the
  next protection stage or a reboot. Such a reset also keeps them in
  `reset_failed` instead of dropping them, so the warning no longer goes away
  while Wi-Fi, the radio or the interface is still off. The result message of
  a clear names them as still in force from an earlier clear. A fan whose
  values are kept for that retry (`fan_restore_pending=1`) is no longer
  reported as controlled by another service, and the daemon no longer logs the
  zone it left on `user_space` as another program's.
- A device tree node with `cooling-levels` but no `compatible` no longer prints
  an error with every status write.
- Status page during a clear: while the page waits for its own clear, or the
  status file says `reset_state=running`, a status file that stopped being
  written reads "Clearing is running, readings resume afterwards." instead of
  "The service is not running". A `running` mark older than the page's wait (500
  seconds) no longer counts, so a reset killed from outside does not hide a
  stopped service. The page waits for the result of a clear as long as a joining
  `thermal-guard reset` does, `RESET_WAIT` plus `RESET_BUDGET` plus 60 seconds:
  the slowest clear that still ends (lock wait, undo budget, final flush,
  admission) takes about 480 seconds, and the earlier 440 called it unknown.
- Settings page: `interval`, `hold_minutes`, `hysteresis`, `trip_boost_offset`,
  `recover_minutes` and `recover_max` take whole numbers only. A fraction passed
  the page and the daemon then used the default.

### Changed

- The test suites run the daemon under the shell they run under. Under
  `busybox sh` on a host whose `sh` is bash, the daemon itself had run under
  bash, so ash only behaviour went untested.
- **Only the holder of the state lock writes the state file, the status file
  or the hardware, however long it holds it.** The daemon never decides without
  the lock: a cycle that finds it held reads the sensors and alerts at `crit`,
  once per holder (the PID in `lock.owner`) and level: `blocked by a reset for
  <n> s, no action taken (cpu <c> C, modem <m> C)` once the daemon has found the
  same holder in place for longer than `RESET_BUDGET`, `blocked
  by a reset while <cpu|modem> is at <t> C, above its crit threshold, no action
  taken`, and `blocked by a reset while the CPU is at <t> C, its emergency
  threshold, no action taken`. It writes neither file and runs no action or
  recovery meanwhile. After the reset it decides on its next cycle, with the
  usual two hits in a row. This replaces the fallback of an earlier build of
  this version, which decided without the lock once a holder had kept it longer
  than `RESET_WAIT`: a long but live reset was then undone by the cycle running
  next to it. The cost: a reset that hangs delays a stage entry for as long as
  it hangs, visible through the alerts.
- A reset has `RESET_BUDGET` seconds for its undo steps. Before each one it
  compares what is left with the longest the step can take, derived from the
  time limits and retries the step runs with, and skips a step that might not
  end in time into `reset_failed`, logged at `crit`
  (`skipping the undo of <action>`).
- The commands run under the state lock that can wait (`wifi`, `ifup`,
  `ifdown`, `ubus`, `sms_tool`, hooks, `iwpriv`, `sync`, the HTTP fetchers) run
  under `timeout -k 5`, so one that ignores TERM is killed 5 seconds after its
  limit, and without the lock's file descriptor, as do the command
  substitutions and pipelines around them. `logger`, `ip` and the `sleep`
  between readback attempts run without the descriptor too, with no time limit
  of their own. Only short one shot file tools and filters (`cat`, `sed`,
  `head`, `mv` and the like) keep it while they run. A reset killed in the
  middle of a step leaves no process behind that keeps the lock held.
- The warning about a fan value another controller replaced no longer advises
  `fan_mode=none` while a fan taken over is being reasserted (it stays forced
  under `none`), and the messages about a fan that could not be forced name the
  mode of the fan taken over instead of the configured one.
- The recovery count is flushed again by its next save when the last flush
  failed, instead of the unchanged file being taken as saved.
- A reset writes `reset_state=running` and a status snapshot with it as soon as
  it holds the lock, before its first undo.
- A stage written to the overlay, the recovery count and their removal by a
  reset count as persisted only once `sync` completed within `CMD_TIMEOUT`. A
  flush that fails or hangs is logged as a failed persist, or for a removal as a
  warning that the stage may come back after a reboot.
- The README describes missing readings per transition and documents the lock,
  `reset-start`, the recovery file and the processor rule. The `thermal-guard`
  package description mentions the optional recovery.
- The status page and the help text of `auto_recover` say that a stage in which
  the processor was warm is not undone automatically (the old wording said
  "caused by the processor"); the German translation follows.
- `thermal-guard selftest` plants its own thermal, hwmon, network and device
  tree trees for the whole run instead of reading the board's, and a test
  helper aimed outside its scratch directory stops the run with a `FAIL` line
  before it deletes or writes anything. It is run as root on live boards.
- The integration suite takes about 10.5 minutes per shell (627 s under `sh`,
  629 s under `busybox sh` on the test VM). It runs with a `sync` stand-in,
  and a daemon run of the fan cases lasts until the state file exists instead
  of a fixed three seconds: a slow host flush ended a restore before its state
  was saved, and the next case then found no record.
- Both test suites must leave stderr empty under `sh` and `busybox sh`; CI fails
  on any line there.
- The selftest message about a missing `jsonfilter` and a comment in the CI
  workflow no longer point at a file that is not part of the repository.

### Added

- `thermal-guard reset-start`, the detached reset the Clear button runs. It
  prints `reset_boot`, `reset_id`, `reset_gen` and `reset_ts` of its request,
  `reset_joined=1` as well where it joined a running one, and returns at once.
- Status file and `thermal-guard status`: the request record, `reset_boot`,
  `reset_id`, `reset_gen`, `reset_kind` (`cli`, `page`) and the previous
  request `reset_prev_id`, `reset_prev_gen`, `reset_prev_state`,
  `reset_prev_failed`, `reset_prev_ts`. `reset_state` also says `starting` and
  `aborted`. The current request's own failure list is `reset_req_failed`.
- Status file and `thermal-guard status`: `fan_control`, the fan mode in
  control (the recorded one while a takeover record is kept, else `fan_mode`),
  and `fan_view`, `fan_percent`, `fan_taken`, `fan_unresolved` in both.
- Status file and `thermal-guard status`: `cpu_seen`, `reset_failed`,
  `reset_state` (`running`, `done`, `failed`, `busy`), `reset_ts` and
  `fan_restore_pending` (`1` while no stage is active and a fan takeover record
  is still kept, an unresolved one included); `thermal-guard status` also prints
  `fan_taken` and `fan_unresolved`.
- `thermal-guard fan-forget`, command line only and not in the LuCI ACL. After
  the operator has checked the fan by hand, it drops a fan takeover record from
  the working state and the persisted copy and `fan` from `reset_failed`,
  writes nothing to the fan and logs `fan restoration record discarded by the
  operator, the fan was not released` at `notice`. It waits for the lock like
  reset and refuses while a stage is active (exit 1).
- State keys `FAN_TAKEN`, `FAN_BOOT`, `FAN_T_NAME`, `FAN_T_DEV`, `FAN_T_ATTR`,
  `FAN_T_ZONE`, `FAN_T_FULL` and `FAN_UNRESOLVED`, the fan takeover record.
- `recover_state=fan`: an unresolved fan record blocks the automatic recovery;
  the status page says so and tells the operator to check the fan, clear the
  stage, then run `thermal-guard fan-forget`, which refuses while a stage is
  active.
- `DEVICES_ROOT` and `BOOT_ID_FILE`, environment variables of the process for
  tests (default `/sys/devices` and `/proc/sys/kernel/random/boot_id`).
- State keys `CPU_SEEN`, `ACTION2`, `IFACE1`, `IFACE2`, `RESET_FAILED`; files
  `/etc/thermal-guard/recover`, `/var/run/thermal-guard/lock`, `lock.owner` and
  `reset`. Older state files load with the new keys empty, apart from the two
  cases under Notes for operators (an absent `IFACE` key, an absent `CPU_SEEN`).
- `recover_state=nomodem`: stage 2 of 3 began while the modem had no reading,
  so it is not pinned on the modem and not undone automatically. The status
  page says so. Before, it read `cpu`, which blamed a processor that had stayed
  cool.
- `RESET_WAIT`, an environment variable of the process (default 240 seconds).
- `RESET_BUDGET`, an environment variable of the process (default 200 seconds):
  what a reset may spend on its undo steps, and how long the blocked daemon
  finds the same holder in place before it alerts (counted from the first cycle
  that found it).

### Known issues

- The reset request record keeps one previous result: two clears that complete
  between two polls of a page push the result it waits for out of the record,
  and then only the log has it; the page says the result is no longer
  available.
- A failed fan release during an automatic recovery switches the radio on and,
  after re-applying the action, off again. It counts toward `recover_max`.
- A threshold of seven digits or more is read as 999999 and never reached, which
  disables the stage it belongs to; for `cpu_emergency` that is the emergency
  stage of the processor.
- A reset that hangs blocks every protective action until it ends or is killed;
  the daemon keeps measuring and alerting meanwhile.
- The status file is not updated while the daemon is blocked by a reset, nor
  while a reset waits for the lock. A reset that ends `busy`, or `failed`
  because a detached reset could not reopen the lock, writes no status either:
  the request record and `thermal-guard status` show it at once, the status
  file only when a later holder of the lock writes it.
- During an upgrade the old daemon keeps running until procd restarts it with
  the new files (the package does that at the end of the install). Until then a
  daemon of 2.1.0.0 takes no state lock, and one of an earlier build of this
  version still decides without the lock once a holder has kept it for
  `RESET_WAIT` seconds. A 2.1.0.0 reset that is still running writes its mark
  in the old format (`reset_state` and `reset_ts` only), without the lock, and
  can replace the new request record: the status page then sees a record
  without `reset_boot`, gets no result and ends with "outcome unknown" after
  its final timeout.
- The undo of `modem_radio_off` and the automatic recovery talk to the modem
  port configured or detected at that moment. After a port change during the
  stage the confirmation does not prove that the original modem was switched
  back on: it may still be in flight mode while another modem was enabled.
- A message a reset queues while the daemon delivers the queue can be lost:
  the daemon reads the outbox, sends it and then empties it, and a line added
  in between goes with it. The reset queues its messages after it has dropped
  the state lock, and the daemon delivers without it. The event log keeps them.
- A rename of the request record that hangs keeps the admission lock: every
  later Clear or `reset` gives up after `ADMIT_WAIT` seconds with exit 1 until
  it ends. A rename on tmpfs does not wait for anything, so this needs a stalled
  process.

## 2.1.0.0

### Notes for operators

- **A configuration kept from 2.0.0 does not use the modem profile.** It still
  sets `modem_warn 80` and `modem_crit 88`, and `thermal-guard status` shows
  `modem_warn_src=uci`. To use the profile:
  `uci -q delete thermal-guard.main.modem_warn; uci -q delete thermal-guard.main.modem_crit; uci commit thermal-guard`
- A stage entered under 2.0.0 recorded neither its cause nor its action, so it
  is never cleared automatically; clear it with `thermal-guard reset`.

### Added

- **Modem profiles.** The daemon asks the modem for its model (`AT+CGMM`, or
  the new `modem-model` hook), up to three times per start until it answers,
  and takes `modem_warn` and `modem_crit` from
  `/usr/share/thermal-guard/modems`. Values set in UCI win option by option.
  Shipped: Quectel RM520N-GL 85/95 °C, Fibocom FM350-GL 80/88 °C, each with
  its source. Why: a GL-X3000 lost its uplink for six hours at 75 °C, a limit
  taken from the module's ambient range, while its hottest internal sensor read
  80 °C under ordinary 5G load.
- **Automatic recovery, off by default.** `auto_recover`, `recover_minutes`,
  `recover_max`: stage 2 of 3 caused by the modem alone clears itself after the
  modem has read cool for a while, at most a few times a day. Stage 3 of 3,
  stages the processor caused and the `command` action stay until a reset.
  Readings have to stay cool without a gap of more than three intervals plus a
  minute; a pause, a long restart or a clock step starts the count again. A
  missing modem reading is not cool, and on a board with a temperature sensor
  neither is a missing processor reading. The recovery undoes the action that
  ran when the stage began (new state key `ACTION1`), and only while it is
  still the configured `stage1_action`. An undo that does not confirm counts
  toward `recover_max` like one that does. Once the limit stops a recovery, the
  stage stays until a reset, also after the 24 hours.
- **Persisted recovery stage.** The recovery count reaches the overlay with
  every stage change and when the limit stops a recovery, so a reboot during a
  stage keeps the count from then and a limit already reached.
- Status file and `thermal-guard status`: `modem_model`, `modem_profile`,
  `modem_profile_warn`, `modem_profile_crit`, `modem_warn_src`,
  `modem_crit_src`, `cause1`, `auto_recover`, `recover_minutes`, `recover_max`,
  `recover_n`, `recover_at`, `recover_state`. `thermal-guard status` also shows
  `cool_since`.
- LuCI: model and profile on the status pages, the time stage 2 of 3 began, and
  whether and when it is undone automatically, worded from the daemon's
  `recover_state` (`cpu`, `nocause`, `action`, `capped`, `cooling`,
  `planned`). The recovery options keep their values while hidden, so setting
  stage 2 of 3 to a script and back does not delete them.

### Changed

- **The shipped configuration no longer sets `modem_warn` and `modem_crit`**,
  so the profile applies on a new installation. An existing configuration keeps
  its values.
- An implausible modem pair falls back to the profile, or to 80/88 without one,
  and no longer resets the CPU thresholds; an implausible CPU triple no longer
  resets the modem pair. Each is logged once instead of every cycle.
- Safety invariant 1 allows the optional automatic recovery; invariant 9 names
  the new `tg_name` guard.

### Fixed

- A number in `/etc/config/thermal-guard` with leading zeros is read as the
  decimal number it looks like: `09` is 9, `010` is 10. Shell arithmetic took
  `010` as 8 and failed on `09`.

## 2.0.0

### Breaking changes

- **Breaking: `trip_dt` is no longer a UCI option.** The daemon used to write
  it into `/etc/config/thermal-guard` from the running process, next to the
  operator's own edits. The device tree trips that `trip_active` was made for
  now live in `/etc/thermal-guard/trip_base`, written on the first cycle with
  `trip_active` set and kept across a sysupgrade. Without `trip_active` the file
  is neither read nor written. The package moves an existing `trip_dt` there
  once (`/etc/uci-defaults/90-thermal-guard-trip-base`) and removes the option;
  a leftover `trip_dt` is ignored. The daemon no longer writes UCI.
- **Breaking: `fan_cooling_device` and `fan_thermal_zone` are gone.** Both
  named a numbered path (`cooling_device0`, `thermal_zone0`), and those numbers
  can change between boots, which is what the detection by type avoids. The
  fan is found by `fan_cooling_device_type`, its zone by the link to it. A
  value left in an old configuration is ignored like any unknown option.

### Notes for operators

- **Syslog filters may need adjusting.** Every line now carries a
  `daemon.*` priority instead of `user.notice`: `crit`, `warning`, `notice`,
  `info` as listed under Changed. A `logread` filter or remote syslog rule
  written for `user.notice` no longer matches.
- **New dependency `jsonfilter`.** `base-files` already ships it on every
  OpenWrt and ImmortalWrt image, so nothing new gets installed there.
- **Update both packages together.** The config page's answer to a changed
  firmware runs `thermal-guard trips-keep`, which needs the daemon and the
  rpcd ACL of this release; the ACL grants exactly that command line.

### Added

- **`thermal-guard trips-keep`** records the device tree trips of the running
  boot as the ones `trip_active` was made for. The config page runs it for both
  answers to the new firmware notice; the ACL grants exactly this command line.

### Changed

- **README: a section on known limitations**: ModemManager and `at_lock`,
  notifications without `curl`, boards that report no temperature, and
  `wifi_off` on radios netifd does not manage.

- **Without `curl`, a notification address with a query string or user info
  is refused.** `uclient-fetch` and `wget` take the address on the command
  line, where every local process can read it in `/proc`, so a token in
  `?token=...` or `user:pass@host` would leak. The check runs when the
  configuration loads and clears `notify_url`, so nothing piles up in the
  outbox; the notify hook still works. An address without `http://` or
  `https://`, or with characters `curl` would misread, and a malformed
  `notify_header` are now rejected at load for the same reason. Each reason is
  logged once, the address itself never. A secret in the path of the address
  (Slack, Discord, a private ntfy topic) cannot be detected and stays visible
  without `curl`; the README says so.
- **A notification post without `curl` has a time limit.** `uclient-fetch` and
  `wget` run under `timeout` (`HTTP_TIMEOUT`, 20 s by default) with `-T 15` for
  the network wait, so a hung DNS lookup or server costs one message instead of
  blocking the loop. The `curl` path keeps its `-m 15`.
- **`wifi_off` is read back.** It was the only built in stage action that
  trusted the exit code of `wifi down`. Now the command is sent up to five times
  with 5 s in between (`WIFI_SETTLE`), and the action succeeds only when
  `ubus call network.wireless status` reports no radio up; the way back after a
  reset waits until every radio that is not disabled is up. Checked against the
  real netifd answers of a Banana Pi R3 Mini (`mt_wifi`) and a GL-X3000, kept as
  test fixtures.
- **Time limits for `wifi`, `ifdown`, `ifup` and every hook.** The commands get
  15 s (`CMD_TIMEOUT`), the `notify`, `stage1` and `stage2` hooks 15 s
  (`HOOK_TIMEOUT`), the `modem-temp` hook 5 s. A hook that ignores TERM is killed
  5 s later. Before, a hung command or hook held the whole loop.
- **The config page checks what the daemon will use.** The order of the
  thresholds is checked against the values in the form, not the saved ones,
  and an empty field counts as the daemon's default; before, `cpu_warn` 85 with
  `cpu_crit` left empty passed and made the daemon fall back to all defaults.
  A threshold like `85abc` is refused. `interval` takes whole numbers of 5 and
  more only. `fan_governor` is a list of the four governors the daemon accepts.
- **`fan_governor` only takes a kernel governor that regulates:**
  `step_wise`, `fair_share`, `bang_bang` or `power_allocator`. Before, any
  string went to the zone's `policy` on reset, `user_space` included, which
  leaves nothing regulating the fan. Anything else now means `step_wise` and is
  logged once.
- **Syslog lines carry a priority** instead of the default `user.notice`:
  `daemon.crit` for stages, restored stages, a stage that cannot be persisted
  and failed stage actions (also a modem or interface that does not come back
  after a reset), `daemon.warning` for rejected options, missing tools, a
  sensor that does not read and trips that could not be written,
  `daemon.notice` for cooled down, reset, `trips-keep` and new firmware trips
  that need a decision, `daemon.info` for the rest. The `blind:` message for a
  CPU sensor that stops reading ran through the stage 0 path and would have
  been `crit`; it is a `warning` and is still notified. The event log format
  is unchanged.
- **netifd's answers are read with `jsonfilter`** instead of `sed` and `awk` on
  the text of `ubus` output, which depended on its indentation. Every `ubus
  call` has a time limit of 5 s (`UBUS_TIMEOUT`): netifd answers late while
  `wifi down` runs, and the readback must not hang on exactly what it checks.
  A radio counts as enabled unless netifd reports it `disabled`; the Wi-Fi log
  line counts only those. `jsonfilter` is now in `DEPENDS`; `base-files`
  already pulls it into every image.
- **The configuration is read with one `config_load` per cycle** instead of
  one `uci -q get` per option, about 40 processes every 20 s. The checks on
  the values are unchanged.
- **The detected fan pwm output is logged once as `fan pwm output detected at
  '...'`.** Before it read `fan pwm path '' unusable`, although nothing was
  configured. A configured `pwm_path` that stopped working is still reported
  as unusable, once per replacement.

### Fixed

- **Four help texts on the config page say what the service does** (English
  and German): `fan_governor` applies only when no earlier control mode was
  recorded; `hold_minutes` starts stage 2 of 3 when the temperature has not
  dropped and stage 3 of 3 only while it still rises; the `zone_path` reason
  names the fan's zone, which is no longer configured; `uplink_interface`
  decides whether a message goes out or is queued, not whether the modem is
  switched off, and is the default for the interface action.

- **README, hooks README and the comments in `/etc/config/thermal-guard`
  describe what the code does**: which stage actions can keep a connection
  off after a reboot, what a pwm reset writes back, when `test` shows the
  escalation over time, what a missing hook means per hook, what
  `fan_cooling_device_type` is used for, and that `fan_governor` applies only
  when no earlier governor was recorded.

- **`thermal-guard test` reports the fan mode the daemon would use.** It took
  `fan_mode` as configured, so `auto` without a cooling device or `pwm`
  without `pwm_full` and `pwm_idle` claimed "forcing fan to full speed", while
  the daemon leaves the fan alone in both cases. It now runs the same fan
  detection, which only reads sysfs.

- **A `cpu_temp_path` set in its `/sys/devices` form no longer shows the
  processor among the other sensors.** Paths were compared as written, and
  the sensor loops walk the `/sys/class` links. Such a path is now resolved
  and compared resolved; the default and detected paths are in class form and
  cost nothing extra.

- **`... cannot send a header` is logged once per fetcher.** Without `curl` it
  came with every message and with every retry of the outbox, two minutes
  apart. It is said again when the header was empty in between or another
  fetcher takes over, and forgotten once `curl` is there.

- **Trip messages are said once each.** They shared one memory, which every
  successful trip write cleared, so `device tree trips are now ...` came back
  after each change of the trips. Each message now has its own, cleared when
  its cause is gone: the zone found, `trip_active` valid again, the firmware
  trips recorded, a write that worked.

- **The 1.2.0 entry on notifications overstated the config file.** Only `curl`
  reads `notify_url` and `notify_header` from a file; `uclient-fetch` and
  `wget` take the address on their command line. Since this release such an
  address is refused when it carries a query string or user info (see
  Changed).

- **`at_lock` is checked where it is used, not only when the configuration
  loads.** 1.2.0 said every UCI path is checked again at its use site; for
  `at_lock` that was not so, `tg_at` handed it to `flock` as it was. Now a path
  the guard refuses falls back to `/var/lock/modem-at.lock` there as well.

- **The processor no longer shows up among the other sensors under another
  name.** It was left out only when its sensor was called `cpu_thermal`. A
  processor zone with another type, or a hwmon input such as `coretemp`, was
  listed a second time. Now its own sensor is skipped by path, and where it is
  a thermal zone, the hwmon node the kernel mirrors it as is skipped by the
  zone's type. The other inputs of the same chip stay listed.

- **A `modem-temp` hook stopped at its time limit gives no reading.** Its
  output was used whatever the exit status, so a hook that printed a value
  and then hung still counted. Now the output is dropped when `timeout`
  reports the limit (124) or the hook died of a signal (above 128: the KILL
  for a hook that ignored TERM, or a BusyBox `timeout`, which reports 143),
  as the hooks README already said.

- **A reading missing at stage entry no longer counts as 0.** The reference
  for "no drop" and "still climbing" was stored as 0 when that reading was
  missing, and a state file from before the references existed loaded them as
  0. Any later reading then counted as a rise, and stage 3 of 3 could start
  without one. A missing reference now stays empty, the comparison counts only
  channels with a reading and a reference, and the first reading after the gap
  becomes the reference, so the channel compares again as "risen since it came
  back".

- **`thermal-guard test` shows what the readings would trigger, and only on
  stdout.** It ran one cycle, while every stage needs two readings in a row, so
  it never showed a stage. What it could do was write a `cooled down` line
  (notice) into syslog and the event log when a stage was active. Now it runs
  two cycles at the same moment and prints each message it would send as
  `would notify (<priority>): ...`; syslog, the event log and the outbox stay
  untouched.

- **Without `ip`, messages were never delivered from stage 2 of 3 on.** The
  uplink check found no route, so every message went to the outbox, and the
  outbox waited for a route it could never see. Nothing was logged. Now a
  missing `ip` means the uplink is unknown and the message goes out at once,
  with `no ip command, cannot tell whether another uplink exists, sending at
  once` logged once as a warning. A missing `flock` is logged once as well
  (`no flock command, AT queries run without the shared lock`); the queries
  still run.

- **A stage restored after a reboot reports an action that fails.** The
  restore reapplied the stage actions without looking at the result, so a
  modem that stayed on or Wi-Fi that stayed up went unreported. Now each
  failure is logged as crit (`stage N action '...' failed after the reboot`),
  and the one restore message, sent after the actions, names what failed. The
  event log gets `restoring stage N after a reboot` before the actions start,
  so a daemon that dies halfway leaves a trace.
- **Handing a pwm fan back is read back.** Reset wrote the saved mode and duty
  cycle without checking them. Both are read back now and a mismatch is logged
  as crit. In automatic mode the duty cycle is no longer written at all: the
  chip sets it itself, the value from before the takeover means nothing there,
  and some drivers refuse it.

- **The status page no longer says a board without a sensor takes no action.**
  The note read "The service stays idle and takes no action", while the modem
  thresholds keep working as long as the modem reports a temperature. It now
  says that the processor is not watched and the modem thresholds still apply
  (English and German).

- **`wifi_off` no longer counts as done when netifd manages no radio.** An
  empty `network.wireless` status used to confirm the action: nothing was up,
  because nothing was there, and the stage reported Wi-Fi off on a device whose
  radios netifd does not see. Now the action fails (`netifd manages no Wi-Fi
  radio, wifi_off switched nothing off`, crit) and is notified like any failed
  action. Bringing Wi-Fi back after a reset still passes, there is nothing to
  bring back. The daemon also warns once when it loads a configuration that
  uses `wifi_off` on such a device, so the mistake shows before the box runs
  hot; a ubus error there is left to the action.

- **`thermal-guard selftest` says why it stops** when it cannot create its
  scratch directory, instead of ending with 1 and no word. The
  `cooling-levels` case skips on a host without `hexdump` rather than failing.

- **Handing the zone back on reset is checked.** `tg_fan_release` wrote the
  governor to the zone's `policy` without reading it back. A governor the
  kernel was built without, such as `power_allocator` on the Filogic kernel,
  was refused by the kernel, and the zone stayed on `user_space` with the fan
  at full speed and nobody told. Now a governor missing from
  `available_policies` becomes `step_wise` (logged as warning), and a zone that
  still reports another policy afterwards is logged as crit.

- **A deleted option kept its last value until the daemon restarted.**
  Removing `notify_url` went on sending notifications, removing a threshold
  kept the old threshold. Every option now returns to its default within one
  cycle.

- **A persisted stage could be lost to a power cut, and a failed persist went
  unnoticed.** Writing `/etc/thermal-guard/state` on a stage change and removing
  it on reset now end with `sync`. A persist that cannot be written, for example
  on a full or read only overlay, is logged once (`could not persist stage N to
  ..., it will not survive a reboot`) instead of being treated as done. The
  per cycle path writes only to `/var/run` and does not sync.

## 1.5.0

### Added

- **Wi-Fi temperatures with the proprietary MediaTek driver.** `mt_wifi`, used
  by the MTK vendor images of the Banana Pi R3 Mini, registers no hwmon sensor,
  so the status page showed no Wi-Fi readings although the LuCI overview did.
  The extra sensors now also read `CurrentTemperature` from
  `iwpriv <interface> stat` for `ra0`, `rax0` and the other `mt_wifi`
  interfaces, only while they are up and bounded by `timeout`, the same way
  ImmortalWrt's `autocore` does it. Shown as Wi-Fi 1, Wi-Fi 2, for display only.

## 1.4.0

Where the kernel drives the fan, thermal-guard can now lower its trip points
for a hot modem instead of competing with it. Package release `1.4.0-r2`,
deployed and checked on the GL-X3000 and both Banana Pi R3 Mini.

### Added

- **Trip management (`trip_boost`, `trip_active`, `trip_boost_offset`,
  `trip_dt`).** With `trip_boost 'modem'` the daemon lowers the active trips of
  the thermal zone that drives the fan by `(modem - offset) - cpu`, rounded up
  to 5 K and capped at 40 K, so the kernel regulator spins the fan up for a hot
  modem it cannot see. Trips only ever go below the baseline, `hot` and
  `critical` are never written, a missing reading holds the trips and raising
  them needs three cool readings in a row. Stopping the daemon leaves them where
  they are. Nothing is written unless `trip_boost` or `trip_active` is set, so
  boards with a kernel-driven fan such as the GL-X3000 keep their trips. New
  module `/usr/share/thermal-guard/trips.sh`, selftest cases against a planted
  sysfs tree.
- **`THERMAL_ROOT`** environment variable, default `/sys/class/thermal`, for
  tests only. UCI cannot change it.
- **`/var/run/thermal-guard/modem-temp`**: one line `<degrees> <unix time>
  <source>`, written atomically after every good modem reading. Other programs
  read the value here instead of querying the modem over AT themselves. A
  missing reading leaves the file alone, so its age shows the outage.
- Deployment findings for 1.2.0 on real hardware, one section per device,
  taken into the development repository unchanged.

### Changed

- **AT queries have a time limit.** `timeout 10 flock <lock> timeout 5
  sms_tool …`: the outer limit covers the wait for the lock, which BusyBox
  `flock` cannot bound itself, the inner one the query. Before, a hung modem or
  a program sitting on the lock stopped the whole loop, stages and trip
  management included. A timeout counts as a missing reading. New dependency
  `coreutils-timeout`; the selftest fails where `timeout` is missing.
- **Web interface.** System → Thermal Guard, tab Fan: `trip_boost`, the
  modem allowance and the switching temperatures (`trip_active`, checked with
  the same rules as the service), the state of the trip management, the
  `cooling-levels` from the device tree with their duty cycle, and after an
  image with other device tree trips a notice with "use the firmware values" and
  "keep my values". The status page shows the current trips and by how much
  they are lowered. 31 new strings, German catalogue complete.
- Status file: `trip_state`, `trip_reason` (a fixed code the page translates),
  `trip_zone`, `trip_base`, `trip_now`, `trip_dt`, `trip_delta`,
  `trip_dt_changed`, `trip_limit`, `fan_levels`.
- Docs: README covers trip management, `modem-temp` and the dependency.
  The internal deployment documents follow the new layout of the build
  repositories.
- `luci-app-thermal-guard` 1.4.0, same number as the daemon.
- **`/lib/upgrade/keep.d/thermal-guard`** keeps `/etc/thermal-guard/` across a
  `sysupgrade`. Before, only `/etc/config/thermal-guard` survived: the hooks
  an operator placed over ssh, `matrix.env` for `matrix-notify`, and the
  persisted stages were lost with every flash. Stages persisted at the time of
  a flash now come back after it, the same as after a reboot; clear them before
  flashing if the cause is fixed.
- The shipped configuration leaves `trip_boost` unset, which means off. An
  image can then switch it on for its board at first boot with a uci-defaults
  script that only sets missing options, without overriding an own setting.
- Integration tests for trip management, the hung modem and the held lock run
  the daemon against a planted sysfs tree. The suite now takes about two
  minutes.
- README: why this package exists, and screenshots of the status page, the
  overview block and the configuration tabs on a Banana Pi R3 Mini and a
  GL-X3000, in `screenshots/`.
- CI installs shellcheck 0.11.0 from its release, checked against a pinned
  SHA256, instead of the Ubuntu package. Ubuntu 24.04 ships 0.9.0, which does
  not know the busybox dialect, so the lint job failed on its first run on
  GitHub without looking at a single line.

### Fixed

- **A package upgrade left the old daemon running.** procd keeps an instance
  whose command line did not change, and `thermal-guard daemon` never does, so
  after `apk add` the previous version went on running while `thermal-guard -V`
  already showed the new one. Found on the GL-X3000 with 1.4.0-r1. The package
  now restarts the service after an upgrade on a running system, only if it was
  running. Package release `1.4.0-r2`.

## 1.3.2

### Fixed

- **`thermal-guard selftest` failed on boards with a fan chip.** The case
  "nothing to read, nothing shown" assumed no hwmon fan exists; on the GL-X3000
  the real `pwm-fan` is found by name and read, which is correct. The case now
  runs only where no fan chip is present.

## 1.3.1

### Fixed

- **`thermal-guard selftest` worked in the live state directory.** It saved
  test stages into `/var/run/thermal-guard/state` under a running daemon, which
  then saw a changed `GEN` and dropped its decision ("reset during this
  cycle"), placed test hooks there, and wrote its test messages to syslog. The
  1.3.0 cases also emptied the event log, the incident history the status page
  shows. The deployment runbook runs the selftest on every board. It now works
  in a temporary directory and logs nothing. Found on the GL-MT300N-V2 right
  after installing 1.3.0.

## 1.3.0

The daemon no longer touches a fan it has not been told about. Found in the
first buildroot build: a package install starts the service at once, and on a
board without a configuration the shipped `auto` could resolve to `pwm` with an
assumed polarity of `255`/`0`, which on an inverted board stops the fan in the
stage meant to force it.

### Changed

- **`fan_mode` defaults to `none`**, in the shipped configuration and in the
  daemon when the option is missing. Most boards with a fan already regulate it,
  and this package is a protection layer, not a regulator.
- **`pwm_full` and `pwm_idle` have no default.** `fan_mode=pwm` needs both; with
  either missing the daemon logs it once and leaves the fan alone. The
  configuration page requires both when `pwm` is selected.
- **`auto` never resolves to `pwm`**, only to `cooling_device` or `none`. The
  cooling device carries its polarity in the device tree; a raw pwm output
  needs it from the operator.
- An upgrade keeps the existing configuration. Affected is only a board that set
  `auto` without a cooling device, or `pwm` without both values; the deployment
  runbook lists the cases.

### Added

- **Stage actions are read back instead of assumed.** `modem_radio_off` asks the
  modem `AT+CFUN?` afterwards and resends up to three times, because a
  collision on the AT port swallows a command without an error. A modem that
  does not confirm fails the stage, which is notified. Switching it back on at
  a reset is checked the same way.
- **`modem_radio_off_at`**: `AT+CFUN=4` (flight mode, default) or `AT+CFUN=0`
  (minimum function) for a modem that does not take 4. Nothing else is
  accepted, because the configuration page can write every option and a free
  AT command would let it reset or disable the modem.
- **`interface_down` as a stage action.** Takes `action_interface` down, or
  `uplink_interface` when that is unset, and waits for netifd to report it
  down. A reset brings it back up. Interface names are checked as UCI section
  names, in the daemon and on the page, since they reach `ifdown` and a ubus
  path; `uplink_interface` is now checked the same way.
- **The fan is shown even where another program drives it.** `fan_mode` says
  what the daemon may write, the new `fan_view` in the status file what it
  reads. Under `none` it reads the raw pwm output where `pwm_full` and
  `pwm_idle` are set, otherwise the cooling device, otherwise the raw output
  without a percentage. The raw output comes first because the kernel derives
  a cooling device's `cur_state` assuming ascending `cooling-levels`; the Banana
  Pi R3 Mini's descend (`<255 96 0>`), so full speed reads as state 0. The status
  page and the overview show the fan whenever `fan_view` names something.

### Fixed

- **A reset only undid `modem_radio_off` at stage 2 of 3 and `wifi_off` at
  stage 3**, so either action configured for the other stage stayed applied
  after a clear. Each stage's configured action is now reversed.
- **The overview block showed a pwm fan as "fan step 140 of 1"** on an inverted
  board, because it used the raw value against `pwm_full` as the maximum. It
  now shows the percentage the daemon computes, and `fan_max` is only reported
  for pwm when both polarity values are set.
- **Stage 1 of 3 promised a fan at full speed under `fan_mode=none`**, in the
  notification, on the status page and in two descriptions on the configuration
  page, and logged "could not force the fan" as if the stage had failed. It now
  says the fan is left to its own controller and logs nothing about it.

### Translations

- German: new `Leave the fan alone` (replaces `No fan`) and `Stage 1 of 3 active:
  warning, fan left to its own controller`; reworded the descriptions of the fan
  mode, `pwm_full`, `pwm_idle`, `cpu_warn` and the Actions tab.
- German: `Switch the modem radio off` (replaces `Switch the modem off
  (AT+CFUN=4)`, since the level is now configurable), and new `Take a network
  interface down`, `network interface down`, `How the modem is switched off`
  with its description, `Flight mode (AT+CFUN=4)`, `Minimum function
  (AT+CFUN=0)`, `Interface to take down` with its description.

## 1.2.0

Hardening pass over the whole package, plus the corrections that came out of
testing on a Banana Pi R3 Mini, a GL-X3000 and a GL-MT300N-V2.

### Fixed

- **One-shot commands narrated the configuration into the event log.** Every
  entry point runs the same validation, so `status`, `reset` and `test` each
  repeated whatever it found: three `thermal-guard status` calls on a board
  without a sensor produced three identical lines. The event log keeps the last
  50 entries, so a monitoring check calling `status` in a loop flushed the
  record of an actual incident out of it within the hour. Only the daemon
  reports these now. Found during deployment on a GL-MT300N-V2.
- **A reset could be undone by the cycle it interrupted.** Reading the modem
  over AT takes seconds, and a reset landing in that window was overwritten
  when the cycle saved. In the worst shape the fan was forced again right after
  being handed back, leaving it at full speed while the state said idle, with
  no way to clear it: the release was guarded by `stage >= 0`. Resets are now
  counted in `GEN` and the count is checked before acting and before saving,
  and `thermal-guard reset` releases the fan unconditionally.
- **Turning `enabled` off removed the guard instead of pausing it.**
  `start_service` registered no instance, so stages stayed applied, the fan
  stayed forced and the status file froze with its last values while the page
  kept showing an active stage. The instance now always runs and the daemon
  pauses itself.
- **The fan was addressed by hwmon number.** `hwmon2` today is `hwmon1` after
  an NVMe moves or a kernel changes, and the daemon would then write a duty
  cycle to a different chip and report success. The fan chip is looked up by
  its hwmon name.
- **`tg_fan_release` did nothing in pwm mode** unless `fan_release_command` was
  set, so the fan stayed on manual full speed after a reset.
- **A failing stage action reported success.** `tg_run_action` ended in an
  unconditional `return 0`, so a modem that could not be reached still counted
  as switched off. It now returns what the action returned, an unknown action
  name is logged, and a failed stage is notified.
- **`tg_cfg` skipped path validation and sensor detection** entirely when `uci`
  was absent.
- CI checked `70_thermal-guard.js`, which was renamed to `11_` some releases
  ago, so the `luci-syntax` job had been failing on a missing file.
- The rpcd ACL named the status file and the reset command but not the ubus
  `file` object they are reached through, nor the `/tmp/run` path that `/var`
  resolves to. Both reads and the clear button were denied for every session
  that was not root.
- **Installing `luci-app-thermal-guard` as a package did not load its ACL**
  (`1.2.0-r2`). The package's own `postinst` replaced the one `luci.mk`
  provides, which is the one that reloads rpcd, so the pages were refused until
  rpcd restarted. The own `postinst` is gone; the default drops the menu caches
  as well. Found in the first buildroot build of either package.

### Added

- **Protection stages survive a reboot.** A stage change is mirrored to
  `/etc/thermal-guard/state` and reapplied at startup. The state used to live
  only in `/var/run`, which is tmpfs, so any reboot silently cleared the
  stages and the box came back with the modem enabled and the same broken fan.
- **`pwm_idle`**, the raw value meaning slowest, as the counterpart to
  `pwm_full`. The pair carries the polarity, which several boards run inverted
  (`1` full speed, `255` stopped). The fan percentage on the status page is
  computed from it instead of assuming a rising scale.
- **A SoC sensor is looked for** when `cpu_temp_path` does not read, covering
  ramips and x86 boards that report through hwmon rather than a thermal zone.
- **"This device reports no temperature at all"** as a state of its own, told
  apart from a wrong path and shown on the status page. Some boards, the
  GL-MT300N-V2 among them, expose no sensor whatsoever.
- **A second fan controller is detected.** When a value the daemon wrote has
  been replaced, it logs which `fan_mode` avoids the fight, reasserts and
  reports it to the page.
- The status file carries `now`, `interval`, `enabled`, `no_sensor`,
  `fan_percent`, `fan_foreign` and `cpu_src`, which lets the page tell running,
  paused and stopped apart instead of showing a stale snapshot as current.
- `tests/run-integration.sh`, exercising reset, the reboot restore, a garbled
  state file and the collectd filter through the real scripts.

### Changed

- **Notifications go out over HTTP.** `notify_url` is posted to with `curl`
  where present and `uclient-fetch` otherwise; `notify_header` carries an
  authorisation token where `curl` is installed. Both go through a config file
  rather than the command line, because `/proc/*/cmdline` is readable by every
  local process, and both are rejected if they contain anything that could
  turn that config file into further directives.
- **Custom code lives in `/etc/thermal-guard/hooks/`** as executables, not in
  UCI as strings. The rpcd ACL grants write access to every option in this
  configuration, so a shell command stored there was a way for anyone who
  could reach the configuration page to run code as root. `sh -c` no longer
  appears in the package at all.
- Paths taken from UCI are checked against the subtree they belong to, in
  `tg_cfg` and again at each use site, and the config view validates the same
  prefixes.
- `thermal-guard-collectd` passes status values through an integer filter
  before building a `PUTVAL` line.
- A cooling device that no thermal zone binds is usable; the zone is only
  needed to take the device away from a governor. `cooling_device` is preferred
  where available because `max_state` means maximum cooling whichever way the
  device tree runs its `cooling-levels`, so that mode cannot get the polarity
  wrong.
- Reload is a no-op. `tg_cfg` runs every cycle, so a changed option is live
  within one interval, and restarting would drop a stage action in flight.
- The stage banner names the configured action instead of the default, so a
  box with `stage1_action=wifi_off` no longer claims the modem was switched
  off.
- German catalogue regenerated: 124 entries, 34 of them new, 11 stale ones
  removed.

### Documented

- **What this package is for.** It is a protection layer, not a fan controller,
  and where a board already has one `fan_mode=none` is the normal setting
  rather than a workaround. The built-in fan handling is for boards with
  nothing else.
- **Sharing the modem's AT port.** Overlapping AT queries return nothing
  useful and neither side reports a fault. Deploying next to a fan controller
  that queried the modem without a lock garbled that controller's reading,
  collapsed its control temperature and left the fan at its minimum on a board
  at 68 °C. The symptom was at the fan, the cause at the serial port.
- **`fan_mode=pwm` is not a regulator**, now a warning in the deployment
  runbook. Below the thresholds it writes nothing to the fan. Pausing the Banana
  Pi's `fan-control` in favour of it left `pwm1` at a stale minimum while the
  SoC climbed from 58 to 68 °C.
- **Deployment runbook, gaps found on hardware.** Check for an installed
  package (`apk info -e` / `opkg status`) and remove it through the package
  manager before deleting files by hand; the Banana Pi carried 1.1.0 as apk
  packages. The migration now lists the options this repository removed in
  1.2.0 (`notify_command` and the other `*_command` options) with their
  replacements, not only the BananaWRT variant's. `pwm_idle='255'` is set on
  the Banana Pi, and the runbook separates what a missing value does:
  `fan_percent` pinned at 100 % under `fan_mode=pwm`, empty under
  `fan_mode=none`.
- **Whether there is a kernel backstop at all.** Preferring `cooling_device`
  used to be justified by the kernel continuing to regulate while the guard is
  idle. That only holds where a thermal zone actually binds the cooling device,
  which several boards do not do, and the README now says how to check.

### Removed

- `notify_command`, `stage1_command`, `stage2_command`, `modem_temp_command`
  and `fan_release_command`. The first is replaced by `notify_url`, the next
  three by hooks of the same name, and the last by recording what the pwm chip
  was set to before the takeover and writing it back on release.

## 1.1.0

- Configuration page under System, clear button on the status page
- Other board temperature sensors reported alongside SoC and modem
- Fan mode no longer reset to `auto` on every cycle

## 1.0.0

- Staged overheating protection: force the fan, modem radio off, Wi-Fi off
- Status page, overview block and collectd feed
