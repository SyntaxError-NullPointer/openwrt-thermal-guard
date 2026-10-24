#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Runs the shipped script as a process against a planted state directory.
# The selftest covers the logic in memory, this covers what ends up on disk.
# shellcheck shell=busybox

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
# set -e ends the suite at the first command that fails outside a check. Say
# so, with the last check that ran, instead of stopping without a word.
finished=0; last="none yet"
suite_exit() { # $1 exit status
	[ "$finished" = 1 ] || echo "FAIL the suite stopped early, the last check was: $last"
	rm -rf "$tmp"
	exit "$1"
}
trap 'suite_exit $?' EXIT
# Under busybox sh, "sh" is busybox sh for everything the suite starts: on a
# host where sh is bash, the daemon would otherwise never run under ash.
self=$(readlink "/proc/$$/exe")
if [ "${self##*/}" = busybox ]; then
	mkdir -p "$tmp/ash"; ln -s "$self" "$tmp/ash/sh"
	PATH="$tmp/ash:$PATH"; export PATH
fi

BIN="$root/thermal-guard/files/usr/sbin/thermal-guard"
LIB_DIR="$root/thermal-guard/files/usr/share/thermal-guard"
STATE_DIR="$tmp/state"
STATUS_FILE="$tmp/status"
PERSIST_DIR="$tmp/persist"
HOOK_DIR="$tmp/hooks"
export LIB_DIR STATE_DIR STATUS_FILE PERSIST_DIR HOOK_DIR

# Every daemon run logs through this stand-in, never the host's syslog. It
# records the arguments, and fails on demand while logger.fail exists.
cat > "$tmp/logger" <<LOGGER_END
#!/bin/sh
[ -e "$tmp/logger.fail" ] && exit 1
echo "\$*" >> "$tmp/syslog"
LOGGER_END
chmod 0755 "$tmp/logger"
export TG_LOGGER="$tmp/logger"
# A real sync flushes the whole host and can take seconds, long enough for a
# bounded daemon run to end before its state is saved. Every run with
# $tmp/bin on PATH gets this one; the cases about flushing bring their own.
sync_standin() {
	mkdir -p "$tmp/bin"
	printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/sync"
	chmod 0755 "$tmp/bin/sync"
}
sync_standin
# Every run sees this boot id, and fan device links resolve under this tree.
BOOT_ID_FILE="$tmp/boot_id"; DEVICES_ROOT="$(cd "$tmp" && pwd -P)/devices"
export BOOT_ID_FILE DEVICES_ROOT
BOOT1=4f0c9d1e-6a2b-4c3d-8e5f-0a1b2c3d4e5f; BOOT0=00000000-1111-2222-3333-444444444444
echo "$BOOT1" > "$BOOT_ID_FILE"
prio() { # $1 start of a message, prints the priority it went out with
	sed -n "s/^-t thermal-guard -p \(daemon\.[a-z]*\) $1.*/\1/p" "$tmp/syslog" | head -n1
}

fail=0
chk() { # $1 label, $2 got, $3 expected
	last=$1
	if [ "$2" = "$3" ]; then
		echo "ok   $1"
	else
		echo "FAIL $1: expected [$3], got [$2]"
		fail=1
	fi
}

# The daemon is started as "sh", which must be the shell the suite runs
# under: on a host where sh is bash, busybox sh would test only the suite.
# shellcheck disable=SC2016 # expanded by the inner shell
chk "the daemon runs under the shell the suite runs under" \
	"$(sh -c 'readlink /proc/$$/exe; :')" "$(readlink "/proc/$$/exe")"

field() { # $1 file, $2 key
	sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n1
}

# A case that reads the status file first proves the file is from its own
# run: fresh_status before the run, sfield after it, which says "stale" for a
# file left over from an earlier case.
fresh_status() {
	rm -f "$STATUS_FILE"; status_t0=$(date +%s)
}
sfield() { # $1 key
	local now
	now=$(field "$STATUS_FILE" now)
	if [ -n "$now" ] && [ "$now" -ge "$status_t0" ]; then
		field "$STATUS_FILE" "$1"
	else
		echo stale
	fi
}
# How many daemons have started on this event log, to show one was running.
started() {
	cat "$STATE_DIR/log" 2>/dev/null | grep -c 'started, version' || true
}
# A cool planted zone for the daemon runs before the trip section plants its
# own tree, so they do not depend on the host's temperature.
COOL="$tmp/cool"
mkdir -p "$COOL/thermal_zone0"; echo 40000 > "$COOL/thermal_zone0/temp"

plant_stage1() {
	mkdir -p "$STATE_DIR"
	cat > "$STATE_DIR/state" <<'EOF'
STAGE=1
T0=1000
T1=1100
T2=0
REF_CPU0=72
REF_MODEM0=0
REF_CPU1=73
REF_MODEM1=0
PENDING=-1
PENDING_N=0
COOLED=0
ACTION1=none
LAST_CPU=73
LAST_MODEM=
LAST_MODEM_SRC=
LAST_TS=1100
GEN=3
EOF
}

# ---- reset clears the stage and bumps the generation ----------------------
plant_stage1
: > "$tmp/syslog"; fresh_status
sh "$BIN" reset >/dev/null 2>&1

chk "reset clears the stage" "$(field "$STATE_DIR/state" STAGE)" "-1"
chk "reset goes to syslog as daemon.notice" "$(prio 'reset requested')" "daemon.notice"
chk "reset bumps GEN" "$(field "$STATE_DIR/state" GEN)" "4"
chk "reset refreshes the status file" "$(sfield stage)" "-1"

# ---- a plain cycle leaves the generation alone ----------------------------
# A daemon cycle, not a dry run: only a real cycle saves the state.
fresh_status
THERMAL_ROOT="$COOL" timeout 3 sh "$BIN" daemon >/dev/null 2>&1 || true
chk "a daemon cycle ran and saved the state" \
	"$(sfield stage)/$([ "$(field "$STATE_DIR/state" LAST_TS)" -ge "$status_t0" ] 2>/dev/null &&
		echo saved || echo not)" "-1/saved"
chk "a cycle does not touch GEN" "$(field "$STATE_DIR/state" GEN)" "4"

# ---- reset is idempotent, and safe on a state that is already clear -------
sh "$BIN" reset >/dev/null 2>&1
chk "second reset bumps GEN again" "$(field "$STATE_DIR/state" GEN)" "5"
chk "second reset keeps the stage clear" "$(field "$STATE_DIR/state" STAGE)" "-1"

# ---- the status file carries what the UI needs to spot a dead service -----
# Written by a daemon cycle; a dry run does not write it.
fresh_status
THERMAL_ROOT="$COOL" timeout 3 sh "$BIN" daemon >/dev/null 2>&1 || true
chk "status reports the enabled flag" "$(sfield enabled)" "1"
# The value depends on the machine running the tests, the field must be there
# either way because the web interface branches on it.
case "$(sfield no_sensor)" in
	0|1) chk "status reports whether a sensor exists" present present ;;
	*)   chk "status reports whether a sensor exists" missing present ;;
esac
case "$(sfield fan_view)" in
	none|pwm|cooling_device) chk "status reports what the fan is read from" present present ;;
	*)                       chk "status reports what the fan is read from" missing present ;;
esac
chk "status reports the interval" "$(sfield interval)" "20"
# The page tells a reboot by it while the new boot has no request record yet.
chk "status names this boot" "$(sfield boot_id)" "$BOOT1"
written=$(field "$STATUS_FILE" now)
now=$(date +%s)
if [ -n "$written" ] && [ $((now - written)) -lt 60 ]; then
	chk "status is stamped with the write time" fresh fresh
else
	chk "status is stamped with the write time" "stale($written)" fresh
fi

# ---- a garbled state file must not carry values into the logic ------------
# Checked through "status", which loads the state and prints it without
# writing anything back, so the planted file stays as it is.
mkdir -p "$STATE_DIR"
cat > "$STATE_DIR/state" <<'EOF'
STAGE=1; rm -rf /
GEN=notanumber
LAST_CPU=42
EOF
sh "$BIN" status > "$tmp/status-out" 2>/dev/null
chk "junk stage is dropped" "$(sed -n 's/^stage=//p' "$tmp/status-out")" "-1"
chk "junk GEN falls back to zero" "$(sed -n 's/^gen=//p' "$tmp/status-out")" "0"
chk "junk reading is dropped" "$(sed -n 's/^last_cpu=//p' "$tmp/status-out")" "42"

# ---- one-shot commands stay out of the event log --------------------------
# Every entry point runs the same configuration checks. If a one-shot command
# logs what they find, repeating it repeats the line, and because the event log
# keeps only the last 50 entries a monitoring check calling status in a loop
# flushes out the record of an actual incident.
# A board without any sensor gives such a diagnostic. The daemon logging it
# shows there is something the one-shot commands have to hold back.
rm -rf "$STATE_DIR" "$PERSIST_DIR"
mkdir -p "$STATE_DIR" "$tmp/nosensor"
THERMAL_ROOT="$tmp/nosensor" HWMON_ROOT="$tmp/nosensor" timeout 3 sh "$BIN" daemon >/dev/null 2>&1 || true
chk "the daemon logs the missing sensor" "$(grep -c 'reports no temperature at all' "$STATE_DIR/log")" "1"
printf '2026-01-01 00:00:00 stage 1: modem radio off\n' > "$STATE_DIR/log"

i=0
while [ "$i" -lt 12 ]; do
	THERMAL_ROOT="$tmp/nosensor" HWMON_ROOT="$tmp/nosensor" sh "$BIN" status >/dev/null 2>&1
	THERMAL_ROOT="$tmp/nosensor" HWMON_ROOT="$tmp/nosensor" sh "$BIN" test 40 40 >/dev/null 2>&1
	i=$((i + 1))
done

chk "status and test add nothing to the log" "$(wc -l < "$STATE_DIR/log")" "1"
chk "the incident is still there" "$(grep -c 'stage 1' "$STATE_DIR/log")" "1"

# ---- a dry run changes nothing -------------------------------------------
# First that the stages were reached at all, then that nothing was written:
# "nothing happened" only counts where something could have.
rm -rf "$STATE_DIR" "$PERSIST_DIR"
: > "$tmp/syslog"
out=$(sh "$BIN" test 95 95 2>/dev/null)
chk "a dry run of 95/95 reaches all three stages" \
	"$(printf '%s\n' "$out" | grep -c '^would notify (crit): stage [0-2]: cpu 95 C')" "3"
chk "and ends in stage 2" "$(printf '%s\n' "$out" | sed -n 's/^decision=.* stage=\([-0-9]*\) .*/\1/p')" "2"
chk "it makes no logger call" "$(wc -l < "$tmp/syslog" | tr -d ' ')" "0"
chk "and writes no event log" "$([ -s "$STATE_DIR/log" ] && echo wrote || echo clean)" "clean"
chk "a dry run writes no state" "$([ -f "$STATE_DIR/state" ] && echo wrote || echo clean)" "clean"
chk "a dry run persists nothing" "$([ -f "$PERSIST_DIR/state" ] && echo wrote || echo clean)" "clean"
# Padded readings on the command line are decimals, 075 is not octal 61.
rc=0
out=$(sh "$BIN" test 075 080 2>"$tmp/test.err") || rc=$?
chk "a dry run of 075/080 reads 75 and 80" \
	"$rc/$(wc -l < "$tmp/test.err" | tr -d ' ')/$(printf '%s\n' "$out" |
		grep -c '^would notify (crit): stage 0: cpu 75 C, modem 80 C')" "0/0/1"
chk "and ends in stage 0" "$(printf '%s\n' "$out" | sed -n 's/^decision=.* stage=\([-0-9]*\) .*/\1/p')" "0"
chk "and writes no state" "$([ -f "$STATE_DIR/state" ] && echo wrote || echo clean)" "clean"

# ---- stages survive a reboot ---------------------------------------------
# A reboot empties /var/run but not the overlay. Simulate that by planting a
# persisted stage and removing the working state, the way tmpfs would.
rm -rf "$STATE_DIR" "$PERSIST_DIR"
mkdir -p "$PERSIST_DIR"
cat > "$PERSIST_DIR/state" <<'EOF'
STAGE=1
T0=1000
T1=1100
T2=0
REF_CPU0=72
REF_MODEM0=0
REF_CPU1=73
REF_MODEM1=0
PENDING=-1
PENDING_N=0
COOLED=0
LAST_CPU=73
LAST_MODEM=
LAST_MODEM_SRC=
LAST_TS=1100
FAN_SAVED_ENABLE=2
FAN_SAVED_PWM=90
GEN=3
EOF

# Only the daemon restores, and it does so at startup, so run one briefly.
timeout 5 sh "$BIN" daemon >/dev/null 2>&1 || true
chk "the daemon adopts the persisted stage" "$(field "$STATE_DIR/state" STAGE)" "1"
chk "the restore keeps the saved fan state" "$(field "$STATE_DIR/state" FAN_SAVED_ENABLE)" "2"
if grep -q "restored stage 1 after a reboot" "$STATE_DIR/log" 2>/dev/null; then
	chk "the restore is logged" logged logged
else
	chk "the restore is logged" silent logged
fi

# reset must clear both copies, otherwise the next boot brings the stage back
plant_stage1
sh "$BIN" reset >/dev/null 2>&1
if [ -e "$PERSIST_DIR/state" ]; then
	chk "reset clears the persisted stage" present gone
else
	chk "reset clears the persisted stage" gone gone
fi

# The removal has to reach the flash as well. A stand-in sync counts the call.
# A BusyBox built with FEATURE_SH_STANDALONE runs its own sync applet before
# anything on PATH, so the case is skipped where the stand-in would not run.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho x >> "%s"\n' "$tmp/sync.calls" > "$tmp/bin/sync"
chmod 0755 "$tmp/bin/sync"
if [ "$(PATH="$tmp/bin:$PATH" sh -c 'command -v sync')" = "$tmp/bin/sync" ]; then
	plant_stage1
	mkdir -p "$PERSIST_DIR"; cp "$STATE_DIR/state" "$PERSIST_DIR/state"
	rm -f "$tmp/sync.calls"
	PATH="$tmp/bin:$PATH" sh "$BIN" reset >/dev/null 2>&1
	chk "reset flushes the removal to flash" \
		"$([ -e "$PERSIST_DIR/state" ] && echo present || echo gone)/$({ wc -l < "$tmp/sync.calls"; } 2>/dev/null | tr -d ' ')" \
		"gone/1"
else
	echo "skip reset flushes the removal to flash (sync would be a shell applet here)"
fi
sync_standin

# ---- stage hooks are files, not configuration -----------------------------
# The point of the hook directory is that nothing in UCI can introduce code.
# A stage set to "command" must run the file and must say so when it is absent.
rm -rf "$STATE_DIR" "$PERSIST_DIR" "$HOOK_DIR"
mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/stage1" <<EOF
#!/bin/sh
echo ran > "$tmp/stage1-ran"
EOF
chmod 0755 "$HOOK_DIR/stage1"

# The dry run with a hook as stage action follows once the configuration can
# say "command", below.

# Whether a hook is executed is covered by the selftest, which can call
# tg_run_hook directly. Here it matters only that a dry run stays dry.

# ---- configuration through the stand-in functions.sh -----------------------
# The daemon reads UCI with config_load, which runs /sbin/uci by its full path,
# so tests/functions.sh reads the planted file instead. The uci on PATH only
# has to exist; every call to it is recorded, and the daemon has no business
# calling it. "get" answers from uci.get, for the migration script.
export TG_FUNCTIONS="$root/tests/functions.sh" UCI_CONFIG_DIR="$tmp/config"
mkdir -p "$tmp/bin" "$UCI_CONFIG_DIR"
cat > "$tmp/bin/uci" <<UCI_END
#!/bin/sh
echo "\$*" >> "$tmp/uci.calls"
[ "\$2" = get ] && [ -r "$tmp/uci.get" ] && sed -n "s|^\$3=||p" "$tmp/uci.get"
exit 0
UCI_END
chmod 0755 "$tmp/bin/uci"
# One "option" line per "name=value" argument, a "list" line per "+name=value".
uci_conf() {
	local a
	{
		echo "config thermal-guard 'main'"
		for a in "$@"; do
			case "$a" in
				+*) a=${a#+}; printf "\tlist %s '%s'\n" "${a%%=*}" "${a#*=}" ;;
				*) printf "\toption %s '%s'\n" "${a%%=*}" "${a#*=}" ;;
			esac
		done
	} > "$UCI_CONFIG_DIR/thermal-guard"
	: > "$tmp/uci.calls"
}

# ---- pwm without a polarity leaves the fan alone, and says so once ---------
# pwm with pwm_idle but no pwm_full. The daemon runs three cycles and must
# report it once; a status call must not report it at all.
# ---- a dry run with a hook as stage action does not run it -----------------
# 85 C clears cpu_crit, so the two cycles of test enter stage 1, whose action
# is the stage1 hook planted above.
uci_conf stage1_action=command
out=$(PATH="$tmp/bin:$PATH" sh "$BIN" test 85 40 2>/dev/null)
chk "a dry run reaches the command stage" \
	"$(printf '%s\n' "$out" | grep -c '^would notify (crit): stage 1: .* running command\.$')" "1"
chk "and never touches the hook" "$([ -e "$tmp/stage1-ran" ] && echo ran || echo no)" "no"

# A dry run reports the fan mode the daemon would use: pwm without pwm_full
# leaves the fan alone there, so the dry run must not claim to force it.
uci_conf fan_mode=pwm pwm_idle=255
out=$(PATH="$tmp/bin:$PATH" sh "$BIN" test 75 60 2>/dev/null)
chk "a dry run reaches stage 0 with the fan mode the daemon would use" \
	"$(printf '%s\n' "$out" | grep -c '^would notify (crit): stage 0: .* fan left to its own controller')" "1"

uci_conf fan_mode=pwm pwm_idle=255 interval=5
rm -rf "$STATE_DIR" "$PERSIST_DIR"
PATH="$tmp/bin:$PATH" timeout 12 sh "$BIN" daemon >/dev/null 2>&1 || true
chk "pwm without pwm_full is reported once" \
	"$(grep -c 'needs both pwm_full and pwm_idle' "$STATE_DIR/log" 2>/dev/null)" "1"
chk "pwm without pwm_full runs as none" \
	"$(PATH="$tmp/bin:$PATH" sh "$BIN" status 2>/dev/null | sed -n 's/^fan_mode=//p')" "none"
chk "status does not report it again" \
	"$(grep -c 'needs both pwm_full and pwm_idle' "$STATE_DIR/log" 2>/dev/null)" "1"

# ---- selftest leaves the live state alone -----------------------------------
# The runbook runs it on boards whose daemon is running. It must not write the
# working state, the event log or the hook directory of the real installation.
rm -rf "$STATE_DIR" "$HOOK_DIR"
plant_stage1
echo "2026-01-01 00:00:00 an incident worth keeping" > "$STATE_DIR/log"
before=$(cat "$STATE_DIR/state")
# Not under set -e: a failing selftest has to show up as a FAIL line here.
# Its stderr stays empty: under ash a command killed after its time limit
# would make the shell print "Killed", which procd hands to syslog.
if sh "$BIN" selftest >/dev/null 2>"$tmp/selftest.err"; then r=passed; else r=failed; fi
chk "the selftest passes and writes nothing to stderr" "$r/$(cat "$tmp/selftest.err")" "passed/"
# Only tg_timeout runs timeout -k from a shell; the one behind flock is
# waited for by flock.
chk "every time limit runs through tg_timeout" \
	"$(cat "$BIN" "$LIB_DIR"/*.sh | grep -c 'timeout -k')" "2"
chk "selftest leaves the working state alone" "$(cat "$STATE_DIR/state")" "$before"
chk "selftest leaves the event log alone" "$(cat "$STATE_DIR/log")" "2026-01-01 00:00:00 an incident worth keeping"
chk "selftest creates no hooks in the real directories" \
	"$(find "$STATE_DIR/hooks" "$HOOK_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

# ---- trip management, the daemon as a process against a planted tree -------
# The tree mirrors the Banana Pi R3 Mini: critical 125, hot 120, active
# 50/60/70, the pwm-fan bound to trips 2, 3 and 4.
TR="$tmp/thermal"
plant_tree() {
	local z="$TR/thermal_zone0" c="$TR/cooling_device0" i t
	rm -rf "$TR"; mkdir -p "$z" "$c"
	echo pwm-fan > "$c/type"; echo 3 > "$c/max_state"; echo 0 > "$c/cur_state"
	echo step_wise > "$z/policy"; echo 50000 > "$z/temp"; echo cpu-thermal > "$z/type"
	i=0
	for t in critical:125000 hot:120000 active:50000 active:60000 active:70000; do
		echo "${t%%:*}" > "$z/trip_point_${i}_type"
		echo "${t#*:}" > "$z/trip_point_${i}_temp"
		i=$((i + 1))
	done
	for i in 0 1 2; do
		ln -s ../cooling_device0 "$z/cdev$i"
		echo $((i + 2)) > "$z/cdev${i}_trip_point"
	done
}
trips() { cat "$TR"/thermal_zone0/trip_point_[234]_temp | tr '\n' ' '; }
tg_run() { # $1 seconds, the daemon runs until timeout sends TERM
	THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout "$1" sh "$BIN" daemon >/dev/null 2>&1 || true
}
BOOST="trip_boost=modem"
IVL="interval=5"
MFILE="modem_temp_file=$tmp/modem"
MSRC="modem_source=file"

# I1: a hot modem at start lowers the trips in one step
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; echo 90 > "$tmp/modem"
uci_conf "$BOOST" "$IVL" "$MSRC" "$MFILE"
: > "$tmp/syslog"
rc=0
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout 3 sh "$BIN" daemon >/dev/null 2>&1 || rc=$?
chk "a hot modem at start lowers the trips" "$(trips)" "25000 35000 45000 "
chk "in one write, without the baseline in between" "$(grep -c 'trips set to' "$STATE_DIR/log")" "1"
chk "a trip change is daemon.info" "$(prio 'trips set to')" "daemon.info"
# Every event log line reached the logger, and nothing else did: one path.
missing=0
while IFS= read -r l; do
	grep -qF -- "${l#* * }" "$tmp/syslog" || missing=$((missing + 1))
done < "$STATE_DIR/log"
chk "every event log line went to the logger" "$missing" "0"
chk "and the logger got no line besides them" \
	"$(wc -l < "$tmp/syslog" | tr -d ' ')" "$(wc -l < "$STATE_DIR/log" | tr -d ' ')"
# I3: timeout ended that run with TERM, the trips stay where they were. One
# start and timeout's status for TERM show the daemon was running when TERM
# came: coreutils says 124, a BusyBox timeout applet dies of the signal (143).
case "$rc" in 124|143) rc=term ;; esac
chk "the daemon was running when it was stopped" "$rc/$(started)" "term/1"
chk "stopping the daemon leaves the trips down" "$(trips)" "25000 35000 45000 "
# I4: the device tree set of this boot is kept, and nothing goes to UCI
chk "device tree set kept for this boot" "$(cat "$STATE_DIR/trip_dt")" "50000 60000 70000"
chk "without trip_active no trip_base is written" \
	"$([ -e "$PERSIST_DIR/trip_base" ] && echo written || echo none)" "none"
chk "trip management calls uci for nothing" "$(cat "$tmp/uci.calls")" ""

# I2: killed while lowered, restarted with a cool modem: baseline again
n0=$(started)
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
pid=$!
sleep 2
chk "the second daemon was running before kill -9" "$(started)" "$((n0 + 1))"
kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
chk "kill -9 leaves the trips down" "$(trips)" "25000 35000 45000 "
echo 40 > "$tmp/modem"
fresh_status
tg_run 3
chk "a restart with a cool modem restores the baseline" "$(trips)" "50000 60000 70000 "
chk "the restart did not read the lowered trips as device tree" "$(sfield trip_dt)" "50/60/70"

# I10: the first cycle with trip_active records the device tree set, on the
# overlay and not in /etc/config. trip_active as a UCI list, like the page.
TA="+trip_active=45 +trip_active=55 +trip_active=65"
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree
# shellcheck disable=SC2086 # TA holds three arguments
uci_conf "$BOOST" "$IVL" "$MSRC" "$MFILE" $TA
conf_before=$(md5sum < "$UCI_CONFIG_DIR/thermal-guard")
tg_run 3
chk "the first cycle with trip_active records trip_base" \
	"$(cat "$PERSIST_DIR/trip_base")" "50 60 70"
chk "and leaves the configuration file alone" \
	"$(md5sum < "$UCI_CONFIG_DIR/thermal-guard")" "$conf_before"
chk "and calls uci for nothing" "$(cat "$tmp/uci.calls")" ""

# I5: a new image with other device tree values, the operator's baseline stays
rm -rf "$STATE_DIR"; plant_tree; echo 75000 > "$TR/thermal_zone0/trip_point_4_temp"
: > "$tmp/syslog"; fresh_status
tg_run 3
chk "a changed device tree is reported" "$(sfield trip_dt_changed)" "1"
chk "at daemon.notice" "$(prio 'device tree trips are now')" "daemon.notice"
chk "and trip_active stays the baseline" "$(trips)" "45000 55000 65000 "
chk "trip_base is left alone" "$(cat "$PERSIST_DIR/trip_base")" "50 60 70"
# The page runs trips-keep once the operator has decided.
chk "trips-keep succeeds" "$(sh "$BIN" trips-keep >/dev/null 2>&1; echo $?)" "0"
chk "and records the set of this boot" "$(cat "$PERSIST_DIR/trip_base")" "50 60 75"
fresh_status
tg_run 3
chk "after that no change is reported" "$(sfield trip_dt_changed)" "0"

# I11: the package moves trip_dt out of UCI once, on install or first boot
MIG="$root/thermal-guard/files/etc/uci-defaults/90-thermal-guard-trip-base"
mig() { # $1 trip_dt as uci -q get prints it, empty for none
	if [ -n "$1" ]; then echo "thermal-guard.main.trip_dt=$1"; fi > "$tmp/uci.get"
	: > "$tmp/uci.calls"
	PATH="$tmp/bin:$PATH" sh "$MIG" >/dev/null 2>&1
	echo "rc=$?"
}
uci_removed() {
	grep -c -e '^-q delete thermal-guard.main.trip_dt$' -e '^-q commit thermal-guard$' \
		"$tmp/uci.calls"
}
rm -rf "$PERSIST_DIR"
chk "the migration exits 0" "$(mig '50 60 70')" "rc=0"
chk "and moves trip_dt to trip_base" "$(cat "$PERSIST_DIR/trip_base")" "50 60 70"
chk "and removes it from UCI" "$(uci_removed)" "2"
chk "a second run exits 0" "$(mig '')" "rc=0"
chk "after asking UCI for trip_dt" "$(grep -c '^-q get thermal-guard.main.trip_dt$' "$tmp/uci.calls")" "1"
chk "and changes nothing" "$(uci_removed)" "0"
echo "45 55 65" > "$PERSIST_DIR/trip_base"
mig '50 60 70' >/dev/null
chk "an existing trip_base is kept" "$(cat "$PERSIST_DIR/trip_base")" "45 55 65"
chk "and trip_dt removed all the same" "$(uci_removed)" "2"
rm -f "$PERSIST_DIR/trip_base"
mig '50 60;reboot' >/dev/null
chk "a garbled trip_dt is not moved" \
	"$([ -e "$PERSIST_DIR/trip_base" ] && echo moved || echo none)" "none"
chk "only removed" "$(uci_removed)" "2"
: > "$tmp/not-a-dir"
chk "a failed write exits 0 as well" "$(PERSIST_DIR="$tmp/not-a-dir" mig '50 60 70')" "rc=0"
chk "after reading trip_dt" "$(grep -c '^-q get thermal-guard.main.trip_dt$' "$tmp/uci.calls")" "1"
chk "and keeps trip_dt in UCI" "$(uci_removed)" "0"

# I9: nothing configured, nothing written: the GL-X3000 case
rm -rf "$STATE_DIR"; plant_tree; echo 90 > "$tmp/modem"
before=$(find "$TR" -name 'trip_point_*' -exec cat {} \; | md5sum)
uci_conf "$IVL" "$MSRC" "$MFILE"
conf_before=$(md5sum < "$UCI_CONFIG_DIR/thermal-guard")
tg_run 12
chk "the daemon leaves the configuration file alone" \
	"$(md5sum < "$UCI_CONFIG_DIR/thermal-guard")" "$conf_before"
chk "and calls uci for nothing" "$(cat "$tmp/uci.calls")" ""
chk "without trip options the zone is untouched" "$(find "$TR" -name 'trip_point_*' -exec cat {} \; | md5sum)" "$before"
chk "and not even read for this boot" "$([ -e "$STATE_DIR/trip_dt" ] && echo read || echo untouched)" "untouched"
chk "status says off" "$(sfield trip_state)" "off"
case "$(cat "$STATE_DIR/modem-temp" 2>/dev/null)" in
	"90 "[0-9]*" file") chk "the modem temperature is published" ok ok ;;
	*) chk "the modem temperature is published" "$(cat "$STATE_DIR/modem-temp" 2>/dev/null)" "90 <time> file" ;;
esac

# An option deleted while the daemon runs is back at its default by the next
# cycle, for a number and for a word alike.
wait_field() { # $1 key, $2 value, $3 seconds
	local i=0
	while [ "$i" -lt "$3" ]; do
		[ "$(sfield "$1")" = "$2" ] && break
		sleep 1; i=$((i + 1))
	done
	sfield "$1"
}
rm -rf "$STATE_DIR"; plant_tree; echo 40 > "$tmp/modem"
uci_conf "$IVL" "$MSRC" "$MFILE" cpu_warn=60 fan_mode=cooling_device
fresh_status
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
pid=$!
chk "the configured cpu_warn is in use" "$(wait_field cpu_warn 60 6)" "60"
chk "the configured fan_mode is in use" "$(wait_field fan_mode cooling_device 1)" "cooling_device"
uci_conf "$IVL" "$MSRC" "$MFILE"
# One interval of 5 s plus the time a cycle takes.
chk "a deleted option returns to its default within one cycle" "$(wait_field cpu_warn 70 7)" "70"
chk "a deleted word option returns to its default as well" "$(wait_field fan_mode none 1)" "none"
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true

# fan_cooling_device and fan_thermal_zone are gone. A value left over in an
# old configuration is ignored like any unknown option: the fan is found by
# its type, not the numbered path the option named.
rm -rf "$STATE_DIR"; plant_tree
mkdir -p "$TR/cooling_device1"; echo other > "$TR/cooling_device1/type"
echo 7 > "$TR/cooling_device1/max_state"; echo 0 > "$TR/cooling_device1/cur_state"
uci_conf "$IVL" "$MSRC" "$MFILE" fan_mode=cooling_device fan_cooling_device="$TR/cooling_device1"
fresh_status
tg_run 3
chk "a leftover fan_cooling_device is ignored" "$(sfield fan_max)" "3"
chk "and not even rejected in the log" "$(grep -c 'fan_cooling_device' "$STATE_DIR/log")" "0"

# I6 and I7: a hung modem or a held lock costs a reading, not the loop.
# /dev/null stands in for the AT port, it is a character device.
AT="modem_source=fibocom"
PORT="modem_at_port=/dev/null"
LOCK="at_lock=$tmp/at.lock"
cat > "$tmp/bin/sms_tool" <<SMS_END
#!/bin/sh
[ -e "$tmp/sms.hang" ] && exec sleep 60
echo "+GTSENRDTEMP: 1,48000"
SMS_END
chmod 0755 "$tmp/bin/sms_tool"

loop_alive() { # $1 label: status written again after a stalled first cycle
	local t0 t1
	fresh_status
	THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
	pid=$!
	sleep 3; t0=$(field "$STATUS_FILE" now)
	sleep 12; t1=$(field "$STATUS_FILE" now)
	kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
	if [ -n "$t1" ] && [ "${t1:-0}" -gt "${t0:-0}" ]; then
		chk "$1" alive alive
	else
		chk "$1" "stuck($t0/$t1)" alive
	fi
}

rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; touch "$tmp/sms.hang"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK"
loop_alive "a hung modem does not stop the loop"
chk "and it reads as no modem temperature" "$(grep -c 'cannot read modem temperature' "$STATE_DIR/log")" "1"

rm -rf "$STATE_DIR" "$PERSIST_DIR"; rm -f "$tmp/sms.hang"
flock "$tmp/at.lock" sleep 60 &
holder=$!
sleep 1
loop_alive "a held lock does not stop the loop"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true

# A logger that fails costs nothing: the loop goes on, the event log is written.
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; echo 40 > "$tmp/modem"
uci_conf "$IVL" "$MSRC" "$MFILE"
touch "$tmp/logger.fail"
loop_alive "a failing logger does not stop the loop"
chk "and the event log is written all the same" "$(grep -c 'started, version' "$STATE_DIR/log")" "1"
rm -f "$tmp/logger.fail"

# I8: stage 1 against a hung modem fails loudly and the loop goes on
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; touch "$tmp/sms.hang"
echo 85000 > "$TR/thermal_zone0/temp"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK"; : > "$tmp/syslog"
AT_WAIT=2 AT_TIMEOUT=1 THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" \
	timeout 30 sh "$BIN" daemon >/dev/null 2>&1 || true
chk "stage 1 against a hung modem is reported as failed" \
	"$(grep -c "stage 1 action 'modem_radio_off' failed" "$STATE_DIR/log")" "1"
chk "as daemon.crit" "$(prio "stage 1 action 'modem_radio_off' failed")" "daemon.crit"
chk "and the stage is still entered" "$(field "$STATE_DIR/state" STAGE)" "1"
rm -f "$tmp/sms.hang"

# I12: a stage restored after a reboot whose action fails says so, in the one
# restore message. The modem stand-in never answers +CFUN, a notify hook
# collects the messages, and a stand-in ip reports a default route that does
# not run through the modem, so the message goes out instead of queueing.
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree
mkdir -p "$PERSIST_DIR" "$HOOK_DIR"
# Stage 1 entered just now at 50 C, so the hold time cannot escalate it
# further while the case runs.
now=$(date +%s)
printf 'STAGE=1\nT0=%s\nT1=%s\nREF_CPU0=50\nREF_CPU1=50\nREF_MODEM0=48\nREF_MODEM1=48\nGEN=3\n' \
	"$now" "$now" > "$PERSIST_DIR/state"
cat > "$HOOK_DIR/notify" <<HOOK_END
#!/bin/sh
cat >> "$tmp/notified"
echo "----" >> "$tmp/notified"
HOOK_END
cat > "$tmp/bin/ip" <<'IP_END'
#!/bin/sh
[ "$1" = -4 ] && echo "default via 192.0.2.1 dev eth9 proto static"
exit 0
IP_END
chmod 0755 "$HOOK_DIR/notify" "$tmp/bin/ip"
: > "$tmp/notified"; : > "$tmp/syslog"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK"
AT_WAIT=2 AT_TIMEOUT=1 THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" \
	timeout 25 sh "$BIN" daemon >/dev/null 2>&1 || true
chk "a failed action after a reboot is crit" \
	"$(prio "stage 1 action 'modem_radio_off' failed after the reboot")" "daemon.crit"
# Counted by kind: a cooled down message may follow, the board is at 50 C.
chk "one restore message goes out" "$(grep -c 'thermal-guard: restored stage' "$tmp/notified")" "1"
chk "the failure is no message of its own" "$(grep -c 'failed after the reboot' "$tmp/notified")" "0"
chk "and it names the failed action" "$(grep -c \
	"restored stage 1 after a reboot, but reapplying failed for: stage 1 action 'modem_radio_off'" \
	"$tmp/notified")" "1"
rm -f "$HOOK_DIR/notify" "$tmp/bin/ip"

# I13: a persisted stage 1 from an older state file, without references and
# with its hold time long past. A missing reference is no 0: without a rise
# nothing escalates.
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; echo 48 > "$tmp/modem"
mkdir -p "$PERSIST_DIR"; printf 'STAGE=1\nT0=1000\nT1=1100\nGEN=3\n' > "$PERSIST_DIR/state"
uci_conf "$IVL" "$MSRC" "$MFILE"
tg_run 12
chk "an old state without references stays in stage 1" "$(field "$STATE_DIR/state" STAGE)" "1"
chk "and logs no stage 2" "$(grep -c 'stage 2:' "$STATE_DIR/log")" "0"
chk "but has references again" "$(field "$STATE_DIR/state" REF_CPU1)/$(field "$STATE_DIR/state" REF_MODEM1)" "50/48"

# I14: the daemon detects the modem, takes its profile and leaves the model
# for the one shot commands. A planted table, so the case does not move with
# the shipped one. 72 C is below the built in 80 but above the profile's 70.
cat > "$tmp/bin/sms_tool" <<SMS_END
#!/bin/sh
case "\$4" in
	AT+CGMM) printf 'AT+CGMM\r\nFM350-GL\r\n\r\nOK\r\n' ;;
	*) echo "+GTSENRDTEMP: 10,48000" ;;
esac
SMS_END
chmod 0755 "$tmp/bin/sms_tool"
printf 'FM350-GL*  70  78  planted for the integration suite\n' > "$tmp/modems"
export MODEM_TABLE="$tmp/modems"
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree
uci_conf "$IVL" "$AT" "$PORT" "$LOCK"
fresh_status
tg_run 8
chk "the daemon publishes the detected model" "$(sfield modem_model)" "FM350-GL"
chk "and its profile and limits" \
	"$(sfield modem_profile)/$(sfield modem_warn)/$(sfield modem_crit)/$(sfield modem_warn_src)" \
	"FM350-GL*/70/78/profile"
chk "the detection is logged once" \
	"$(grep -c 'modem FM350-GL, profile FM350-GL\*' "$STATE_DIR/log")" "1"
out=$(PATH="$tmp/bin:$PATH" sh "$BIN" status 2>/dev/null)
chk "status shows the model the daemon found" \
	"$(printf '%s\n' "$out" | sed -n 's/^modem_model=//p')/$(printf '%s\n' "$out" | sed -n 's/^modem_warn=//p')" \
	"FM350-GL/70"
out=$(THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" test 50 72 2>/dev/null)
chk "a dry run judges with the profile limits" \
	"$(printf '%s\n' "$out" | grep -c '^would notify (crit): stage 0:')" "1"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" modem_warn=75
out=$(PATH="$tmp/bin:$PATH" sh "$BIN" status 2>/dev/null)
chk "a UCI value still wins over the profile" \
	"$(printf '%s\n' "$out" | sed -n 's/^modem_warn=//p')/$(printf '%s\n' "$out" | sed -n 's/^modem_warn_src=//p')" \
	"75/uci"
unset MODEM_TABLE

# I15: stage 1 caused by the modem, cool for longer than recover_minutes,
# clears itself in the first cycle. The stand-in keeps the CFUN level in a file.
cat > "$tmp/bin/sms_tool" <<SMS_END
#!/bin/sh
case "\$4" in
	AT+CGMM) printf 'AT+CGMM\r\nFM350-GL\r\n\r\nOK\r\n' ;;
	'AT+CFUN?') echo "+CFUN: \$(cat "$tmp/cfun" 2>/dev/null || echo 1)" ;;
	AT+CFUN=*) echo "\${4#AT+CFUN=}" > "$tmp/cfun"; echo OK ;;
	*) echo "+GTSENRDTEMP: 10,48000" ;;
esac
SMS_END
chmod 0755 "$tmp/bin/sms_tool"
# Stage 1 caused by the modem, cool since $1 seconds, the last reading $2
# seconds ago, $3 one more state line. Persisted too, as a stage entry does.
plant_cool1() {
	local now
	now=$(date +%s)
	rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; echo 4 > "$tmp/cfun"
	mkdir -p "$STATE_DIR" "$PERSIST_DIR"
	printf 'STAGE=1\nT0=%s\nT1=%s\nREF_CPU0=60\nREF_MODEM0=90\nREF_CPU1=60\nREF_MODEM1=90\n' \
		"$((now - $1 - 100))" "$((now - $1 - 50))" > "$STATE_DIR/state"
	printf 'CAUSE1=modem\nCPU_SEEN=0\nCOOL_SINCE=%s\nLAST_TS=%s\nGEN=3\n%s\n' \
		"$((now - $1))" "$((now - $2))" "$3" >> "$STATE_DIR/state"
	cp "$STATE_DIR/state" "$PERSIST_DIR/state"
}
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" auto_recover=1 recover_minutes=10

# A state from 2.0.0 recorded no action at entry, so nothing says what to undo.
plant_cool1 700 5 ''
: > "$tmp/syslog"; fresh_status
tg_run 8
chk "a stage 1 without a recorded action stays, radio off" \
	"$(field "$STATE_DIR/state" STAGE)/$(cat "$tmp/cfun")" "1/4"
chk "and nothing is undone" "$(grep -c 'auto recovery' "$STATE_DIR/log")" "0"
chk "and the page is told why" "$(sfield recover_state)" "action"

plant_cool1 700 5 ACTION1=modem_radio_off
: > "$tmp/syslog"
tg_run 8
chk "a cool modem clears its own stage 1" \
	"$(field "$STATE_DIR/state" STAGE)/$(field "$STATE_DIR/state" RECOVER_N)/$(cat "$tmp/cfun")" \
	"-1/1/1"
chk "without touching GEN" "$(field "$STATE_DIR/state" GEN)" "3"
chk "the persisted stage is gone" "$([ -e "$PERSIST_DIR/state" ] && echo kept || echo gone)" "gone"
chk "the recovery is daemon.notice" "$(prio 'auto recovery 1 of 3')" "daemon.notice"
chk "and happens once" "$(grep -c 'auto recovery' "$STATE_DIR/log")" "1"
chk "the attempt is in the ledger on the overlay" \
	"$(field "$PERSIST_DIR/recover" RECOVER_N)/$(field "$PERSIST_DIR/recover" RECOVER_TOLD)" "1/0"

# Reboot: /var/run is gone, the overlay stays. No stage is left to carry the
# count, so the ledger alone has to bring it back.
ledger_win=$(field "$PERSIST_DIR/recover" RECOVER_WIN)
rm -rf "$STATE_DIR"
fresh_status
tg_run 8
chk "after a reboot the daemon has the recovery count back" \
	"$(field "$STATE_DIR/state" RECOVER_N)/$(field "$STATE_DIR/state" RECOVER_WIN)" "1/$ledger_win"
chk "and an idle daemon leaves the ledger as it was" \
	"$(field "$PERSIST_DIR/recover" RECOVER_N)/$(field "$PERSIST_DIR/recover" RECOVER_WIN)" "1/$ledger_win"

# Both on the overlay: the ledger is written on every attempt, the stage file only
# on a stage change, so the ledger is at least as fresh and wins.
rm -rf "$STATE_DIR"; mkdir -p "$PERSIST_DIR"
printf 'STAGE=1\nT0=1000\nT1=1100\nCAUSE1=modem\nACTION1=none\nGEN=3\nRECOVER_N=1\nRECOVER_WIN=%s\n' \
	"$ledger_win" > "$PERSIST_DIR/state"
printf 'RECOVER_WIN=%s\nRECOVER_N=2\nRECOVER_TOLD=0\n' "$ledger_win" > "$PERSIST_DIR/recover"
fresh_status
tg_run 8
chk "the ledger wins over the count in the stage file" \
	"$(field "$STATE_DIR/state" STAGE)/$(field "$STATE_DIR/state" RECOVER_N)" "1/2"

# A ledger from before this version does not exist: the count in the stage file stays.
rm -rf "$STATE_DIR" "$PERSIST_DIR/recover"
fresh_status
tg_run 8
chk "without a ledger the count in the stage file is kept" \
	"$(field "$STATE_DIR/state" STAGE)/$(field "$STATE_DIR/state" RECOVER_N)" "1/1"

# I15b: the same stage, but the last reading is an hour old (daemon stopped or
# disabled meanwhile). The cool streak starts over, nothing is undone.
plant_cool1 4700 3600 ACTION1=modem_radio_off
: > "$tmp/syslog"; fresh_status
tg_run 8
chk "a gap in the readings keeps stage 1 and its radio off" \
	"$(field "$STATE_DIR/state" STAGE)/$(field "$STATE_DIR/state" RECOVER_N)/$(cat "$tmp/cfun")" \
	"1/0/4"
chk "and no recovery is reported" "$(grep -c 'auto recovery' "$STATE_DIR/log")" "0"
chk "the page is told a recovery is planned" "$(sfield recover_state)" "planned"
# The one shot status shows the same, and the profile behind the limits.
out=$(PATH="$tmp/bin:$PATH" sh "$BIN" status 2>/dev/null)
skey() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
chk "status shows the planned recovery" \
	"$(skey recover_state)/$(($(skey recover_at) - $(skey cool_since)))" "planned/600"
chk "and the recovery options" "$(skey recover_minutes)/$(skey recover_max)" "10/3"
chk "and the profile's own limits" "$(skey modem_profile_warn)/$(skey modem_profile_crit)" "80/88"

# A cool stage 1 written by 2.1.0.0, without CPU_SEEN: nothing says the processor
# stayed cool, so it waits for a reset.
plant_cool1 700 5 ACTION1=modem_radio_off
for f in "$STATE_DIR/state" "$PERSIST_DIR/state"; do
	grep -v '^CPU_SEEN=' "$f" > "$f.old" || true; mv "$f.old" "$f"
done
: > "$tmp/syslog"; fresh_status
tg_run 8
chk "a stage 1 from 2.1.0.0 without CPU_SEEN does not clear itself" \
	"$(field "$STATE_DIR/state" STAGE)/$(cat "$tmp/cfun")/$(sfield recover_state)" "1/4/cpu"
chk "and is saved as seen" "$(field "$STATE_DIR/state" CPU_SEEN)" "1"

# I16: reset clears the recovery count as well.
plant_stage1; printf 'RECOVER_N=2\nRECOVER_WIN=1000\n' >> "$STATE_DIR/state"
sh "$BIN" reset >/dev/null 2>&1
chk "reset clears the recovery count" \
	"$(field "$STATE_DIR/state" RECOVER_N)/$(field "$STATE_DIR/state" RECOVER_WIN)" "0/0"
plant_stage1; mkdir -p "$PERSIST_DIR"
printf 'RECOVER_WIN=1000\nRECOVER_N=2\nRECOVER_TOLD=1\n' > "$PERSIST_DIR/recover"
sh "$BIN" reset >/dev/null 2>&1
chk "and the ledger on the overlay is gone" \
	"$([ -e "$PERSIST_DIR/recover" ] && echo kept || echo gone)" "gone"

# A FIFO without a writer as modem_temp_file: an unbounded read would block the
# first cycle for good. The cycle has to go on and the reading counts as missing.
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; rm -f "$tmp/modem.fifo"
mkfifo "$tmp/modem.fifo"
uci_conf "$IVL" "$MSRC" "modem_temp_file=$tmp/modem.fifo"
fresh_status
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout 8 sh "$BIN" daemon >/dev/null 2>&1 || true
t1=$(field "$STATUS_FILE" now)
# Cycles run at about 0 s and 5 s: a second write shows the first one returned.
if [ -n "$t1" ] && [ "$t1" -ge $((status_t0 + 4)) ]; then
	chk "a fifo as modem_temp_file does not stop the loop" alive alive
else
	chk "a fifo as modem_temp_file does not stop the loop" "stuck(${t1:-none})" alive
fi
chk "and it reads as no modem temperature" \
	"$(grep -c 'cannot read modem temperature' "$STATE_DIR/log" 2>/dev/null)" "1"
rm -f "$tmp/modem.fifo"

# A padded 09000 in modem_temp_file is 9 C. Taken as octal it is an arithmetic
# error, and that ends the daemon in its first cycle.
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; echo 09000 > "$tmp/modem"
uci_conf "$IVL" "$MSRC" "$MFILE"
fresh_status
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout 8 sh "$BIN" daemon >/dev/null 2>&1 || true
t1=$(field "$STATUS_FILE" now)
if [ -n "$t1" ] && [ "$t1" -ge $((status_t0 + 4)) ]; then
	chk "a padded modem reading does not stop the loop" alive alive
else
	chk "a padded modem reading does not stop the loop" "stuck(${t1:-none})" alive
fi
chk "and it is published as 9 under modem_c and last_modem" \
	"$(sfield modem_c)/$(THERMAL_ROOT="$TR" sh "$BIN" status 2>/dev/null |
		sed -n 's/^last_modem=//p')" "9/9"

# ---- reset undoes the actions that ran, not the ones configured now --------
# Stand-ins for wifi, ifup, ifdown, ubus and jsonfilter: every call is recorded,
# and a state is kept in files so the read back sees what the call did.
cat > "$tmp/bin/wifi" <<STANDIN_END
#!/bin/sh
echo "wifi \$*" >> "$tmp/undo.calls"
{ true >&7; } 2>/dev/null && echo open > "$tmp/wifi.fd7" || echo closed > "$tmp/wifi.fd7"
[ -e "$tmp/wifi.stuck" ] && exit 0
case "\$1" in up) echo true > "$tmp/wifi.up" ;; down) echo false > "$tmp/wifi.up" ;; esac
STANDIN_END
cat > "$tmp/bin/ifup" <<STANDIN_END
#!/bin/sh
echo "ifup \$1" >> "$tmp/undo.calls"
echo true > "$tmp/if.\$1"
STANDIN_END
cat > "$tmp/bin/ifdown" <<STANDIN_END
#!/bin/sh
echo "ifdown \$1" >> "$tmp/undo.calls"
echo false > "$tmp/if.\$1"
STANDIN_END
# ubus names the object, jsonfilter then answers for it.
cat > "$tmp/bin/ubus" <<STANDIN_END
#!/bin/sh
echo "\${2#network.}"
STANDIN_END
cat > "$tmp/bin/jsonfilter" <<STANDIN_END
#!/bin/sh
read -r obj
case "\$obj" in
	wireless) cat "$tmp/wifi.up" 2>/dev/null || echo false ;;
	interface.*) cat "$tmp/if.\${obj#interface.}" 2>/dev/null || echo false ;;
esac
STANDIN_END
chmod 0755 "$tmp/bin/wifi" "$tmp/bin/ifup" "$tmp/bin/ifdown" "$tmp/bin/ubus" "$tmp/bin/jsonfilter"

# $1 stage, then state lines: what the daemon wrote at entry, with the Wi-Fi
# and the interface down and the modem off as the stages left them.
plant_undo() {
	local s=$1
	shift
	rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; mkdir -p "$STATE_DIR"
	{ printf 'STAGE=%s\nT0=1000\nT1=1100\nGEN=3\n' "$s"; printf '%s\n' "$@"; } > "$STATE_DIR/state"
	echo false > "$tmp/wifi.up"; echo false > "$tmp/if.wwan"; echo 4 > "$tmp/cfun"
	rm -f "$tmp/wifi.stuck" "$tmp/undo.calls"
}
undo_reset() {
	: > "$tmp/syslog"; fresh_status
	THERMAL_ROOT="$TR" WIFI_SETTLE=0 PATH="$tmp/bin:$PATH" sh "$BIN" reset >/dev/null 2>"$tmp/undo.err" &&
		undo_rc=0 || undo_rc=$?
}
# No calls file yet means no calls. The braces take the open error as well.
undo_seen() { { tr '\n' ',' < "$tmp/undo.calls"; } 2>/dev/null; }

plant_undo 1 ACTION1=wifi_off
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" stage1_action=modem_radio_off
undo_reset
chk "reset undoes the recorded Wi-Fi action, not the configured modem one" \
	"$undo_rc/$(undo_seen)/$(cat "$tmp/cfun")/$(field "$STATE_DIR/state" STAGE)" "0/wifi up,/4/-1"
chk "and a clean reset reports nothing failed" "$(sfield reset_failed)" ""
chk "and marks the reset done for the page" "$(sfield reset_state)" "done"
# Some vendor wifi scripts start daemons that would keep the state lock held.
chk "and wifi runs without the state lock's fd" "$(cat "$tmp/wifi.fd7" 2>/dev/null)" "closed"

plant_undo 1 ACTION1=interface_down IFACE1=wwan
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" stage1_action=interface_down action_interface=lan
undo_reset
chk "reset brings up the interface that went down, not the configured one" \
	"$undo_rc/$(undo_seen)/$(cat "$tmp/if.wwan")" "0/ifup wwan,/true"

plant_undo 2 ACTION1=wifi_off ACTION2=interface_down IFACE2=wwan
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" stage1_action=modem_radio_off stage2_action=wifi_off
undo_reset
chk "reset undoes stage 2 before stage 1" "$undo_rc/$(undo_seen)" "0/ifup wwan,wifi up,"

plant_undo 1
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" stage1_action=wifi_off
undo_reset
chk "a state without a recorded action undoes the configured one" \
	"$undo_rc/$(undo_seen)" "0/wifi up,"
chk "and the event log says so" \
	"$(grep -c 'state from an older version, undoing the configured actions' "$STATE_DIR/log")" "1"

# An undo that cannot be confirmed: the stage is cleared all the same, and the
# operator is told what is still in force.
plant_undo 1 ACTION1=wifi_off; touch "$tmp/wifi.stuck"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK"
undo_reset
chk "a reset that could not undo exits 1" "$undo_rc" "1"
chk "and still clears the stage" "$(field "$STATE_DIR/state" STAGE)" "-1"
chk "and keeps what failed in the state" "$(field "$STATE_DIR/state" RESET_FAILED)" "wifi_off"
chk "and publishes it in the status file" "$(sfield reset_failed)" "wifi_off"
chk "and marks the reset failed" "$(sfield reset_state)" "failed"
chk "and logs it as crit" "$(prio 'reset done, but could not undo: wifi_off')" "daemon.crit"
chk "and status shows it" \
	"$(PATH="$tmp/bin:$PATH" sh "$BIN" status 2>/dev/null | sed -n 's/^reset_failed=//p')" "wifi_off"
# Without a stage a reset tries only the fan again. Wi-Fi stays off, so the
# entry stays in view until the next stage or a reboot. It is no failure of this
# reset: exit 0, done, and a notice instead of "could not undo".
rm -f "$tmp/wifi.stuck"; : > "$tmp/undo.calls"
undo_reset
chk "a reset without a stage does not try Wi-Fi again and keeps the entry" \
	"$undo_rc/$(undo_seen)/$(field "$STATE_DIR/state" RESET_FAILED)/$(sfield reset_failed)" \
	"0//wifi_off/wifi_off"
chk "and marks the reset done" "$(sfield reset_state)" "done"
chk "and says at notice what is still in force" \
	"$(prio 'still in force from an earlier reset: wifi_off')/$(grep -c 'could not undo' "$tmp/syslog")" \
	"daemon.notice/0"
chk "and prints the same line on stderr" "$(cat "$tmp/undo.err")" \
	"still in force from an earlier reset: wifi_off"
chk "once per reset" "$(grep -c 'still in force from an earlier reset' "$tmp/syslog")" "1"

# A stage entered after a reset empties the warning list, not the request's own
# result: a page that polls late still learns what its reset could not undo.
stage_enter() {
	local t0 i=0
	t0=$(cat "$TR/thermal_zone0/temp"); echo 75000 > "$TR/thermal_zone0/temp"; fresh_status
	env THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout 40 sh "$BIN" daemon >/dev/null 2>&1 &
	sd=$!
	while [ "$(sfield stage)" != 0 ] && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
	kill "$sd" 2>/dev/null || true; wait "$sd" 2>/dev/null || true
	echo "$t0" > "$TR/thermal_zone0/temp"
}
plant_undo 1 ACTION1=wifi_off; touch "$tmp/wifi.stuck"
uci_conf "$IVL" modem_source=none fan_mode=none
undo_reset; stage_enter
chk "a failed reset keeps its own list in the status after the next stage entry" \
	"$(sfield stage)/$(sfield reset_state)/$(sfield reset_req_failed)/$(sfield reset_failed)" \
	"0/failed/wifi_off/"
plant_undo 1 ACTION1=wifi_off; touch "$tmp/wifi.stuck"; undo_reset
rm -f "$tmp/wifi.stuck"; undo_reset; stage_enter
chk "so does a done reset that listed what an earlier one left in force" \
	"$(sfield stage)/$(sfield reset_state)/$(sfield reset_req_failed)/$(sfield reset_failed)" \
	"0/done/wifi_off/"

# An empty IFACE1 means nothing was taken down, so nothing is brought up. A state
# without the key (2.1.0.0) or without the action (2.0.0) acted on the configured
# interface, so the reset brings that one up.
plant_undo 1 ACTION1=interface_down IFACE1=
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" stage1_action=interface_down action_interface=lan
undo_reset
chk "a recorded interface_down with an empty interface undoes nothing" \
	"$undo_rc/$(undo_seen)" "0/"
plant_undo 1 ACTION1=interface_down
undo_reset
chk "one from 2.1.0.0 without the IFACE1 key brings up the configured interface" \
	"$undo_rc/$(undo_seen)" "0/ifup lan,"
plant_undo 1
undo_reset
chk "an older state brings up the configured interface" "$undo_rc/$(undo_seen)" "0/ifup lan,"

# A reboot between the stage and the reset: the restore follows the recorded
# actions as well, so the reset undoes the same thing that was applied again.
restore_run() {
	THERMAL_ROOT="$TR" WIFI_SETTLE=0 PATH="$tmp/bin:$PATH" timeout 6 sh "$BIN" daemon >/dev/null 2>&1 ||
		true
}
plant_undo 1 ACTION1=wifi_off
mkdir -p "$PERSIST_DIR"; mv "$STATE_DIR/state" "$PERSIST_DIR/state"; rm -rf "$STATE_DIR"
echo 1 > "$tmp/cfun"; echo true > "$tmp/wifi.up"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" stage1_action=modem_radio_off fan_mode=none
restore_run
chk "after a reboot the recorded Wi-Fi action is applied again, not the configured one" \
	"$(undo_seen)/$(cat "$tmp/cfun")/$(field "$STATE_DIR/state" ACTION1)" "wifi down,/1/wifi_off"
undo_reset
chk "and the reset then undoes it" "$undo_rc/$(undo_seen)" "0/wifi down,wifi up,"
plant_undo 1 ACTION1=interface_down IFACE1=wwan
mkdir -p "$PERSIST_DIR"; mv "$STATE_DIR/state" "$PERSIST_DIR/state"; rm -rf "$STATE_DIR"
echo true > "$tmp/if.wwan"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" stage1_action=interface_down action_interface=lan fan_mode=none
restore_run
chk "after a reboot the recorded interface is taken down again, not the configured one" \
	"$(undo_seen)/$(cat "$tmp/if.wwan")" "ifdown wwan,/false"
undo_reset
chk "and the reset brings that one up" "$undo_rc/$(undo_seen)" "0/ifdown wwan,ifup wwan,"
plant_undo 1 ACTION1=interface_down
mkdir -p "$PERSIST_DIR"; mv "$STATE_DIR/state" "$PERSIST_DIR/state"; rm -rf "$STATE_DIR"
echo true > "$tmp/if.lan"
restore_run
chk "after a reboot one from 2.1.0.0 without IFACE1 takes the configured interface down" \
	"$(undo_seen)/$(cat "$tmp/if.lan")/$(field "$STATE_DIR/state" IFACE1)" "ifdown lan,/false/lan"
rm -rf "$PERSIST_DIR"

# A fan that cannot be handed back keeps its record and saved values for the
# next reset. The record names the planted cooling device and its zone.
CDEV_REC="FAN_TAKEN=cooling_device FAN_BOOT=$BOOT1 FAN_T_NAME=pwm-fan FAN_T_ZONE=cpu-thermal"
# shellcheck disable=SC2086 # CDEV_REC holds four state lines
plant_undo 1 ACTION1=none $CDEV_REC FAN_SAVED_POLICY=user_space
rm -f "$TR/thermal_zone0/policy"; mkdir "$TR/thermal_zone0/policy"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=cooling_device
undo_reset
chk "a fan that cannot be handed back fails the reset" \
	"$undo_rc/$(field "$STATE_DIR/state" RESET_FAILED)/$(field "$STATE_DIR/state" STAGE)" "1/fan/-1"
chk "and the stderr says what" "$(cat "$tmp/undo.err")" "could not undo: fan"
chk "and keeps the record and the saved governor for a retry" \
	"$(field "$STATE_DIR/state" FAN_TAKEN)/$(field "$STATE_DIR/state" FAN_SAVED_POLICY)" \
	"cooling_device/user_space"
rmdir "$TR/thermal_zone0/policy"; echo step_wise > "$TR/thermal_zone0/policy"
undo_reset
chk "the next reset writes the saved governor back" \
	"$undo_rc/$(cat "$TR/thermal_zone0/policy")/$(field "$STATE_DIR/state" RESET_FAILED)" "0/user_space/"
chk "and drops it and the record from the state" \
	"$(field "$STATE_DIR/state" FAN_SAVED_POLICY)/$(field "$STATE_DIR/state" FAN_TAKEN)" "/"
# The page's Clear after a failed reset: the fan is tried again, Wi-Fi is not
# and stays listed. A fan that fails again is this reset's failure, and only it.
# shellcheck disable=SC2086 # CDEV_REC holds four state lines
plant_undo -1 RESET_FAILED=wifi_off,fan $CDEV_REC FAN_SAVED_POLICY=user_space
rm -f "$TR/thermal_zone0/policy"; mkdir "$TR/thermal_zone0/policy"
undo_reset
chk "a fan retry that fails again exits 1 and keeps both entries" \
	"$undo_rc/$(undo_seen)/$(field "$STATE_DIR/state" RESET_FAILED)/$(sfield reset_state)" \
	"1//wifi_off,fan/failed"
chk "and says could not undo for the fan alone" \
	"$(cat "$tmp/undo.err")/$(prio 'reset done, but could not undo: fan. Check the device.')" \
	"could not undo: fan/daemon.crit"
rmdir "$TR/thermal_zone0/policy"; echo step_wise > "$TR/thermal_zone0/policy"
undo_reset
chk "a fan retry that works exits 0, drops fan and keeps wifi_off" \
	"$undo_rc/$(undo_seen)/$(cat "$TR/thermal_zone0/policy")/$(field "$STATE_DIR/state" RESET_FAILED)/$(sfield reset_state)" \
	"0//user_space/wifi_off/done"
chk "and reports wifi_off as still in force" "$(cat "$tmp/undo.err")" \
	"still in force from an earlier reset: wifi_off"
rm -f "$tmp/bin/wifi" "$tmp/bin/ifup" "$tmp/bin/ifdown" "$tmp/bin/ubus" "$tmp/bin/jsonfilter"

# ---- reset and the daemon cycle take one lock ------------------------------
# The modem stand-in records every CFUN call. CFUN=4 is slow while cfun4.slow
# exists, CFUN=1 while cfun1.slow does; each says when it has started, so the
# cases wait on files instead of on fixed sleeps. The query holds while
# cfunq.hold exists, until cfunq.go appears.
cat > "$tmp/bin/sms_tool" <<SMS_END
#!/bin/sh
case "\$4" in
	'AT+CFUN?')
		if [ -e "$tmp/cfunq.hold" ]; then
			: > "$tmp/cfunq.started"
			i=0
			while [ ! -e "$tmp/cfunq.go" ] && [ "\$i" -lt 60 ]; do sleep 1; i=\$((i + 1)); done
		fi
		echo "+CFUN: \$(cat "$tmp/cfun" 2>/dev/null || echo 1)" ;;
	AT+CFUN=*)
		l=\${4#AT+CFUN=}
		echo "cfun\$l-start" >> "$tmp/lock.calls"
		if [ -e "$tmp/cfun\$l.slow" ]; then
			touch "$tmp/cfun\$l.started"
			[ "\$l" = 4 ] && sleep 6 || sleep 2
		fi
		echo "\$l" > "$tmp/cfun"; echo "cfun\$l" >> "$tmp/lock.calls"; echo OK ;;
	*) echo "+GTSENRDTEMP: 10,48000" ;;
esac
SMS_END
chmod 0755 "$tmp/bin/sms_tool"
wait_file() { # $1 file, $2 seconds
	local i=0
	while [ ! -e "$1" ] && [ "$i" -lt "$2" ]; do sleep 1; i=$((i + 1)); done
	[ -e "$1" ]
}
wait_line() { # $1 file, $2 whole line, $3 seconds
	local i=0
	while ! grep -qx -- "$2" "$1" 2>/dev/null && [ "$i" -lt "$3" ]; do sleep 1; i=$((i + 1)); done
}
wait_grep() { # $1 file, $2 basic regular expression, $3 seconds
	local i=0
	while ! grep -q -- "$2" "$1" 2>/dev/null && [ "$i" -lt "$3" ]; do sleep 1; i=$((i + 1)); done
}
lock_calls() { { tr '\n' ',' < "$tmp/lock.calls"; } 2>/dev/null; }
lock_reset() { # reset as the page runs it; sets lock_rc
	THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout 60 sh "$BIN" reset >/dev/null \
		2>"$tmp/lock.err" && lock_rc=0 || lock_rc=$?
}
lock_clean() {
	rm -f "$tmp/lock.calls" "$tmp/cfun4.slow" "$tmp/cfun1.slow" "$tmp/cfun4.started" \
		"$tmp/cfun1.started" "$tmp/lock.held" "$tmp/mt.calls"
}

# A cycle runs the slow stage 1 action while reset is pressed. The reset waits
# for the cycle and then undoes what it did, instead of clearing a stage the
# cycle writes back a moment later with the radio left off.
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; lock_clean
echo 85000 > "$TR/thermal_zone0/temp"; echo 1 > "$tmp/cfun"; touch "$tmp/cfun4.slow"
mkdir -p "$STATE_DIR"; printf 'STAGE=-1\nGEN=3\n' > "$STATE_DIR/state"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=none
AT_WAIT=15 AT_TIMEOUT=10 THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
pid=$!
lock_rc=none
if wait_file "$tmp/cfun4.started" 20; then
	# Cool from here on, so no later cycle has a reason to switch it off again.
	echo 40000 > "$TR/thermal_zone0/temp"
	lock_reset
	echo reset-done >> "$tmp/lock.calls"
	# Without the lock the slow call only ends now.
	wait_line "$tmp/lock.calls" cfun4 10
fi
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
chk "reset waits for the stage action of a running cycle, then undoes it" \
	"$lock_rc/$(lock_calls)" "0/cfun4-start,cfun4,cfun1-start,cfun1,reset-done,"
chk "and leaves the state idle with GEN advanced and the radio on" \
	"$(field "$STATE_DIR/state" STAGE)/$(field "$STATE_DIR/state" GEN)/$(cat "$tmp/cfun")" "-1/4/1"

# Two resets at once: the second one joins the first and returns with its
# result, one reset counts.
plant_undo 1 ACTION1=modem_radio_off; lock_clean; touch "$tmp/cfun1.slow"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=none
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout 60 sh "$BIN" reset >/dev/null 2>&1 &
pid=$!
lock_rc=none
wait_file "$tmp/cfun1.started" 10 && lock_reset
first_rc=0; wait "$pid" || first_rc=$?
chk "two resets at once both return" "$first_rc/$lock_rc" "0/0"
chk "and one counts, the stage stays cleared, the radio switched on once" \
	"$(field "$STATE_DIR/state" GEN)/$(field "$STATE_DIR/state" STAGE)/$(
	grep -c '^cfun1$' "$tmp/lock.calls")" "4/-1/1"
chk "the state file is whole KEY=value lines, all 38 of them" \
	"$(grep -cv '^[A-Z][A-Z0-9_]*=[a-z0-9_,-]*$' "$STATE_DIR/state")/$(wc -l < "$STATE_DIR/state" |
		tr -d ' ')" "0/38"
chk "and no temp file is left behind" \
	"$(find "$STATE_DIR" -name 'state.tmp*' | wc -l | tr -d ' ')" "0"

# A reset that cannot get the lock gives up after RESET_WAIT and changes
# nothing. A process standing in for a stuck cycle holds the lock.
if command -v flock >/dev/null 2>&1; then
	plant_undo 1 ACTION1=modem_radio_off; lock_clean
	uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=none
	: > "$STATE_DIR/log"; : > "$tmp/syslog"; before=$(cat "$STATE_DIR/state")
	sh -c 'exec 8>"$1"; flock -x 8; : > "$2"; exec sleep 30' _ "$STATE_DIR/lock" "$tmp/lock.held" &
	holder=$!
	wait_file "$tmp/lock.held" 5 || true
	# Exported by hand: ash does not hand an assignment in front of a function
	# on to the commands the function runs.
	t0=$(date +%s)
	export RESET_WAIT=2; lock_reset; unset RESET_WAIT
	t1=$(date +%s)
	kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
	took=$((t1 - t0))
	chk "a reset that cannot get the lock exits 1 after RESET_WAIT" \
		"$lock_rc/$([ "$took" -le 4 ] && echo bounded || echo "took $took s")" "1/bounded"
	chk "and says why on stderr" "$(cat "$tmp/lock.err")" \
		"the daemon is busy with a stage action, try again"
	chk "and marks it busy for the page" "$(field "$STATE_DIR/reset" reset_state)" "busy"
	chk "and changes nothing" \
		"$(cat "$STATE_DIR/state")/$(cat "$tmp/cfun")/$(lock_calls)" "$before/4/"
	chk "and logs nothing" "$(wc -l < "$STATE_DIR/log" | tr -d ' ')/$(wc -l < "$tmp/syslog" |
		tr -d ' ')" "0/0"

	# The daemon never waits for the lock: while a reset holds it the cycle skips
	# its decision, and the loop goes on. The modem hook counts the cycles.
	rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; lock_clean; mkdir -p "$STATE_DIR" "$HOOK_DIR"
	echo 85000 > "$TR/thermal_zone0/temp"
	printf '#!/bin/sh\necho x >> "%s"\necho 48\n' "$tmp/mt.calls" > "$HOOK_DIR/modem-temp"
	chmod 0755 "$HOOK_DIR/modem-temp"
	uci_conf "$IVL" modem_source=command fan_mode=none stage1_action=none
	sh -c 'exec 8>"$1"; flock -x 8; : > "$2"; exec sleep 60' _ "$STATE_DIR/lock" "$tmp/lock.held" &
	holder=$!
	wait_file "$tmp/lock.held" 5 || true
	THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
	pid=$!
	# Three cycles at 5 s apart, enough for two hot readings in a row.
	i=0
	while [ "$({ wc -l < "$tmp/mt.calls"; } 2>/dev/null || echo 0)" -lt 3 ] && [ "$i" -lt 20 ]; do
		sleep 1; i=$((i + 1))
	done
	chk "a held lock skips the decision, the loop goes on" \
		"$(wc -l < "$tmp/mt.calls" | tr -d ' ')/$(field "$STATE_DIR/state" STAGE)" "3/"
	kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
	# Two more cycles: the hot readings of the skipped ones were never counted.
	i=0
	while [ "$(field "$STATE_DIR/state" STAGE)" != 1 ] && [ "$i" -lt 20 ]; do
		sleep 1; i=$((i + 1))
	done
	kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
	chk "once the lock is free the daemon decides again" "$(field "$STATE_DIR/state" STAGE)" "1"

	# Held for longer than any reset takes, the lock still belongs to its holder:
	# the daemon keeps measuring and alerts, once per holder and level, and
	# decides nothing. Holder B queues behind A and takes over when A ends.
	rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; lock_clean; mkdir -p "$STATE_DIR"
	echo 85000 > "$TR/thermal_zone0/temp"
	# shellcheck disable=SC2016 # expanded by the sh -c that runs it
	hold='exec 8>"$1"; flock -x 8; echo $$ > "$2"; : > "$3"; exec sleep 60'
	sh -c "$hold" _ "$STATE_DIR/lock" "$STATE_DIR/lock.owner" "$tmp/lock.held" &
	holder=$!
	wait_file "$tmp/lock.held" 5 || true
	: > "$tmp/syslog"
	# RESET_WAIT=4 as well: past it, an earlier build decided without the lock.
	RESET_BUDGET=4 RESET_WAIT=4 THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon \
		>/dev/null 2>&1 &
	pid=$!
	wait_grep "$tmp/syslog" 'blocked by a reset for' 20
	sh -c "$hold" _ "$STATE_DIR/lock" "$STATE_DIR/lock.owner" "$tmp/lock.held2" &
	holder2=$!
	crit='blocked by a reset while cpu is at 85 C, above its crit threshold, no action taken'
	chk "a lock held past the reset budget keeps the daemon from deciding" \
		"$(field "$STATE_DIR/state" STAGE)" ""
	budget='blocked by a reset for [0-9]* s, no action taken (cpu 85 C, modem 48 C)'
	chk "and the over budget alert is crit, once" \
		"$(prio 'blocked by a reset for')/$(grep -c "$budget" "$STATE_DIR/log")" "daemon.crit/1"
	chk "the crit reading is alerted once for this holder" "$(grep -cF "$crit" "$STATE_DIR/log")" "1"
	kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
	wait_file "$tmp/lock.held2" 5 || true
	i=0
	while [ "$(grep -cF "$crit" "$STATE_DIR/log")" -lt 2 ] && [ "$i" -lt 15 ]; do
		sleep 1; i=$((i + 1))
	done
	chk "and once more for the next holder" "$(grep -cF "$crit" "$STATE_DIR/log")" "2"
	kill "$holder2" 2>/dev/null || true; wait "$holder2" 2>/dev/null || true
	kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
	rm -f "$HOOK_DIR/modem-temp" "$tmp/lock.held2"
else
	echo "skip the lock cases that need a flock command on the host"
fi
lock_clean

# ---- only the lock holder writes ------------------------------------------
# An instrumented copy of the daemon and its library: every state save, status
# write, stage action, undo and fan write appends "<pid> begin <name>" and
# "<pid> end <name>" to the journal, a taken state lock "<pid> lock", its
# release "<pid> unlock", the body of a reset "<pid> reset". TG_NO_FLOCK takes
# flock away through tg_have, TG_WIFI_TRIES shortens the Wi-Fi retries,
# TG_NO_START hides the start time of the own process. Four points of a reset
# request pause while $TG_PAUSE/<point>.hold exists, until <point>.go appears,
# and add the pid that paused to <point>.pid: fence (the worker before its
# fence), publish (reset-start between the fork and recording the worker),
# finish (before the result goes into the record) and alive (a liveness test
# of the request just read).
IBIN="$tmp/instr/thermal-guard"; ILIB="$tmp/instr/lib"
mkdir -p "$ILIB"; cp "$LIB_DIR"/* "$ILIB"/
for f in tg_lock_take tg_lock_drop tg_reset_run tg_state_write tg_status_write tg_run_action \
	tg_undo_recorded tg_fan_full tg_fan_release tg_recover_ledger_save tg_fan_record_save \
	tg_reset_fence tg_reset_publish tg_reset_finish tg_reset_alive tg_proc_start; do
	printf 's/^%s() {/%s_orig() {/\n' "$f" "$f"
done > "$tmp/instr/renames.sed"
sed -f "$tmp/instr/renames.sed" "$LIB_DIR/backends.sh" > "$ILIB/backends.sh"
sed -f "$tmp/instr/renames.sed" "$BIN" | awk '$0 == "case \"${1:-}\" in" {
	print "[ -z \"${TG_INSTRUMENT:-}\" ] || . \"$TG_INSTRUMENT\"" } { print }' > "$IBIN"
chk "the instrumented copy wraps eleven writers, four pause points and the start time" \
	"$(cat "$IBIN" "$ILIB/backends.sh" | grep -c '^tg_[a-z_]*_orig() {')/$(grep -c \
	'TG_INSTRUMENT' "$IBIN")" "16/1"
cat > "$tmp/instr/hooks.sh" <<'INSTR_END'
tg_journal() { tg_my_pid; echo "$MY_PID $*" >> "$TG_JOURNAL"; }
tg_lock_take() { tg_lock_take_orig || return; tg_journal lock; }
tg_lock_drop() { tg_journal unlock; tg_lock_drop_orig; }
tg_reset_run() { tg_journal reset; tg_reset_run_orig "$@"; }
tg_pause() { # $1 point
	local i=0
	[ -n "${TG_PAUSE:-}" ] && [ -e "$TG_PAUSE/$1.hold" ] || return 0
	tg_my_pid; echo "$MY_PID" >> "$TG_PAUSE/$1.pid"
	while [ ! -e "$TG_PAUSE/$1.go" ] && [ "$i" -lt 60 ]; do sleep 1 6>&- 7>&-; i=$((i + 1)); done
}
tg_reset_fence() { tg_pause fence; tg_reset_fence_orig "$@"; }
tg_reset_publish() { tg_pause publish; tg_reset_publish_orig "$@"; }
tg_reset_finish() { tg_pause finish; tg_reset_finish_orig "$@"; }
tg_reset_alive() { tg_pause alive; tg_reset_alive_orig "$@"; }
tg_proc_start() {
	tg_proc_start_orig "$@"
	[ -z "${TG_NO_START:-}" ] || [ "$1" != "$MY_PID" ] || PROC_START=""
}
for tg_f in tg_state_write tg_status_write tg_run_action tg_undo_recorded tg_fan_full \
	tg_fan_release tg_recover_ledger_save tg_fan_record_save; do
	eval "$tg_f() { local jr=0; tg_journal begin $tg_f; ${tg_f}_orig \"\$@\" || jr=\$?;
		tg_journal end $tg_f; return \$jr; }"
done
if [ -n "${TG_NO_FLOCK:-}" ]; then
	tg_have() { [ "$1" != flock ] && command -v "$1" >/dev/null 2>&1; }
fi
[ -z "${TG_WIFI_TRIES:-}" ] || WIFI_TRIES=$TG_WIFI_TRIES
INSTR_END
# Leading NAME=value arguments go to env, so they reach the daemon. irun_exec
# is for a background job: the exec makes $! the pid of the copy itself.
irun() {
	env LIB_DIR="$ILIB" TG_INSTRUMENT="$tmp/instr/hooks.sh" TG_JOURNAL="$tmp/journal" \
		TG_PAUSE="$tmp/pause" THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" "$@"
}
irun_exec() {
	exec env LIB_DIR="$ILIB" TG_INSTRUMENT="$tmp/instr/hooks.sh" TG_JOURNAL="$tmp/journal" \
		TG_PAUSE="$tmp/pause" THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" "$@"
}
# Writes outside the writer's own hold, and holds that overlap. 0 is clean.
journal_bad() {
	awk '$2 == "lock" { if (h != "") bad++; h = $1; next }
		$2 == "unlock" { if (h != $1) bad++; h = ""; next }
		$2 == "begin" || $2 == "end" { if (h != $1) bad++ }
		END { print bad + 0 }' "$tmp/journal"
}
# Stand-ins that say whether they got fd 7. ifup holds while ifup.hold exists
# until ifup.go appears, and leaves a child running while ifup.child exists.
# wifi ignores TERM while wifi.deaf exists.
cat > "$tmp/bin/ifup" <<STANDIN_END
#!/bin/sh
echo "ifup \$1" >> "$tmp/undo.calls"
{ true >&7; } 2>/dev/null && echo open >> "$tmp/fd7.ifup" || echo closed >> "$tmp/fd7.ifup"
if [ -e "$tmp/ifup.child" ]; then
	sleep 30 &
	echo \$! > "$tmp/ifup.child.pid"
fi
if [ -e "$tmp/ifup.hold" ]; then
	: > "$tmp/ifup.started"
	i=0
	while [ ! -e "$tmp/ifup.go" ] && [ "\$i" -lt 60 ]; do sleep 1; i=\$((i + 1)); done
fi
echo true > "$tmp/if.\$1"
STANDIN_END
cat > "$tmp/bin/ifdown" <<STANDIN_END
#!/bin/sh
echo "ifdown \$1" >> "$tmp/undo.calls"
echo false > "$tmp/if.\$1"
STANDIN_END
cat > "$tmp/bin/wifi" <<STANDIN_END
#!/bin/sh
echo "wifi \$*" >> "$tmp/undo.calls"
if [ -e "$tmp/wifi.deaf" ]; then
	trap '' TERM
	echo \$\$ > "$tmp/wifi.pid"
	exec sleep 30
fi
case "\$1" in up) echo true > "$tmp/wifi.up" ;; down) echo false > "$tmp/wifi.up" ;; esac
STANDIN_END
# ubus holds while ubus.hold exists, until ubus.go appears.
cat > "$tmp/bin/ubus" <<STANDIN_END
#!/bin/sh
{ true >&7; } 2>/dev/null && echo open >> "$tmp/fd7.ubus" || echo closed >> "$tmp/fd7.ubus"
if [ -e "$tmp/ubus.hold" ]; then
	: > "$tmp/ubus.started"
	i=0
	while [ ! -e "$tmp/ubus.go" ] && [ "\$i" -lt 60 ]; do sleep 1; i=\$((i + 1)); done
fi
echo "\${2#network.}"
STANDIN_END
cat > "$tmp/bin/jsonfilter" <<STANDIN_END
#!/bin/sh
read -r obj
case "\$obj" in
	wireless) cat "$tmp/wifi.up" 2>/dev/null || echo false ;;
	interface.*) cat "$tmp/if.\${obj#interface.}" 2>/dev/null || echo false ;;
esac
STANDIN_END
chmod 0755 "$tmp/bin/ifup" "$tmp/bin/ifdown" "$tmp/bin/wifi" "$tmp/bin/ubus" "$tmp/bin/jsonfilter"
writer_clean() {
	rm -f "$tmp/journal" "$tmp/fd7.ifup" "$tmp/fd7.ubus" "$tmp/ifup.hold" "$tmp/ifup.go" \
		"$tmp/ifup.started" "$tmp/ifup.child" "$tmp/ifup.child.pid" "$tmp/wifi.deaf" \
		"$tmp/wifi.pid" "$tmp/mt.calls"
	: > "$tmp/journal"
}
lock_free() { ( flock -n -x 9 ) 9>"$STATE_DIR/lock" && echo free || echo held; }

if command -v flock >/dev/null 2>&1; then
	# No lock, no change: without flock, or with a lock file that cannot be
	# opened (a directory in its place, which not even root can open for
	# writing), reset and reset-start exit 1 and the daemon does not start.
	# status still answers.
	for variant in noflock lockdir; do
		plant_undo 1 ACTION1=interface_down IFACE1=wwan; lock_clean; writer_clean
		uci_conf "$IVL" modem_source=none fan_mode=none
		case "$variant" in
			noflock)
				set -- TG_NO_FLOCK=1
				why="no flock command, the state lock cannot be taken" ;;
			lockdir)
				set -- TG_NONE=1; mkdir "$STATE_DIR/lock"
				why="cannot open $STATE_DIR/lock, the state lock cannot be taken" ;;
		esac
		before=$(cat "$STATE_DIR/state"); rm -f "$STATUS_FILE"; : > "$tmp/syslog"
		irun "$@" sh "$IBIN" reset >/dev/null 2>"$tmp/nl.reset" && r1=0 || r1=$?
		: > "$tmp/journal"
		irun "$@" sh "$IBIN" reset-start >/dev/null 2>"$tmp/nl.start" && r2=0 || r2=$?
		sleep 1
		chk "without a lock ($variant) reset-start launches no reset" "$(cat "$tmp/journal")" ""
		irun "$@" timeout 10 sh "$IBIN" daemon >/dev/null 2>"$tmp/nl.daemon" && r3=0 || r3=$?
		irun "$@" sh "$IBIN" status >"$tmp/nl.status" 2>/dev/null && r4=0 || r4=$?
		irun "$@" sh "$IBIN" fan-forget >/dev/null 2>"$tmp/nl.forget" && r5=0 || r5=$?
		chk "without a lock ($variant) reset, reset-start and the daemon exit 1, status 0" \
			"$r1/$r2/$r3/$r4/$(sed -n 's/^stage=//p' "$tmp/nl.status")" "1/1/1/0/1"
		chk "and fan-forget exits 1 and says why" "$r5/$(cat "$tmp/nl.forget")" \
			"1/$why, nothing was changed"
		chk "and nothing is written: state, status, reset mark, hardware" \
			"$([ "$(cat "$STATE_DIR/state")" = "$before" ] && echo same || echo changed)/$(
			[ -e "$STATUS_FILE" ] && echo status)/$([ -e "$STATE_DIR/reset" ] && echo mark)/$(
			undo_seen)/$(cat "$tmp/journal")" "same////"
		chk "and each says why on stderr" \
			"$(cat "$tmp/nl.reset")|$(cat "$tmp/nl.start")|$(cat "$tmp/nl.daemon")" \
			"$why, nothing was changed|$why, nothing was changed|$why, not starting"
		chk "the daemon's refusal is crit" \
			"$(grep -cF -- "-p daemon.crit $why, not starting" "$tmp/syslog")" "1"
	done
	set --

	# A slow reset with the daemon running. The reset publishes its running
	# mark before it undoes anything; the daemon, blocked, measures and alerts
	# once per level and writes nothing; after the release it decides from the
	# reset's state, two hits as always.
	plant_undo 1 ACTION1=interface_down IFACE1=wwan; lock_clean; writer_clean; mkdir -p "$HOOK_DIR"
	printf '#!/bin/sh\necho x >> "%s"\ncat "%s"\n' "$tmp/mt.calls" "$tmp/mtemp" \
		> "$HOOK_DIR/modem-temp"
	chmod 0755 "$HOOK_DIR/modem-temp"; echo 48 > "$tmp/mtemp"
	echo 40000 > "$TR/thermal_zone0/temp"
	uci_conf "$IVL" modem_source=command fan_mode=none stage1_action=none stage2_action=none
	touch "$tmp/ifup.hold"; : > "$tmp/syslog"; fresh_status
	irun_exec CMD_TIMEOUT=60 sh "$IBIN" reset >/dev/null 2>"$tmp/slow.err" &
	rpid=$!
	wait_file "$tmp/ifup.started" 15 || true
	chk "a reset publishes its running mark before the first undo" \
		"$(sfield reset_state)/$(sfield stage)" "running/1"
	irun_exec RESET_BUDGET=4 sh "$IBIN" daemon >/dev/null 2>&1 &
	dpid=$!
	wait_grep "$tmp/syslog" 'blocked by a reset for' 20
	echo 90 > "$tmp/mtemp"
	wait_grep "$tmp/syslog" 'above its crit threshold' 15
	echo 95000 > "$TR/thermal_zone0/temp"
	wait_grep "$tmp/syslog" 'its emergency threshold' 15
	n=$({ wc -l < "$tmp/mt.calls"; } 2>/dev/null || echo 0)
	i=0
	while [ "$({ wc -l < "$tmp/mt.calls"; } 2>/dev/null || echo 0)" -lt $((n + 2)) ] &&
		[ "$i" -lt 15 ]; do
		sleep 1; i=$((i + 1))
	done
	budget='blocked by a reset for [0-9]* s, no action taken (cpu 40 C, modem 48 C)'
	crit='blocked by a reset while modem is at 90 C, above its crit threshold, no action taken'
	emer='blocked by a reset while the CPU is at 95 C, its emergency threshold, no action taken'
	r="$(grep -c "$budget" "$STATE_DIR/log")/$(grep -cF "$crit" "$STATE_DIR/log")"
	r="$r/$(grep -cF "$emer" "$STATE_DIR/log")/$(prio 'blocked by a reset while the CPU')"
	chk "the blocked daemon alerts over budget, crit and emergency once each, at crit" \
		"$r" "1/1/1/daemon.crit"
	chk "and enters no stage, writes nothing" \
		"$(field "$STATE_DIR/state" STAGE)/$(grep -c 'stage [0-2]:' "$STATE_DIR/log")/$(
		grep -c "^$dpid " "$tmp/journal")" "1/0/0"
	touch "$tmp/ifup.go"
	slow_rc=0; wait "$rpid" || slow_rc=$?
	i=0
	while [ "$(field "$STATE_DIR/state" PENDING_N)" != 1 ] &&
		[ "$(field "$STATE_DIR/state" STAGE)" = -1 ] && [ "$i" -lt 15 ]; do
		sleep 1; i=$((i + 1))
	done
	chk "after the reset the first hot cycle is pending, with the reset's GEN" \
		"$slow_rc/$(field "$STATE_DIR/state" STAGE)/$(field "$STATE_DIR/state" PENDING_N)/$(
		field "$STATE_DIR/state" GEN)" "0/-1/1/4"
	i=0
	while [ "$(field "$STATE_DIR/state" STAGE)" != 2 ] && [ "$i" -lt 15 ]; do
		sleep 1; i=$((i + 1))
	done
	chk "and the second one enters the stage" \
		"$(field "$STATE_DIR/state" STAGE)/$(field "$STATE_DIR/state" GEN)" "2/4"
	kill "$dpid" 2>/dev/null || true; wait "$dpid" 2>/dev/null || true
	chk "the journal shows one writer at a time, the reset's final save included" \
		"$(journal_bad)/$(grep -c "^$rpid begin tg_state_write" "$tmp/journal")/$(
		grep -c "^$dpid lock" "$tmp/journal" | sed 's/^[1-9][0-9]*$/some/')" "0/1/some"
	chk "and ifup and ubus ran without the state lock's fd" \
		"$(sort -u "$tmp/fd7.ifup" "$tmp/fd7.ubus" 2>/dev/null | tr '\n' ' ')" "closed "
	rm -f "$HOOK_DIR/modem-temp"

	# A reset killed in the middle of a step, so it never unlocks: neither the
	# step still running nor the child it left behind keeps the lock held.
	plant_undo 1 ACTION1=interface_down IFACE1=wwan; lock_clean; writer_clean
	uci_conf "$IVL" modem_source=none fan_mode=none
	touch "$tmp/ifup.child" "$tmp/ifup.hold"
	irun_exec CMD_TIMEOUT=60 sh "$IBIN" reset >/dev/null 2>&1 &
	rpid=$!
	wait_file "$tmp/ifup.started" 15 || true
	kill -9 "$rpid" 2>/dev/null || true; wait "$rpid" 2>/dev/null || true
	child=$(cat "$tmp/ifup.child.pid" 2>/dev/null || echo none)
	r=$(kill -0 "$child" 2>/dev/null && echo running || echo gone)
	chk "a reset killed in a step leaves no holder behind, the step and its child running" \
		"$(lock_free)/$r" "free/running"
	# The step ends within a second of the go, before the next case plants its files.
	touch "$tmp/ifup.go"; sleep 2
	kill "$child" 2>/dev/null || true

	# The same for a reset killed while a readback waits inside a command
	# substitution: the subshells it runs in must not hold the lock either.
	# The status write reads the mt_wifi radios through iwpriv, so a planted
	# ra0 that is up and an iwpriv that holds cover that path.
	mkdir -p "$tmp/net/ra0"; echo 0x1003 > "$tmp/net/ra0/flags"
	cat > "$tmp/bin/iwpriv" <<STANDIN_END
#!/bin/sh
if [ -e "$tmp/iwpriv.hold" ]; then
	: > "$tmp/iwpriv.started"
	i=0
	while [ ! -e "$tmp/iwpriv.go" ] && [ "\$i" -lt 60 ]; do sleep 1; i=\$((i + 1)); done
fi
echo "CurrentTemperature = 50"
STANDIN_END
	chmod 0755 "$tmp/bin/iwpriv"
	for variant in wifi interface modem status; do
		case "$variant" in
			wifi) plant_undo 1 ACTION1=wifi_off; hold=ubus ;;
			interface) plant_undo 1 ACTION1=interface_down IFACE1=wwan; hold=ubus ;;
			modem) plant_undo 1 ACTION1=modem_radio_off; hold=cfunq ;;
			status) plant_undo 1 ACTION1=none; hold=iwpriv ;;
		esac
		lock_clean; writer_clean; touch "$tmp/$hold.hold"
		uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=none
		# The long limits raise the undo budgets, so the budget is raised too:
		# a skipped undo would never reach the readback.
		irun_exec UBUS_TIMEOUT=60 AT_WAIT=60 AT_TIMEOUT=60 RESET_BUDGET=1000 WIFI_SETTLE=0 \
			NET_ROOT="$tmp/net" sh "$IBIN" reset >/dev/null 2>&1 &
		rpid=$!
		wait_file "$tmp/$hold.started" 15 || true
		kill -9 "$rpid" 2>/dev/null || true; wait "$rpid" 2>/dev/null || true
		r="$(lock_free)/$([ -e "$tmp/$hold.started" ] && echo reached || echo "not reached")"
		touch "$tmp/$hold.go"; sleep 2
		rm -f "$tmp/$hold.hold" "$tmp/$hold.go" "$tmp/$hold.started"
		chk "a reset killed in the $variant readback leaves no holder behind" "$r" "free/reached"
	done

	# A Wi-Fi undo that ignores TERM is killed 5 s after its time limit, and
	# counts as not undone.
	plant_undo 1 ACTION1=wifi_off; lock_clean; writer_clean; touch "$tmp/wifi.deaf"
	t0=$(date +%s)
	irun CMD_TIMEOUT=1 WIFI_SETTLE=0 TG_WIFI_TRIES=1 sh "$IBIN" reset >/dev/null 2>&1 &&
		r=0 || r=$?
	took=$(($(date +%s) - t0))
	chk "a Wi-Fi undo that ignores TERM is killed after the grace and fails the reset" \
		"$r/$([ "$took" -ge 6 ] && [ "$took" -le 15 ] && echo bounded || echo "took $took s")/$(
		kill -0 "$(cat "$tmp/wifi.pid" 2>/dev/null || echo none)" 2>/dev/null && echo alive ||
		echo dead)/$(field "$STATE_DIR/state" RESET_FAILED)" "1/bounded/dead/wifi_off"

	# An undo that might not end within the reset budget is skipped and listed.
	plant_undo 2 ACTION1=wifi_off ACTION2=interface_down IFACE2=wwan; lock_clean; writer_clean
	: > "$tmp/syslog"
	irun RESET_BUDGET=100 WIFI_SETTLE=0 sh "$IBIN" reset >/dev/null 2>&1 && r=0 || r=$?
	chk "an undo that does not fit the budget is skipped into reset_failed" \
		"$r/$(undo_seen)/$(field "$STATE_DIR/state" STAGE)/$(field "$STATE_DIR/state" RESET_FAILED)" \
		"1/ifup wwan,/-1/wifi_off"
	chk "and the skip is crit" "$(prio 'skipping the undo of wifi_off')" "daemon.crit"

	# RESET_WAIT ends against a daemon cycle that holds the lock with a slow
	# stage action: busy, and the reset changes nothing.
	rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; lock_clean; writer_clean
	echo 85000 > "$TR/thermal_zone0/temp"; echo 1 > "$tmp/cfun"; touch "$tmp/cfun4.slow"
	mkdir -p "$STATE_DIR"; printf 'STAGE=-1\nGEN=3\n' > "$STATE_DIR/state"
	uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=none
	irun_exec AT_WAIT=15 AT_TIMEOUT=10 sh "$IBIN" daemon >/dev/null 2>&1 &
	pid=$!
	r=none
	if wait_file "$tmp/cfun4.started" 20; then
		irun RESET_WAIT=2 sh "$IBIN" reset >/dev/null 2>"$tmp/busy.err" && r=0 || r=$?
		wait_line "$tmp/lock.calls" cfun4 10
	fi
	kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
	chk "a reset that waits out RESET_WAIT against a long cycle is busy and changes nothing" \
		"$r/$(field "$STATE_DIR/reset" reset_state)/$(field "$STATE_DIR/state" GEN)/$(lock_calls)" \
		"1/busy/3/cfun4-start,cfun4,"
	chk "and the journal has no write of the reset" "$(journal_bad)/$(grep -c 'begin tg_undo' \
		"$tmp/journal")" "0/0"

	# A flush that fails or hangs confirms nothing. sync is a stand-in that
	# fails while sync.fail exists and hangs while sync.hang does.
	mkdir -p "$tmp/bin-sync"
	printf '#!/bin/sh\n[ -e "%s" ] && exec sleep 10\n[ ! -e "%s" ]\n' \
		"$tmp/sync.hang" "$tmp/sync.fail" > "$tmp/bin-sync/sync"
	chmod 0755 "$tmp/bin-sync/sync"
	SPATH="$tmp/bin-sync:$tmp/bin:$PATH"
	gone="could not flush the removal of $PERSIST_DIR/state"
	plant_undo 1 ACTION1=none; lock_clean; writer_clean
	mkdir -p "$PERSIST_DIR"; cp "$STATE_DIR/state" "$PERSIST_DIR/state"
	uci_conf "$IVL" modem_source=none fan_mode=none
	touch "$tmp/sync.fail"; : > "$tmp/syslog"
	THERMAL_ROOT="$TR" PATH="$SPATH" sh "$BIN" reset >/dev/null 2>&1 && r=0 || r=$?
	n=$(grep -cF -- "-p daemon.warning $gone, the stage may come back" "$tmp/syslog" || true)
	chk "a reset whose flush fails clears the stage and warns that it may come back" \
		"$r/$(field "$STATE_DIR/state" STAGE)/$n" "0/-1/1"
	# The automatic recovery says the same of the stage it cleared.
	plant_cool1 700 5 ACTION1=modem_radio_off; lock_clean
	uci_conf "$IVL" "$AT" "$PORT" "$LOCK" auto_recover=1 recover_minutes=10
	: > "$tmp/syslog"
	THERMAL_ROOT="$TR" PATH="$SPATH" timeout 8 sh "$BIN" daemon >/dev/null 2>&1 || true
	n=$(grep -cF -- "-p daemon.warning $gone, stage 1 may come back" "$tmp/syslog" || true)
	chk "a recovery whose flush fails clears stage 1 and warns that it may come back" \
		"$(field "$STATE_DIR/state" STAGE)/$n" "-1/1"
	# trips-keep reports a trip_base whose flush hung, within the flush's limit.
	rm -f "$tmp/sync.fail"; touch "$tmp/sync.hang"; mkdir -p "$STATE_DIR"
	echo "50000 60000 70000" > "$STATE_DIR/trip_dt"
	t0=$(date +%s)
	CMD_TIMEOUT=1 PATH="$SPATH" sh "$BIN" trips-keep >/dev/null 2>"$tmp/keep.err" && r=0 || r=$?
	took=$(($(date +%s) - t0))
	chk "a trip_base whose flush hangs is reported, without waiting for it" \
		"$r/$([ "$took" -le 4 ] && echo bounded || echo "took $took s")/$(cat "$tmp/keep.err")" \
		"1/bounded/could not write $PERSIST_DIR/trip_base"
	rm -f "$tmp/sync.hang" "$tmp/sync.fail" "$STATE_DIR/trip_dt" "$PERSIST_DIR/trip_base"
else
	echo "skip the writer cases that need a flock command on the host"
fi
writer_clean; lock_clean
rm -f "$tmp/bin/ifup" "$tmp/bin/ifdown" "$tmp/bin/wifi" "$tmp/bin/ubus" "$tmp/bin/jsonfilter" \
	"$tmp/bin/iwpriv"
rm -rf "$tmp/net"

# ---- the page's Clear runs the reset detached -----------------------------
# rpcd kills a command that outlasts its timeout and waits for the command's
# streams to close, so reset-start must return at once and leave none open.
# The page then reads the result from the status file.
reset_mark() { field "$STATE_DIR/reset" "$1"; }
out_key() { # $1 output of a command, $2 key
	printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}
wait_mark() { # $1 reset_state in the mark, $2 seconds
	local i=0
	while [ "$(reset_mark reset_state)" != "$1" ] && [ "$i" -lt "$2" ]; do
		sleep 1; i=$((i + 1))
	done
}
wait_published() { # $1 reset_state in the status file, $2 seconds
	local i=0
	while [ "$(sfield reset_state)" != "$1" ] && [ "$i" -lt "$2" ]; do
		sleep 1; i=$((i + 1))
	done
}
# The detached reset has to be gone before the next case removes its directory.
wait_owner_gone() {
	local p i=0
	p=$(cat "$STATE_DIR/lock.owner" 2>/dev/null || true)
	while [ -n "$p" ] && kill -0 "$p" 2>/dev/null && [ "$i" -lt 15 ]; do
		sleep 1; i=$((i + 1))
	done
}
start_reset() { # as the page runs it, both streams captured; sets start_rc and start_out
	start_out=$(THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout 60 sh "$BIN" reset-start 2>&1) &&
		start_rc=0 || start_rc=$?
}
if command -v flock >/dev/null 2>&1; then
	plant_undo 1 ACTION1=modem_radio_off; lock_clean; touch "$tmp/cfun1.slow"
	uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=none
	sh -c 'exec 8>"$1"; flock -x 8; : > "$2"; exec sleep 30' _ "$STATE_DIR/lock" "$tmp/lock.held" &
	holder=$!
	wait_file "$tmp/lock.held" 5 || true
	fresh_status; t0=$(date +%s)
	export RESET_WAIT=20; start_reset; unset RESET_WAIT
	t1=$(date +%s)
	chk "reset-start returns at once while the lock is held, with no stream left open" \
		"$start_rc/$([ $((t1 - t0)) -le 2 ] && echo quick || echo "took $((t1 - t0)) s")" "0/quick"
	ts=$(out_key "$start_out" reset_ts)
	case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
	chk "and prints the time it started" \
		"$([ "$ts" -ge "$t0" ] && echo ok || echo "$start_out")" "ok"
	chk "with this boot, the request id and its generation" \
		"$(out_key "$start_out" reset_boot)/$(out_key "$start_out" reset_id)/$(
		out_key "$start_out" reset_gen)" "$BOOT1/1-$(reset_mark reset_rpid)/1"
	wait_mark running 5
	chk "the reset is marked running meanwhile" \
		"$(reset_mark reset_state)/$(reset_mark reset_ts)/$(reset_mark reset_kind)/$(lock_calls)" \
		"running/$ts/page/"
	kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
	r=none
	if wait_file "$tmp/cfun1.started" 10; then
		owner=$(cat "$STATE_DIR/lock.owner" 2>/dev/null || true)
		r=$(for n in 0 1 2; do
			readlink "/proc/${owner:-none}/fd/$n" 2>/dev/null || echo open
		done | tr '\n' ' ')
	fi
	chk "the detached reset owns the lock under its own pid, its streams on /dev/null" \
		"$r" "/dev/null /dev/null /dev/null "
	wait_published "done" 15
	r=$(sfield reset_ts); case "$r" in ''|*[!0-9]*) r=0 ;; esac
	chk "then it is done, the stage cleared and the radio on" \
		"$(reset_mark reset_state)/$(field "$STATE_DIR/state" STAGE)/$(cat "$tmp/cfun")" "done/-1/1"
	chk "and the status file publishes it, not before the start" \
		"$(sfield reset_state)/$([ "$r" -ge "$ts" ] && echo later || echo "$r")" "done/later"
	wait_owner_gone

	# It waits RESET_WAIT for the lock like the command line reset, then gives up.
	plant_undo 1 ACTION1=modem_radio_off; lock_clean
	before=$(cat "$STATE_DIR/state")
	sh -c 'exec 8>"$1"; flock -x 8; : > "$2"; exec sleep 30' _ "$STATE_DIR/lock" "$tmp/lock.held" &
	holder=$!
	wait_file "$tmp/lock.held" 5 || true
	export RESET_WAIT=2; start_reset; unset RESET_WAIT
	wait_mark busy 10
	chk "a detached reset that cannot get the lock ends busy" \
		"$start_rc/$(reset_mark reset_state)" "0/busy"
	chk "and changes nothing" \
		"$(cat "$STATE_DIR/state")/$(cat "$tmp/cfun")/$(lock_calls)" "$before/4/"
	chk "and status shows it" \
		"$(PATH="$tmp/bin:$PATH" sh "$BIN" status 2>/dev/null | sed -n 's/^reset_state=//p')" "busy"
	kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true

	# An undo that cannot be confirmed reaches the page with what it was.
	plant_undo 1 ACTION1=none FAN_SAVED_POLICY=user_space; lock_clean
	rm -f "$TR/thermal_zone0/policy"; mkdir "$TR/thermal_zone0/policy"
	uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=cooling_device fan_cooling_device="$TR/cooling_device0"
	fresh_status; start_reset
	wait_published failed 15
	chk "a detached reset that could not undo ends failed, with what" \
		"$start_rc/$(sfield reset_state)/$(sfield reset_failed)" "0/failed/fan"
	wait_owner_gone
	rmdir "$TR/thermal_zone0/policy"; echo step_wise > "$TR/thermal_zone0/policy"

	# A Clear while a reset runs starts no second one: it joins the running
	# request, so both pages wait for the same id and end on the same result.
	plant_undo 1 ACTION1=modem_radio_off; lock_clean; touch "$tmp/cfun1.slow"
	uci_conf "$IVL" "$AT" "$PORT" "$LOCK" fan_mode=none
	fresh_status
	start_reset; first=$start_out
	wait_file "$tmp/cfun1.started" 10 || true
	start_reset; second=$start_out
	chk "a start while a reset runs joins it, with the same boot, id, generation and time" \
		"$(out_key "$second" reset_joined)/$(out_key "$second" reset_boot)/$(
		out_key "$second" reset_id)/$(out_key "$second" reset_gen)/$(out_key "$second" reset_ts)" \
		"1/$(out_key "$first" reset_boot)/$(out_key "$first" reset_id)/$(
		out_key "$first" reset_gen)/$(out_key "$first" reset_ts)"
	wait_published "done" 15
	chk "and the one request ends with one result, the radio switched on once" \
		"$(sfield reset_id)/$(sfield reset_state)/$(grep -c '^cfun1$' "$tmp/lock.calls")" \
		"$(out_key "$first" reset_id)/done/1"
	wait_owner_gone
else
	echo "skip the detached reset cases that need a flock command on the host"
fi
lock_clean

# ---- one reset at a time, fenced workers ---------------------------------
# reset-start and reset admit one request at a time under reset.admit. A start
# while a request's process lives joins it; a request whose process is gone is
# aborted by the next start. A worker reset-start left behind acts only while
# the record still names its request and itself. The instrumented copy pauses
# where the cases need it (see above) and journals every write.
rec() { field "$STATE_DIR/reset" "$1"; }
wait_rec() { # $1 reset_state in the record, $2 seconds
	local i=0
	while [ "$(rec reset_state)" != "$1" ] && [ "$i" -lt "$2" ]; do sleep 1; i=$((i + 1)); done
}
wait_gone() { # $1 pid, $2 seconds
	local i=0
	while kill -0 "$1" 2>/dev/null && [ "$i" -lt "$2" ]; do sleep 1; i=$((i + 1)); done
}
pstart() { # $1 pid, prints field 22 of its stat, counted after the last ")"
	local l rest
	{ read -r l < "/proc/$1/stat"; } 2>/dev/null || return 0
	rest=${l##*)}
	# shellcheck disable=SC2086 # split into the fields on purpose
	set -- $rest
	shift 19
	echo "$1"
}
istart() { # reset-start of the instrumented copy, as the page runs it
	start_out=$(irun "$@" timeout 60 sh "$IBIN" reset-start 2>&1) && start_rc=0 || start_rc=$?
}
plant_rec() { # $1 state, $2 worker pid, $3 its start time, $4 boot
	printf 'reset_boot=%s\nreset_id=1-%s\nreset_gen=1\nreset_state=%s\nreset_ts=1000\n' \
		"${4:-$BOOT1}" "$2" "$1" > "$STATE_DIR/reset"
	printf 'reset_kind=page\nreset_rpid=%s\nreset_rstart=%s\nreset_wpid=%s\nreset_wstart=%s\n' \
		"$2" "$3" "$2" "$3" >> "$STATE_DIR/reset"
}
jbad=0
# A request with nothing to undo, and a clean journal. What the last case
# journaled counts toward the check for one writer at a time.
quiet() {
	[ -s "$tmp/journal" ] && jbad=$((jbad + $(journal_bad)))
	plant_undo 1 ACTION1=none; lock_clean; writer_clean
	rm -rf "$tmp/pause"; mkdir -p "$tmp/pause"
	uci_conf "$IVL" modem_source=none fan_mode=none
}
resets() { grep -c ' reset$' "$tmp/journal" || true; }
lines() { # $1 file, 0 where it is missing
	local n
	n=$({ wc -l < "$1"; } 2>/dev/null) || n=0
	echo $((n + 0))
}
if command -v flock >/dev/null 2>&1; then
	# Two starts at once: one request, the other start joins it.
	quiet; touch "$tmp/pause/finish.hold"
	irun timeout 60 sh "$IBIN" reset-start > "$tmp/s1.out" 2>&1 &
	p1=$!
	irun timeout 60 sh "$IBIN" reset-start > "$tmp/s2.out" 2>&1 &
	p2=$!
	wait "$p1" || true; wait "$p2" || true
	o1=$(cat "$tmp/s1.out"); o2=$(cat "$tmp/s2.out")
	wait_file "$tmp/pause/finish.pid" 15 || true
	r="$(cat "$tmp/s1.out" "$tmp/s2.out" | grep -c '^reset_joined=1$' || true)"
	for k in reset_boot reset_id reset_gen reset_ts; do
		[ "$(out_key "$o1" $k)" = "$(out_key "$o2" $k)" ] && r="$r/same" || r="$r/$k differs"
	done
	chk "two starts at once admit one request, the other joins it" "$r" "1/same/same/same/same"
	touch "$tmp/pause/finish.go"; wait_rec "done" 15
	chk "and one reset runs, its result in the record under that id" \
		"$(resets)/$(rec reset_state)/$(rec reset_id)/$(rec reset_boot)" \
		"1/done/$(out_key "$o1" reset_id)/$BOOT1"
	wait_owner_gone

	# Two requests one after the other within one second: own ids and
	# generations, the first one kept as the previous record. Tried a few
	# times in case a second boundary falls between them.
	n=0
	while [ "$n" -lt 3 ]; do
		quiet
		s=$(date +%s); while [ "$(date +%s)" = "$s" ]; do :; done
		irun sh "$IBIN" reset >/dev/null 2>&1 || true
		a="$(rec reset_id) $(rec reset_gen) $(rec reset_ts)"
		irun sh "$IBIN" reset >/dev/null 2>&1 || true
		b="$(rec reset_id) $(rec reset_gen) $(rec reset_ts)"
		[ "${a##* }" = "${b##* }" ] && break
		n=$((n + 1))
	done
	chk "two requests in one second get their own ids and generations" \
		"$([ "${a%% *}" != "${b%% *}" ] && echo own)/$(rec reset_gen)/$(
		[ "${a##* }" = "${b##* }" ] && echo "one second")" "own/2/one second"
	chk "a reset by hand alone rotates the records" \
		"$(rec reset_kind)/$(rec reset_state)/$(rec reset_prev_id)/$(rec reset_prev_gen)/$(
		rec reset_prev_state)/$(rec reset_prev_ts)" "cli/done/${a%% *}/1/done/${a##* }"

	# A worker paused before its fence while its starter returns: the request
	# names the worker, so a second start joins it, and the worker then runs as
	# the one admitted request.
	quiet; touch "$tmp/pause/fence.hold"
	istart; o1=$start_out; r1=$start_rc
	wait_file "$tmp/pause/fence.pid" 10 || true
	w=$(cat "$tmp/pause/fence.pid" 2>/dev/null || echo none)
	chk "a start returns while its worker waits before the fence, the worker recorded" \
		"$r1/$(rec reset_state)/$(rec reset_wpid)/$(rec reset_wstart)" \
		"0/starting/$w/$(pstart "$w")"
	rm -f "$tmp/pause/fence.hold"
	istart; o2=$start_out
	chk "and a second start joins that request" \
		"$(out_key "$o2" reset_joined)/$(out_key "$o2" reset_id)" "1/$(out_key "$o1" reset_id)"
	touch "$tmp/pause/fence.go"; wait_rec "done" 15
	chk "the paused worker then runs the one reset" \
		"$(rec reset_id)/$(rec reset_state)/$(resets)/$(grep -c "^$w reset$" "$tmp/journal")" \
		"$(out_key "$o1" reset_id)/done/1/1"
	wait_owner_gone

	# reset-start killed after the fork, before it recorded its worker: the next
	# start finds the reserver dead and no worker, aborts that request and runs
	# its own. The old worker, resumed, leaves at its fence without a trace.
	quiet; touch "$tmp/pause/fence.hold" "$tmp/pause/publish.hold"
	irun_exec sh "$IBIN" reset-start >/dev/null 2>&1 &
	pp=$!
	wait_file "$tmp/pause/publish.pid" 10 || true; wait_file "$tmp/pause/fence.pid" 10 || true
	a=$(cat "$tmp/pause/fence.pid" 2>/dev/null || echo none); aid=$(rec reset_id)
	chk "before its worker is recorded a request names only its reserver" \
		"$(rec reset_state)/$(rec reset_rpid)/$(rec reset_wpid)/$aid" "starting/$pp//1-$pp"
	kill -9 "$pp" 2>/dev/null || true; wait "$pp" 2>/dev/null || true
	rm -f "$tmp/pause/fence.hold" "$tmp/pause/publish.hold"; : > "$tmp/syslog"
	istart; o=$start_out
	wait_rec "done" 15
	chk "a start after the reserver died aborts that request and runs its own" \
		"$start_rc/$(out_key "$o" reset_joined)/$(out_key "$o" reset_gen)/$(rec reset_state)/$(
		rec reset_prev_id)/$(rec reset_prev_state)" "0//2/done/$aid/aborted"
	chk "and logs the abort" \
		"$(prio "reset request $aid ended without a result")" "daemon.warning"
	wait_owner_gone
	before=$(cat "$STATE_DIR/reset")
	touch "$tmp/pause/fence.go"; wait_gone "$a" 15
	chk "the resumed old worker leaves at its fence, without the lock and without a write" \
		"$(kill -0 "$a" 2>/dev/null && echo alive || echo gone)/$(grep -c "^$a " "$tmp/journal")/$(
		[ "$(cat "$STATE_DIR/reset")" = "$before" ] && echo same)/$(resets)" "gone/0/same/1"

	# A worker that reaches its result after a later request took the record
	# writes no result: the later one and its failure list stay as they are.
	quiet; touch "$tmp/pause/finish.hold"
	istart; aid=$(out_key "$start_out" reset_id)
	wait_file "$tmp/pause/finish.pid" 15 || true
	w=$(cat "$tmp/pause/finish.pid" 2>/dev/null || echo none)
	{
		printf 'reset_boot=%s\nreset_id=2-4242\nreset_gen=2\nreset_state=failed\n' "$BOOT1"
		printf 'reset_ts=%s\nreset_kind=cli\nreset_failed=wifi_off\n' "$(date +%s)"
		printf 'reset_prev_id=%s\nreset_prev_gen=1\nreset_prev_state=aborted\n' "$aid"
		printf 'reset_prev_failed=\nreset_prev_ts=1000\n'
	} > "$STATE_DIR/reset"
	before=$(cat "$STATE_DIR/reset"); fresh_status
	touch "$tmp/pause/finish.go"; wait_gone "$w" 15
	chk "a stale worker at its result writes no result over a later request" \
		"$([ "$(cat "$STATE_DIR/reset")" = "$before" ] && echo same)/$(sfield reset_id)/$(
		sfield reset_state)/$(sfield reset_prev_id)" "same/2-4242/failed/$aid"

	# A running request whose worker is gone shows as aborted, and the next
	# start aborts it and reserves anew.
	quiet
	sh -c 'exit 0' & dead=$!; wait "$dead" || true
	plant_rec running "$dead" 4711
	chk "a running request whose worker is gone shows as aborted" \
		"$(irun sh "$IBIN" status 2>/dev/null | sed -n 's/^reset_state=//p')" "aborted"
	istart; o=$start_out; wait_rec "done" 15
	chk "and the next start aborts it and reserves anew" \
		"$(out_key "$o" reset_joined)/$(out_key "$o" reset_gen)/$(rec reset_prev_id)/$(
		rec reset_prev_state)/$(rec reset_state)" "/2/1-$dead/aborted/done"
	wait_owner_gone

	# A live process under the recorded pid is the worker only with the
	# recorded start time: a reused pid is not joined.
	quiet
	sleep 30 & live=$!
	st=$(pstart "$live")
	plant_rec running "$live" "$st"
	istart; o=$start_out
	chk "a live worker identity is joined" \
		"$(out_key "$o" reset_joined)/$(out_key "$o" reset_id)/$(resets)" "1/1-$live/0"
	plant_rec running "$live" "$((st + 1))"
	istart; o=$start_out; wait_rec "done" 15
	chk "the same pid with another start time is not" \
		"$(out_key "$o" reset_joined)/$(out_key "$o" reset_gen)/$(rec reset_prev_state)" \
		"/2/aborted"
	kill "$live" 2>/dev/null || true; wait "$live" 2>/dev/null || true
	wait_owner_gone

	# A request of another boot is neither joined nor kept: the generation
	# starts again at 1, and no previous record of that boot is carried.
	quiet
	sleep 30 & live=$!
	plant_rec running "$live" "$(pstart "$live")" "$BOOT0"
	echo "$BOOT0 7" > "$STATE_DIR/reset.gen"
	istart; o=$start_out; wait_rec "done" 15
	chk "a request of another boot is not joined, this boot starts at generation 1" \
		"$(out_key "$o" reset_joined)/$(out_key "$o" reset_gen)/$(rec reset_boot)/$(
		rec reset_prev_id)/$(cat "$STATE_DIR/reset.gen")" "/1/$BOOT1//$BOOT1 1"
	kill "$live" 2>/dev/null || true; wait "$live" 2>/dev/null || true
	wait_owner_gone

	# A reset by hand while a detached one runs joins it and exits by its
	# result, while that worker writes the result: no deadlock, in bounded time.
	quiet; touch "$tmp/pause/finish.hold"
	istart; id=$(out_key "$start_out" reset_id)
	wait_file "$tmp/pause/finish.pid" 15 || true
	t0=$(date +%s)
	irun timeout 60 sh "$IBIN" reset > "$tmp/join.out" 2> "$tmp/join.err" &
	jp=$!
	wait_grep "$tmp/join.out" 'already running' 10
	touch "$tmp/pause/finish.go"
	jr=0; wait "$jp" || jr=$?
	took=$(($(date +%s) - t0))
	chk "a reset by hand during a detached one joins it and exits by its result" \
		"$jr/$(cat "$tmp/join.out")/$([ "$took" -le 20 ] && echo bounded || echo "took $took s")/$(
		resets)/$(rec reset_id)/$(rec reset_state)" \
		"0/a reset is already running (request $id), waiting for its result/bounded/1/$id/done"
	wait_owner_gone
	# The same for a detached reset that ends busy: the joined one exits 1.
	quiet
	sh -c 'exec 8>"$1"; flock -x 8; : > "$2"; exec sleep 30' _ "$STATE_DIR/lock" "$tmp/lock.held" &
	holder=$!
	wait_file "$tmp/lock.held" 5 || true
	istart RESET_WAIT=3; id=$(out_key "$start_out" reset_id)
	irun timeout 60 sh "$IBIN" reset > "$tmp/join.out" 2> "$tmp/join.err" && jr=0 || jr=$?
	chk "and a joined reset that ends busy exits 1 and says so" \
		"$jr/$(cat "$tmp/join.err")/$(rec reset_id)/$(rec reset_state)" \
		"1/the daemon is busy with a stage action, try again/$id/busy"
	kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true

	# Readers without admission, a joined reset and status, read the record
	# while the request runs and test its process only after the worker wrote
	# its result and ended: they report that result, never aborted.
	quiet; touch "$tmp/pause/finish.hold"
	istart; id=$(out_key "$start_out" reset_id)
	wait_file "$tmp/pause/finish.pid" 15 || true
	w=$(cat "$tmp/pause/finish.pid" 2>/dev/null || echo none)
	irun timeout 60 sh "$IBIN" reset > "$tmp/join.out" 2> "$tmp/join.err" &
	jp=$!
	wait_grep "$tmp/join.out" 'already running' 10
	touch "$tmp/pause/alive.hold"
	wait_file "$tmp/pause/alive.pid" 10 || true
	irun timeout 60 sh "$IBIN" status > "$tmp/race.status" 2>/dev/null &
	sp=$!
	i=0
	while [ "$(lines "$tmp/pause/alive.pid")" -lt 2 ] && [ "$i" -lt 10 ]; do
		sleep 1; i=$((i + 1))
	done
	rm -f "$tmp/pause/alive.hold"
	r=$(lines "$tmp/pause/alive.pid")
	touch "$tmp/pause/finish.go"; wait_gone "$w" 15
	r="$r/$(kill -0 "$w" 2>/dev/null && echo alive || echo gone)/$(rec reset_state)"
	touch "$tmp/pause/alive.go"
	jr=0; wait "$jp" || jr=$?; wait "$sp" || true
	chk "both readers paused, the worker wrote done and ended meanwhile" "$r" "2/gone/done"
	chk "and the joined reset and status report done, not aborted" \
		"$jr/$(cat "$tmp/join.err")/$(field "$tmp/race.status" reset_state)/$(
		field "$tmp/race.status" reset_id)" "0//done/$id"

	# A request needs the start time of the process that makes it: without it a
	# live command line reset would look dead, and the next start would run a
	# second one next to it.
	quiet; before=$(cat "$STATE_DIR/state")
	irun TG_NO_START=1 sh "$IBIN" reset >/dev/null 2>"$tmp/adm.reset" && r1=0 || r1=$?
	irun TG_NO_START=1 sh "$IBIN" reset-start >/dev/null 2>"$tmp/adm.start" && r2=0 || r2=$?
	sleep 1
	why="cannot read the start time of this process from /proc, nothing was changed"
	chk "without its own start time reset and reset-start exit 1 and start nothing" \
		"$r1/$r2/$(cat "$tmp/adm.reset")|$(cat "$tmp/adm.start")/$(cat "$tmp/journal")/$(
		[ -e "$STATE_DIR/reset" ] && echo record)/$(
		[ "$(cat "$STATE_DIR/state")" = "$before" ] && echo same)" "1/1/$why|$why///same"

	# A worker that cannot open the state lock at all ends failed, not busy:
	# trying again would not help. The log says why.
	quiet; touch "$tmp/pause/fence.hold"
	istart; id=$(out_key "$start_out" reset_id)
	wait_file "$tmp/pause/fence.pid" 10 || true
	rm -f "$STATE_DIR/lock" "$tmp/pause/fence.hold"; mkdir "$STATE_DIR/lock"; : > "$tmp/syslog"
	touch "$tmp/pause/fence.go"; wait_rec failed 15
	nolock="cannot open $STATE_DIR/lock, the state lock cannot be taken"
	chk "a worker without a state lock ends failed and logs why at crit" \
		"$(rec reset_id)/$(rec reset_state)/$(resets)/$(grep -cF -- \
		"-p daemon.crit reset request $id: $nolock, nothing was changed" "$tmp/syslog")" \
		"$id/failed/1/1"
	wait_gone "$(cat "$tmp/pause/fence.pid" 2>/dev/null || echo none)" 15
	rmdir "$STATE_DIR/lock"

	# Three completions in a row: the current and the previous record keep the
	# failure lists of their own requests. The second cannot hand the fan back.
	quiet
	irun sh "$IBIN" reset >/dev/null 2>&1 || true
	uci_conf "$IVL" modem_source=none fan_mode=cooling_device \
		fan_cooling_device="$TR/cooling_device0"
	printf 'STAGE=1\nT0=1000\nT1=1100\nGEN=3\nACTION1=none\nFAN_SAVED_POLICY=user_space\n' \
		> "$STATE_DIR/state"
	rm -f "$TR/thermal_zone0/policy"; mkdir "$TR/thermal_zone0/policy"
	irun sh "$IBIN" reset >/dev/null 2>&1 || true
	r="$(rec reset_state)/$(rec reset_failed)"
	# The saved values name no fan, so they stay unresolved: the third request
	# starts from a stage without them.
	rmdir "$TR/thermal_zone0/policy"; echo step_wise > "$TR/thermal_zone0/policy"
	printf 'STAGE=1\nT0=1000\nT1=1100\nGEN=5\nACTION1=none\n' > "$STATE_DIR/state"
	irun sh "$IBIN" reset >/dev/null 2>&1 || true
	fresh_status; irun sh "$IBIN" status > "$tmp/three.status" 2>/dev/null || true
	chk "the second of three resets fails with the fan" "$r" "failed/fan"
	chk "after the third the current and the previous record keep their own lists" \
		"$(rec reset_gen)/$(rec reset_state)/$(rec reset_failed)/$(rec reset_prev_gen)/$(
		rec reset_prev_state)/$(rec reset_prev_failed)" "3/done//2/failed/fan"
	chk "and status publishes both" \
		"$(field "$tmp/three.status" reset_gen)/$(field "$tmp/three.status" reset_failed)/$(
		field "$tmp/three.status" reset_prev_gen)/$(field "$tmp/three.status" reset_prev_failed)" \
		"3//2/fan"

	# Without admission there is no request: a directory in place of reset.admit,
	# or a holder that does not let go.
	quiet; before=$(cat "$STATE_DIR/state"); mkdir "$STATE_DIR/reset.admit"
	irun sh "$IBIN" reset-start >/dev/null 2>"$tmp/adm.start" && r1=0 || r1=$?
	irun sh "$IBIN" reset >/dev/null 2>"$tmp/adm.reset" && r2=0 || r2=$?
	sleep 1
	chk "without admission reset-start and reset exit 1, start nothing and write nothing" \
		"$r1/$r2/$(cat "$tmp/journal")/$([ -e "$STATE_DIR/reset" ] && echo record)/$(
		[ "$(cat "$STATE_DIR/state")" = "$before" ] && echo same)" "1/1///same"
	why="cannot open $STATE_DIR/reset.admit, nothing was changed"
	chk "and say why" "$(cat "$tmp/adm.start")|$(cat "$tmp/adm.reset")" "$why|$why"
	rmdir "$STATE_DIR/reset.admit"
	sh -c 'exec 8>"$1"; flock -x 8; : > "$2"; exec sleep 30' _ "$STATE_DIR/reset.admit" \
		"$tmp/lock.held" &
	holder=$!
	wait_file "$tmp/lock.held" 5 || true
	irun ADMIT_WAIT=1 sh "$IBIN" reset-start >/dev/null 2>"$tmp/adm.start" && r1=0 || r1=$?
	sleep 1
	chk "an admission held elsewhere ends reset-start with 1 after ADMIT_WAIT, nothing started" \
		"$r1/$(cat "$tmp/adm.start")/$(cat "$tmp/journal")/$(
		[ -e "$STATE_DIR/reset" ] && echo record)" \
		"1/another reset is being admitted and does not let go, nothing was changed//"
	kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
	# Without this boot's id a request cannot be told from one of another boot.
	irun BOOT_ID_FILE="$tmp/no-boot-id" sh "$IBIN" reset-start >/dev/null 2>"$tmp/adm.start" &&
		r1=0 || r1=$?
	irun BOOT_ID_FILE="$tmp/no-boot-id" sh "$IBIN" reset >/dev/null 2>"$tmp/adm.reset" &&
		r2=0 || r2=$?
	sleep 1
	why="cannot read the boot id from $tmp/no-boot-id, nothing was changed"
	chk "without a boot id reset-start and reset exit 1 and start nothing" \
		"$r1/$r2/$(cat "$tmp/adm.start")|$(cat "$tmp/adm.reset")/$(cat "$tmp/journal")/$(
		[ -e "$STATE_DIR/reset" ] && echo record)" "1/1/$why|$why//"

	# A rename that outlives its caller still holds admission: no later request
	# gets in before it has landed, so it cannot put back an older record.
	real_mv=$(command -v mv)
	mkdir -p "$tmp/mvbin"
	cat > "$tmp/mvbin/mv" <<STANDIN_END
#!/bin/sh
# Holds the rename onto the file named in mv.hold until mv.go appears.
p="$tmp/pause"
if [ -e "\$p/mv.hold" ] && [ "\${2##*/}" = "\$(cat "\$p/mv.hold")" ]; then
	rm -f "\$p/mv.hold"; echo \$\$ > "\$p/mv.pid"
	i=0
	while [ ! -e "\$p/mv.go" ] && [ "\$i" -lt 60 ]; do sleep 1; i=\$((i + 1)); done
fi
exec "$real_mv" "\$@"
STANDIN_END
	chmod 0755 "$tmp/mvbin/mv"
	for target in reset.gen reset; do
		quiet; echo "$target" > "$tmp/pause/mv.hold"
		( irun_exec PATH="$tmp/mvbin:$tmp/bin:$PATH" sh "$IBIN" reset >/dev/null 2>&1 ) &
		pa=$!
		wait_file "$tmp/pause/mv.pid" 10 || true
		gen0=$(cat "$STATE_DIR/reset.gen" 2>/dev/null) || gen0=""
		rec0=$(cat "$STATE_DIR/reset" 2>/dev/null) || rec0=""
		kill -9 "$pa" 2>/dev/null || true; wait "$pa" 2>/dev/null || true
		irun ADMIT_WAIT=1 sh "$IBIN" reset >/dev/null 2>&1 && r1=0 || r1=$?
		same=""
		[ "$(cat "$STATE_DIR/reset.gen" 2>/dev/null)" = "$gen0" ] &&
			[ "$(cat "$STATE_DIR/reset" 2>/dev/null)" = "$rec0" ] && same=same
		touch "$tmp/pause/mv.go"; wait_gone "$(cat "$tmp/pause/mv.pid")" 10
		irun sh "$IBIN" reset >/dev/null 2>&1 && r2=0 || r2=$?
		chk "a rename onto $target whose caller died keeps admission until it has landed" \
			"$r1/$same/$r2/$(cut -d' ' -f2 "$STATE_DIR/reset.gen")/$(rec reset_gen)/$(
			rec reset_state)" "1/same/0/2/2/done"
	done

	quiet
	chk "the journal shows one writer at a time in every case above" "$jbad" "0"
else
	echo "skip the single flight cases that need a flock command on the host"
fi
writer_clean; lock_clean; rm -rf "$tmp/pause"

# The page runs fixed command lines only: the ACL names three, without arguments.
ACL="$root/luci-app-thermal-guard/root/usr/share/rpcd/acl.d/luci-app-thermal-guard.json"
chk "the rpcd ACL runs thermal-guard with three exact command lines" \
	"$(grep -o '"/usr/sbin/thermal-guard[^"]*": \[ "exec" \]' "$ACL" | tr '\n' ';')" \
	"$(printf '"/usr/sbin/thermal-guard %s": [ "exec" ];' reset reset-start trips-keep)"

# A writer killed between write and rename leaves its temp file behind. The
# daemon removes those at start, under the lock, and nothing else.
leftovers() {
	printf '%s\n' "$STATE_DIR/state.tmp.4711" "$PERSIST_DIR/state.tmp.4712" \
		"$STATUS_FILE.tmp.4713" "$STATUS_FILE.tmp" "$PERSIST_DIR/recover.4714" \
		"$STATE_DIR/other.tmp.1"
}
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; mkdir -p "$STATE_DIR" "$PERSIST_DIR"
leftovers | while read -r f; do : > "$f"; done
uci_conf "$IVL" modem_source=none fan_mode=none
fresh_status
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
pid=$!
wait_file "$STATUS_FILE" 15 || true
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
r=$(leftovers | while read -r f; do [ -e "$f" ] && printf 1 || printf 0; done)
chk "the daemon removes leftover temp files at start, other files stay" "$r" "000001"
rm -f "$STATE_DIR/other.tmp.1"

# ---- the fan taken at stage entry is the one handed back ------------------
# A takeover records the fan by identity (hwmon name or cooling device type,
# the resolved device link, the pwm attribute, the zone type) and this boot's
# id. Reassert and release find that fan again by scanning, whatever the
# settings say by then, and a record that cannot name one fan writes nothing.
HW="$tmp/hwmon"
plant_chip() { # $1 hwmon index, $2 device under platform, $3 duty cycle, $4 mode
	local h="$HW/hwmon$1" d="$DEVICES_ROOT/platform/$2"
	mkdir -p "$h" "$d"
	echo pwmfan > "$h/name"; echo "$3" > "$h/pwm1"; echo "$4" > "$h/pwm1_enable"
	ln -s "$d" "$h/device"
}
chip() { echo "$(cat "$HW/hwmon$1/pwm1")/$(cat "$HW/hwmon$1/pwm1_enable")"; }
fan_clean() { rm -rf "$STATE_DIR" "$PERSIST_DIR" "$HW" "$DEVICES_ROOT"; plant_tree; }
# A stage as a reboot leaves it: in the persisted copy, without a working state.
plant_persist() { # $@ state lines after the stage
	mkdir -p "$PERSIST_DIR"
	{ printf 'STAGE=0\nT0=%s\nGEN=3\n' "$(date +%s)"; printf '%s\n' "$@"; } > "$PERSIST_DIR/state"
}
plant_state() { # $1 stage, then state lines
	local s=$1
	shift
	mkdir -p "$STATE_DIR"
	{ printf 'STAGE=%s\nT0=%s\nGEN=3\n' "$s" "$(date +%s)"; printf '%s\n' "$@"; } \
		> "$STATE_DIR/state"
}
st() { field "$STATE_DIR/state" "$1"; }
fan_env() { env THERMAL_ROOT="$TR" HWMON_ROOT="$HW" PATH="$tmp/bin:$PATH" "$@"; }
# A restore writes the working state only once its takeover save and actions
# are done: stopped earlier, the next case would find no record. So the run
# lasts $1 seconds and then until the state file exists, 30 seconds at most.
fan_daemon() { # $1 seconds
	local pid
	# Not through fan_env: a function in the background is a subshell, and its
	# pid is not the one of timeout, which hands TERM on to the daemon.
	env THERMAL_ROOT="$TR" HWMON_ROOT="$HW" PATH="$tmp/bin:$PATH" timeout 60 sh "$BIN" daemon \
		>/dev/null 2>&1 &
	pid=$!
	sleep "$1"
	wait_file "$STATE_DIR/state" 30 || true
	kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
}
fan_reset() {
	: > "$tmp/syslog"
	fan_env sh "$BIN" reset >/dev/null 2>"$tmp/fan.err" && fan_rc=0 || fan_rc=$?
}
fan_forget() {
	fan_env sh "$BIN" fan-forget >"$tmp/fan.out" 2>"$tmp/fan.err" && fan_rc=0 || fan_rc=$?
}
pending() { fan_env sh "$BIN" status 2>/dev/null | sed -n 's/^fan_restore_pending=//p'; }
fan_conf() { uci_conf "$IVL" modem_source=none stage1_action=none stage2_action=none "$@"; }
PWM_REC="FAN_TAKEN=pwm FAN_BOOT=$BOOT1 FAN_T_NAME=pwmfan FAN_T_ATTR=pwm1 FAN_T_FULL=255"

# A real stage entry. The instrumented copy notes the duty cycle at the save of
# the takeover record, which has to see the chip untouched.
fan_clean; plant_chip 0 fan0 90 1; echo 75000 > "$TR/thermal_zone0/temp"
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
cat > "$tmp/fan-order.sh" <<'ORDER_END'
. "$TG_HOOKS"
tg_fan_record_save() {
	[ -z "$FAN_TAKEN" ] || cat "$TG_PWM_SEEN" >> "$TG_PWM_LOG" 2>/dev/null
	tg_fan_record_save_orig "$@"
}
ORDER_END
rm -f "$tmp/pwm.seen"
irun TG_INSTRUMENT="$tmp/fan-order.sh" TG_HOOKS="$tmp/instr/hooks.sh" HWMON_ROOT="$HW" \
	TG_PWM_SEEN="$HW/hwmon0/pwm1" TG_PWM_LOG="$tmp/pwm.seen" timeout 8 sh "$IBIN" daemon \
	>/dev/null 2>&1 || true
chk "a stage forces the pwm fan" "$(st STAGE)/$(chip 0)" "0/255/1"
chk "and records it by identity, with this boot and what the chip was doing" \
	"$(st FAN_TAKEN)/$(st FAN_T_NAME)/$(st FAN_T_DEV)/$(st FAN_T_ATTR)/$(st FAN_BOOT)/$(
	st FAN_SAVED_PWM)/$(st FAN_SAVED_ENABLE)/$(st FAN_UNRESOLVED)" \
	"pwm/pwmfan/$DEVICES_ROOT/platform/fan0/pwm1/$BOOT1/90/1/0"
chk "the record is saved before the first write to the chip" \
	"$(head -n1 "$tmp/pwm.seen" 2>/dev/null)" "90"
# fan_mode none during the stage: the record stays in force, said once, and
# the reassert still goes to the chip that was taken.
fan_conf fan_mode=none pwm_full=255 pwm_idle=0
echo 128 > "$HW/hwmon0/pwm1"; : > "$tmp/syslog"; fresh_status
fan_daemon 8
chk "with fan_mode none since, the stage keeps the recorded fan forced" \
	"$(st STAGE)/$(chip 0)/$(st FAN_TAKEN)" "0/255/1/pwm"
chk "and the status names the recorded fan in control, the setting apart" \
	"$(sfield fan_mode)/$(sfield fan_control)/$(sfield fan_taken)/$(sfield fan_view)/$(
	sfield fan_state)" "none/pwm/pwm/pwm/255"
chk "and says once at warning that the new settings wait for the next takeover" \
	"$(grep -c 'fan settings changed since the fan was taken over' "$STATE_DIR/log")/$(
	prio 'fan settings changed since the fan was taken over')" "1/daemon.warning"
fan_reset
chk "reset hands the recorded fan back and drops the record" \
	"$fan_rc/$(chip 0)/$(st FAN_TAKEN)/$(st FAN_SAVED_PWM)/$(st RESET_FAILED)" "0/90/1///"

# pwm_path moved to a second chip during the stage. A restored stage takes the
# fan over too, and saves the record to the persisted copy before the write.
fan_clean; plant_chip 0 fan0 90 1; plant_chip 1 fan1 40 1; plant_persist
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0 pwm_path="$HW/hwmon0/pwm1"
fan_daemon 3
chk "a restored stage takes the configured chip over" \
	"$(chip 0)/$(chip 1)/$(st FAN_T_DEV)" "255/1/40/1/$DEVICES_ROOT/platform/fan0"
chk "and its record is in the persisted copy" \
	"$(field "$PERSIST_DIR/state" FAN_BOOT)/$(field "$PERSIST_DIR/state" FAN_SAVED_PWM)" "$BOOT1/90"
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0 pwm_path="$HW/hwmon1/pwm1"
fresh_status
fan_daemon 3
chk "with pwm_path on another chip since, the stage leaves that chip alone" \
	"$(chip 0)/$(chip 1)" "255/1/40/1"
chk "and the status reads the recorded chip, not the configured one" \
	"$(sfield fan_control)/$(sfield fan_state)/$(sfield fan_percent)" "pwm/255/"
fan_reset
chk "and reset hands the first chip back and never writes the second" \
	"$fan_rc/$(chip 0)/$(chip 1)/$(st FAN_TAKEN)" "0/90/1/40/1/"

# The polarity belongs to the record too. An inverted chip configured during
# the stage must not get its full speed value written to the recorded one,
# which would stop that fan, and no polarity at all must not stop the reassert.
fan_clean; plant_chip 0 fan0 90 1; plant_chip 1 fan1 40 1; plant_persist
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0 pwm_path="$HW/hwmon0/pwm1"
fresh_status
fan_daemon 3
chk "the record keeps the full speed value it forced" "$(chip 0)/$(st FAN_T_FULL)" "255/1/255"
chk "with settings that still fit the record the status shows its percentage" \
	"$(sfield fan_control)/$(sfield fan_state)/$(sfield fan_max)/$(sfield fan_percent)" \
	"pwm/255/255/100"
fan_conf fan_mode=pwm pwm_full=1 pwm_idle=255 pwm_path="$HW/hwmon1/pwm1"
echo 128 > "$HW/hwmon0/pwm1"; fresh_status
fan_daemon 3
chk "an inverted polarity set during the stage never reaches the recorded chip" \
	"$(chip 0)/$(chip 1)" "255/1/40/1"
chk "and the status reads the recorded chip without scaling it by the new polarity" \
	"$(sfield fan_state)/$(sfield fan_max)/$(sfield fan_percent)" "255//"
fan_conf fan_mode=pwm
echo 128 > "$HW/hwmon0/pwm1"
fan_daemon 3
chk "and without any polarity configured the recorded chip is still reasserted" \
	"$(chip 0)" "255/1"
fan_reset
chk "reset hands it back" "$fan_rc/$(chip 0)" "0/90/1"

# pwm_enable_path is only ever the output's own: pwm_path on a chip without a
# mode file, next to a pwmfan chip that has one.
fan_clean; mkdir -p "$HW/hwmon0" "$DEVICES_ROOT/platform/nct"
echo nct6775 > "$HW/hwmon0/name"; echo 90 > "$HW/hwmon0/pwm1"
ln -s "$DEVICES_ROOT/platform/nct" "$HW/hwmon0/device"
plant_chip 1 fan1 40 2; plant_persist
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0 pwm_path="$HW/hwmon0/pwm1"
fan_daemon 3
chk "a pwm_path without its own mode file never takes another chip's" \
	"$(cat "$HW/hwmon0/pwm1")/$(chip 1)/$(st FAN_UNRESOLVED)/$(st FAN_T_NAME)" "255/40/2/0/nct6775"
fan_reset
chk "and its record hands that chip back" "$fan_rc/$(cat "$HW/hwmon0/pwm1")/$(chip 1)" "0/90/40/2"

# A configured pwm_enable_path belongs to the configured pwm_path. Where that
# output is unusable and detection picks another chip, the mode file goes with it.
fan_clean; mkdir -p "$HW/hwmon0" "$DEVICES_ROOT/platform/nct"
echo nct6775 > "$HW/hwmon0/name"; echo 90 > "$HW/hwmon0/pwm1"; echo 2 > "$HW/hwmon0/pwm1_enable"
ln -s "$DEVICES_ROOT/platform/nct" "$HW/hwmon0/device"
plant_chip 1 fan1 40 2; plant_persist
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0 pwm_path="$HW/hwmon0/pwm9" \
	pwm_enable_path="$HW/hwmon0/pwm1_enable"
fan_daemon 3
chk "a detected chip that replaces an unusable pwm_path is forced with its own mode file" \
	"$(chip 1)/$(cat "$HW/hwmon0/pwm1")/$(cat "$HW/hwmon0/pwm1_enable")/$(st FAN_UNRESOLVED)" \
	"255/1/90/2/0"
fan_reset
# Mode 2 again: the chip drives the duty cycle, so 255 stays in the stand-in file.
chk "and reset puts its mode back, the configured chip's mode file never written" \
	"$fan_rc/$(chip 1)/$(cat "$HW/hwmon0/pwm1_enable")" "0/255/2/2"

# The output's own mode file named by another path to it is still its own.
fan_clean; plant_chip 0 fan0 90 1; ln -s hwmon0 "$HW/fanchip"; plant_persist
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0 pwm_path="$HW/hwmon0/pwm1" \
	pwm_enable_path="$HW/fanchip/pwm1_enable"
fan_daemon 3
chk "a pwm_enable_path that resolves to the output's own mode file is recorded" \
	"$(chip 0)/$(st FAN_TAKEN)/$(st FAN_UNRESOLVED)" "255/1/pwm/0"
fan_reset
chk "and handed back" "$fan_rc/$(chip 0)" "0/90/1"

# The takeover save keeps the stage as loaded: a daemon killed while the stage
# 1 hook runs must enter stage 1 again after its restart, with the values the
# chip had before the takeover.
fan_clean; plant_chip 0 fan0 90 1; mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/stage1" <<HOOK_END
#!/bin/sh
echo run >> "$tmp/stage1.calls"
[ -e "$tmp/stage1.block" ] || exit 0
: > "$tmp/stage1.started"
i=0
while [ -e "$tmp/stage1.block" ] && [ "\$i" -lt 30 ]; do sleep 1; i=\$((i + 1)); done
HOOK_END
chmod 0755 "$HOOK_DIR/stage1"
rm -f "$tmp/stage1.calls" "$tmp/stage1.started"; : > "$tmp/stage1.block"
echo 85000 > "$TR/thermal_zone0/temp"
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0 stage1_action=command
env THERMAL_ROOT="$TR" HWMON_ROOT="$HW" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
pid=$!
wait_file "$tmp/stage1.started" 20 || true
chk "the stage 1 hook runs after the fan was taken over" "$(chip 0)/$(st FAN_SAVED_PWM)" "255/1/90"
kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$tmp/stage1.block"
chk "a daemon killed during the stage actions left the stage it had loaded" \
	"$(st STAGE)/$(st FAN_TAKEN)" "-1/pwm"
fan_daemon 12
chk "after the restart stage 1 is entered again and its hook runs again" \
	"$(st STAGE)/$(wc -l < "$tmp/stage1.calls" | tr -d ' ')" "1/2"
chk "with the values the chip had before the takeover" \
	"$(st FAN_SAVED_PWM)/$(st FAN_SAVED_ENABLE)/$(chip 0)" "90/1/255/1"
rm -f "$HOOK_DIR/stage1"

# An unresolved record and a new stage: the configured fan is forced without a
# record or saved values of its own. It stays forced past a reset, and only a
# reset after fan-forget hands it to automatic mode.
fan_clean; plant_chip 0 fan0 90 1
plant_state -1 FAN_UNRESOLVED=1 FAN_SAVED_PWM=33 FAN_SAVED_ENABLE=1
echo 75000 > "$TR/thermal_zone0/temp"
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
fan_daemon 8
chk "with an unresolved record a new stage forces the configured fan and records nothing" \
	"$(st STAGE)/$(chip 0)/$(st FAN_TAKEN)/$(st FAN_UNRESOLVED)/$(st FAN_SAVED_PWM)" \
	"0/255/1//1/33"
fan_reset
chk "a reset leaves that fan forced" "$fan_rc/$(chip 0)" "1/255/1"
fan_forget; fan_reset
chk "after fan-forget the next reset hands it to automatic mode" \
	"$fan_rc/$(cat "$HW/hwmon0/pwm1_enable")" "0/2"

# fan_cooling_device_type changed during the stage, to a second planted pair.
fan_clean; mkdir -p "$DEVICES_ROOT/platform/fan0"
ln -s "$DEVICES_ROOT/platform/fan0" "$TR/cooling_device0/device"
z1="$TR/thermal_zone1"; c1="$TR/cooling_device1"; mkdir -p "$z1" "$c1"
echo other-fan > "$c1/type"; echo 2 > "$c1/max_state"; echo 0 > "$c1/cur_state"
echo board-thermal > "$z1/type"; echo bang_bang > "$z1/policy"; echo 40000 > "$z1/temp"
ln -s ../cooling_device1 "$z1/cdev0"
plant_persist
fan_conf fan_mode=cooling_device
fan_daemon 3
chk "a restored stage takes the cooling device and its zone over" \
	"$(cat "$TR/thermal_zone0/policy")/$(cat "$TR/cooling_device0/cur_state")/$(st FAN_TAKEN)/$(
	st FAN_T_NAME)/$(st FAN_T_DEV)/$(st FAN_T_ZONE)/$(st FAN_SAVED_POLICY)" \
	"user_space/3/cooling_device/pwm-fan/$DEVICES_ROOT/platform/fan0/cpu-thermal/step_wise"
fan_conf fan_mode=cooling_device fan_cooling_device_type=other-fan
fan_reset
chk "with another cooling device type since, reset hands the original zone back" \
	"$fan_rc/$(cat "$TR/thermal_zone0/policy")/$(cat "$z1/policy")/$(cat "$c1/cur_state")" \
	"0/step_wise/bang_bang/0"

# The chip is gone at reset: the stage clears, the fan is listed, the record
# stays. Back again, the next reset hands it back.
fan_clean; plant_chip 0 fan0 90 1; plant_persist
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
fan_daemon 3
mv "$HW/hwmon0" "$tmp/hwmon0.away"
fan_reset
chk "a fan that is gone at reset fails it, the stage clears and the record stays" \
	"$fan_rc/$(st STAGE)/$(st RESET_FAILED)/$(st FAN_TAKEN)/$(st FAN_SAVED_PWM)" "1/-1/fan/pwm/90"
chk "and a restore is pending" "$(pending)" "1"
mv "$tmp/hwmon0.away" "$HW/hwmon0"
fan_reset
chk "once it is back, the next reset hands it back and drops the record" \
	"$fan_rc/$(chip 0)/$(st RESET_FAILED)/$(st FAN_TAKEN)/$(pending)" "0/90/1///0"

# Renumbered: the chip is hwmon3 now, and another pwmfan chip on another
# device took hwmon0. The release goes by identity.
fan_clean; plant_chip 0 fan0 90 1; plant_persist
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
fan_daemon 3
rm -rf "$HW"; plant_chip 3 fan0 255 1; plant_chip 0 fan9 40 1
fan_reset
chk "after renumbering, reset finds the chip by identity and leaves the other one alone" \
	"$fan_rc/$(chip 3)/$(chip 0)" "0/90/1/40/1"

# A daemon killed during a restore, after the takeover save: the record is only
# in the persisted copy, there is no working state yet. A reset that gets the
# lock before the restarted daemon still goes by that record.
fan_clean; plant_chip 3 fan0 255 1; plant_chip 0 fan9 40 1
# shellcheck disable=SC2086 # PWM_REC holds five state lines
plant_persist $PWM_REC "FAN_T_DEV=$DEVICES_ROOT/platform/fan0" FAN_SAVED_PWM=90 \
	FAN_SAVED_ENABLE=1
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
fan_reset
chk "a reset without a working state hands back the chip the persisted record names" \
	"$fan_rc/$(chip 3)/$(chip 0)/$([ -e "$PERSIST_DIR/state" ] && echo kept)/$(st FAN_TAKEN)" \
	"0/90/1/40/1//"

# The same, but the record is from an earlier boot: the reset drops it as a
# load does, never writes its saved values, and releases the configured fan.
fan_clean; plant_chip 3 fan0 255 1; plant_chip 0 fan9 40 1
plant_persist FAN_TAKEN=pwm "FAN_BOOT=$BOOT0" FAN_T_NAME=pwmfan FAN_T_ATTR=pwm1 \
	"FAN_T_DEV=$DEVICES_ROOT/platform/fan0" FAN_T_FULL=255 FAN_SAVED_PWM=90 FAN_SAVED_ENABLE=1
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
fan_reset
chk "a reset without a working state drops a persisted record of an earlier boot" \
	"$fan_rc/$(chip 3)/$(chip 0)/$([ -e "$PERSIST_DIR/state" ] && echo kept)/$(st FAN_TAKEN)" \
	"0/255/1/40/2//"
chk "and says so as a notice" \
	"$(prio 'fan takeover record from an earlier boot discarded')" "daemon.notice"

# Two chips of the recorded name on the recorded device: no single match.
fan_clean; plant_chip 0 fan0 255 1; plant_chip 1 fan0 255 1
# shellcheck disable=SC2086 # PWM_REC holds five state lines
plant_state 0 $PWM_REC "FAN_T_DEV=$DEVICES_ROOT/platform/fan0" FAN_SAVED_PWM=90 \
	FAN_SAVED_ENABLE=1
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
fan_reset
chk "two chips match the record: reset writes neither and keeps it" \
	"$fan_rc/$(chip 0)/$(chip 1)/$(st RESET_FAILED)/$(st FAN_TAKEN)/$(st FAN_SAVED_PWM)" \
	"1/255/1/255/1/fan/pwm/90"
chk "and says so at crit" "$(prio 'the fan taken over (pwm pwmfan) is not found exactly once')" \
	"daemon.crit"

# A device path with .. passes the character check but not the path guard.
fan_clean; plant_chip 0 fan0 255 1
# shellcheck disable=SC2086 # PWM_REC holds five state lines
plant_state -1 RESET_FAILED=fan $PWM_REC "FAN_T_DEV=$DEVICES_ROOT/platform/../platform/fan0" \
	FAN_SAVED_PWM=90 FAN_SAVED_ENABLE=1
fan_reset
chk "a recorded device path with .. is no identity: unresolved, nothing written" \
	"$fan_rc/$(chip 0)/$(st FAN_UNRESOLVED)/$(st FAN_T_DEV)/$(st FAN_SAVED_PWM)/$(pending)" \
	"1/255/1/1//90/1"
chk "and the log says what the operator can do" \
	"$(prio "the fan taken over has no usable record, nothing was handed back")" "daemon.crit"

# Older states: saved values without any identity are unresolved, both
# backends. Nothing is written, the values stay.
fan_clean; plant_chip 0 fan0 255 1
plant_state 0 FAN_SAVED_PWM=90 FAN_SAVED_ENABLE=1
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
fan_reset
chk "an older state with saved pwm values is unresolved and writes nothing" \
	"$fan_rc/$(chip 0)/$(st STAGE)/$(st RESET_FAILED)/$(st FAN_UNRESOLVED)/$(
	st FAN_SAVED_PWM)/$(st FAN_SAVED_ENABLE)/$(cat "$tmp/fan.err")" \
	"1/255/1/-1/fan/1/90/1/could not undo: fan"
fan_clean; echo user_space > "$TR/thermal_zone0/policy"; echo 3 > "$TR/cooling_device0/cur_state"
plant_state 0 FAN_SAVED_POLICY=step_wise
fan_conf fan_mode=cooling_device
fan_reset
chk "and so is one with a saved governor" \
	"$fan_rc/$(cat "$TR/thermal_zone0/policy")/$(st FAN_UNRESOLVED)/$(st FAN_SAVED_POLICY)" \
	"1/user_space/1/step_wise"
# 2.0.0 saved nothing: its fan is handed back as it always was.
fan_clean; echo user_space > "$TR/thermal_zone0/policy"; plant_state 0
fan_conf fan_mode=cooling_device fan_governor=fair_share
fan_reset
chk "a 2.0.0 state with nothing saved hands the zone to fan_governor" \
	"$fan_rc/$(cat "$TR/thermal_zone0/policy")/$(st FAN_UNRESOLVED)/$(st RESET_FAILED)" \
	"0/fair_share/0/"

# The working state lost within the same boot: a persisted copy without a boot
# id is no evidence of a reboot, its saved values stay unresolved.
fan_clean; plant_chip 0 fan0 255 1; plant_persist FAN_SAVED_PWM=90 FAN_SAVED_ENABLE=1
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
fan_daemon 3
chk "a legacy persisted copy restored in the same boot keeps its values unresolved" \
	"$(st STAGE)/$(st FAN_UNRESOLVED)/$(st FAN_SAVED_PWM)/$(st FAN_TAKEN)/$(chip 0)" \
	"0/1/90//255/1"
fan_reset
chk "and reset writes nothing to the fan and lists it" \
	"$fan_rc/$(chip 0)/$(st RESET_FAILED)/$(pending)" "1/255/1/fan/1"

# A record from another boot: that forcing ended with it. The restored stage
# takes the fan over afresh.
fan_clean; plant_chip 0 fan0 90 1
plant_persist FAN_TAKEN=pwm "FAN_BOOT=$BOOT0" FAN_T_NAME=pwmfan FAN_T_ATTR=pwm1 \
	"FAN_T_DEV=$DEVICES_ROOT/platform/fan0" FAN_T_FULL=255 FAN_SAVED_PWM=33 FAN_SAVED_ENABLE=2
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
: > "$tmp/syslog"
fan_daemon 3
chk "a record from an earlier boot goes, the restored stage takes the fan over afresh" \
	"$(st FAN_BOOT)/$(st FAN_SAVED_PWM)/$(st FAN_SAVED_ENABLE)/$(chip 0)" "$BOOT1/90/1/255/1"
chk "the persisted copy carries the new record" \
	"$(field "$PERSIST_DIR/state" FAN_BOOT)/$(field "$PERSIST_DIR/state" FAN_SAVED_PWM)" "$BOOT1/90"
chk "and the drop is a notice" \
	"$(prio 'fan takeover record from an earlier boot discarded')" "daemon.notice"
fan_reset
chk "reset hands back what this boot found" "$fan_rc/$(chip 0)" "0/90/1"

# An unresolved record is a pending restore, in status and in the status file.
fan_clean; plant_state -1 FAN_UNRESOLVED=1
fan_conf fan_mode=none
fresh_status; fan_daemon 3
chk "fan_restore_pending is 1 for an unresolved record" "$(pending)/$(sfield fan_restore_pending)" \
	"1/1"

# fan-forget: refused while a stage is active, in the working state or in the
# persisted copy the next start restores.
fan_clean; plant_chip 0 fan0 255 1
# shellcheck disable=SC2086 # PWM_REC holds five state lines
plant_state 0 $PWM_REC FAN_SAVED_PWM=90 FAN_SAVED_ENABLE=1
fan_conf fan_mode=pwm pwm_full=255 pwm_idle=0
before=$(cat "$STATE_DIR/state")
fan_forget
chk "fan-forget refuses while a stage is active and changes nothing" \
	"$fan_rc/$(cat "$tmp/fan.err")/$([ "$(cat "$STATE_DIR/state")" = "$before" ] && echo same ||
	echo changed)/$(chip 0)" "1/a stage is active, clear it first/same/255/1"
plant_state -1 FAN_UNRESOLVED=1 FAN_SAVED_PWM=90; plant_persist FAN_SAVED_PWM=90
before=$(cat "$STATE_DIR/state" "$PERSIST_DIR/state")
fan_forget
chk "and while the persisted copy holds a stage" \
	"$fan_rc/$([ "$(cat "$STATE_DIR/state" "$PERSIST_DIR/state")" = "$before" ] && echo same ||
	echo changed)" "1/same"
# Idle: the record goes from both copies, nothing else does, no hardware is written.
fan_clean; plant_chip 0 fan0 255 1
plant_state -1 RESET_FAILED=wifi_off,fan FAN_UNRESOLVED=1 FAN_SAVED_PWM=90 FAN_SAVED_ENABLE=1
mkdir -p "$PERSIST_DIR"
printf 'STAGE=-1\nRECOVER_N=2\nFAN_SAVED_PWM=90\nFAN_UNRESOLVED=1\nFAN_T_NAME=pwmfan\n' \
	> "$PERSIST_DIR/state"
: > "$tmp/syslog"
fan_forget
chk "fan-forget idle drops the record from the working state and fan from the list" \
	"$fan_rc/$(st FAN_UNRESOLVED)/$(st FAN_SAVED_PWM)/$(st FAN_SAVED_ENABLE)/$(st RESET_FAILED)" \
	"0/0///wifi_off"
chk "and from the persisted copy, where the other keys stay" \
	"$(grep -c '^FAN_' "$PERSIST_DIR/state")/$(field "$PERSIST_DIR/state" RECOVER_N)" "0/2"
chk "and writes no hardware" "$(chip 0)" "255/1"
chk "and logs at notice that the fan was not released" \
	"$(prio 'fan restoration record discarded by the operator, the fan was not released')" \
	"daemon.notice"
fresh_status; fan_daemon 3
chk "a daemon restart does not bring the record back" \
	"$(st FAN_UNRESOLVED)/$(st FAN_SAVED_PWM)/$(sfield fan_restore_pending)/$(chip 0)" "0//0/255/1"
fan_forget
chk "with nothing left to discard fan-forget says so and exits 0" \
	"$fan_rc/$(cat "$tmp/fan.out")" "0/no fan restoration record, nothing was changed"
rm -rf "$HW" "$DEVICES_ROOT" "$z1" "$c1"

# ---- a reset keeps what is still queued -----------------------------------
# A daemon blocked by the reset queues its alert while the reset posts its own
# message. The hook stands in for both: it queues a line, then delivers.
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; plant_state 0; mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/notify" <<HOOK_END
#!/bin/sh
cat >/dev/null
echo "queued while the reset posted" >> "$STATE_DIR/outbox"
HOOK_END
chmod 0755 "$HOOK_DIR/notify"
uci_conf "$IVL" modem_source=none fan_mode=none
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" reset >/dev/null 2>&1 && r=0 || r=$?
chk "a reset that delivers its own message keeps a message queued meanwhile" \
	"$r/$(grep -c 'queued while the reset posted' "$STATE_DIR/outbox" 2>/dev/null)" "0/1"
rm -f "$HOOK_DIR/notify" "$STATE_DIR/outbox"

# ---- a fan that cannot be forced is notified ------------------------------
# The zone policy does not read back, so forcing the fan at stage 1 of 3 fails.
# A notify hook collects what goes out.
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; mkdir -p "$HOOK_DIR"
rm -f "$TR/thermal_zone0/policy"; ln -s /dev/null "$TR/thermal_zone0/policy"
echo 75000 > "$TR/thermal_zone0/temp"
cat > "$HOOK_DIR/notify" <<HOOK_END
#!/bin/sh
cat >> "$tmp/notified"
HOOK_END
chmod 0755 "$HOOK_DIR/notify"
: > "$tmp/notified"; : > "$tmp/syslog"
uci_conf "$IVL" modem_source=none fan_mode=cooling_device
tg_run 12
chk "a fan force that does not read back reaches stage 1 of 3" "$(field "$STATE_DIR/state" STAGE)" "0"
chk "and is notified" \
	"$(grep -c 'stage 0: could not force the fan (mode cooling_device). Check the fan.' "$tmp/notified")" "1"
chk "at crit" "$(prio 'stage 0: could not force the fan')" "daemon.crit"
chk "and the failed takeover keeps its record" \
	"$(field "$STATE_DIR/state" FAN_TAKEN)/$(field "$STATE_DIR/state" FAN_T_ZONE)" \
	"cooling_device/cpu-thermal"
rm -f "$HOOK_DIR/notify"

# ---- collectd emits only plain integers ----------------------------------
# Same filter as the helper, checked here so a change to it cannot go unnoticed.
tg_num() {
	case "$1" in
		''|*[!0-9-]*|-|?*-*) echo "" ;;
		*) echo "$1" ;;
	esac
}
chk "collectd keeps a reading" "$(tg_num 55)" "55"
chk "collectd keeps idle stage -1" "$(tg_num '-1')" "-1"
chk "collectd drops a shell payload" "$(tg_num '1;reboot')" ""
chk "collectd drops a lone dash" "$(tg_num '-')" ""
chk "collectd drops a stray minus" "$(tg_num 1-2)" ""
chk "collectd drops an empty value" "$(tg_num '')" ""

finished=1
if [ "$fail" = 0 ]; then
	echo "integration: all cases passed"
else
	echo "integration: FAILED"
	exit 1
fi
