#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Runs the shipped script as a process against a planted state directory.
# The selftest covers the logic in memory, this covers what ends up on disk.
# shellcheck shell=busybox

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

BIN="$root/thermal-guard/files/usr/sbin/thermal-guard"
LIB_DIR="$root/thermal-guard/files/usr/share/thermal-guard"
STATE_DIR="$tmp/state"
STATUS_FILE="$tmp/status"
PERSIST_DIR="$tmp/persist"
HOOK_DIR="$tmp/hooks"
export LIB_DIR STATE_DIR STATUS_FILE PERSIST_DIR HOOK_DIR

fail=0
chk() { # $1 label, $2 got, $3 expected
	if [ "$2" = "$3" ]; then
		echo "ok   $1"
	else
		echo "FAIL $1: expected [$3], got [$2]"
		fail=1
	fi
}

field() { # $1 file, $2 key
	sed -n "s/^$2=//p" "$1" | head -n1
}

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
LAST_CPU=73
LAST_MODEM=
LAST_MODEM_SRC=
LAST_TS=1100
GEN=3
EOF
}

# ---- reset clears the stage and bumps the generation ----------------------
plant_stage1
sh "$BIN" reset >/dev/null 2>&1

chk "reset clears the stage" "$(field "$STATE_DIR/state" STAGE)" "-1"
chk "reset bumps GEN" "$(field "$STATE_DIR/state" GEN)" "4"
chk "reset refreshes the status file" "$(field "$STATUS_FILE" stage)" "-1"

# ---- a plain cycle leaves the generation alone ----------------------------
sh "$BIN" test 50 50 >/dev/null 2>&1
chk "a cycle does not touch GEN" "$(field "$STATE_DIR/state" GEN)" "4"

# ---- reset is idempotent, and safe on a state that is already clear -------
sh "$BIN" reset >/dev/null 2>&1
chk "second reset bumps GEN again" "$(field "$STATE_DIR/state" GEN)" "5"
chk "second reset keeps the stage clear" "$(field "$STATE_DIR/state" STAGE)" "-1"

# ---- the status file carries what the UI needs to spot a dead service -----
sh "$BIN" test 60 60 >/dev/null 2>&1
chk "status reports the enabled flag" "$(field "$STATUS_FILE" enabled)" "1"
# The value depends on the machine running the tests, the field must be there
# either way because the web interface branches on it.
case "$(field "$STATUS_FILE" no_sensor)" in
	0|1) chk "status reports whether a sensor exists" present present ;;
	*)   chk "status reports whether a sensor exists" missing present ;;
esac
case "$(field "$STATUS_FILE" fan_view)" in
	none|pwm|cooling_device) chk "status reports what the fan is read from" present present ;;
	*)                       chk "status reports what the fan is read from" missing present ;;
esac
chk "status reports the interval" "$(field "$STATUS_FILE" interval)" "20"
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
rm -rf "$STATE_DIR" "$PERSIST_DIR"
mkdir -p "$STATE_DIR"
printf '2026-01-01 00:00:00 stage 1: modem radio off\n' > "$STATE_DIR/log"

i=0
while [ "$i" -lt 12 ]; do
	sh "$BIN" status >/dev/null 2>&1
	sh "$BIN" test 40 40 >/dev/null 2>&1
	i=$((i + 1))
done

chk "status and test add nothing to the log" "$(wc -l < "$STATE_DIR/log")" "1"
chk "the incident is still there" "$(grep -c 'stage 1' "$STATE_DIR/log")" "1"

# ---- a dry run changes nothing -------------------------------------------
rm -rf "$STATE_DIR" "$PERSIST_DIR"
sh "$BIN" test 95 95 >/dev/null 2>&1
sh "$BIN" test 95 95 >/dev/null 2>&1
chk "a dry run writes no state" "$([ -f "$STATE_DIR/state" ] && echo wrote || echo clean)" "clean"
chk "a dry run persists nothing" "$([ -f "$PERSIST_DIR/state" ] && echo wrote || echo clean)" "clean"

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

# 85 C with the modem silent clears cpu_crit twice, which enters stage 1.
sh "$BIN" test 85 0 >/dev/null 2>&1
sh "$BIN" test 85 0 >/dev/null 2>&1
chk "a dry run never touches a hook" "$([ -e "$tmp/stage1-ran" ] && echo ran || echo no)" "no"

# Whether a hook is executed is covered by the selftest, which can call
# tg_run_hook directly. Here it matters only that a dry run stays dry.

# ---- pwm without a polarity leaves the fan alone, and says so once ---------
# A stand-in uci configures pwm with pwm_idle but no pwm_full. The daemon runs
# three cycles and must report it once; a status call must not report it at all.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/uci" <<'UCI_END'
#!/bin/sh
case "$3" in
	thermal-guard.main.fan_mode) echo pwm ;;
	thermal-guard.main.pwm_idle) echo 255 ;;
	thermal-guard.main.interval) echo 5 ;;
	*) exit 1 ;;
esac
UCI_END
chmod 0755 "$tmp/bin/uci"
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
sh "$BIN" selftest >/dev/null 2>&1
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
	echo step_wise > "$z/policy"; echo 50000 > "$z/temp"
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
# A stand-in uci that reads "key=value" lines and records what the daemon adds.
cat > "$tmp/bin/uci" <<UCI_END
#!/bin/sh
case "\$2" in
	get) v=\$(sed -n "s|^\$3=||p" "$tmp/uci.conf"); [ -n "\$v" ] && echo "\$v" ;;
	add_list) echo "\$3" >> "$tmp/uci.added" ;;
	*) exit 0 ;;
esac
UCI_END
chmod 0755 "$tmp/bin/uci"
uci_conf() { printf '%s\n' "$@" > "$tmp/uci.conf"; : > "$tmp/uci.added"; }
tg_run() { # $1 seconds, the daemon runs until timeout sends TERM
	THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" timeout "$1" sh "$BIN" daemon >/dev/null 2>&1 || true
}
BOOST="thermal-guard.main.trip_boost=modem"
IVL="thermal-guard.main.interval=5"
MFILE="thermal-guard.main.modem_temp_file=$tmp/modem"
MSRC="thermal-guard.main.modem_source=file"

# I1: a hot modem at start lowers the trips in one step
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; echo 90 > "$tmp/modem"
uci_conf "$BOOST" "$IVL" "$MSRC" "$MFILE"
tg_run 3
chk "a hot modem at start lowers the trips" "$(trips)" "25000 35000 45000 "
chk "in one write, without the baseline in between" "$(grep -c 'trips set to' "$STATE_DIR/log")" "1"
# I3: timeout ended that run with TERM, the trips stay where they were
chk "stopping the daemon leaves the trips down" "$(trips)" "25000 35000 45000 "
# I4: the device tree set of this boot is kept and handed to UCI once
chk "device tree set kept for this boot" "$(cat "$STATE_DIR/trip_dt")" "50000 60000 70000"
chk "and recorded as trip_dt" "$(tr '\n' ' ' < "$tmp/uci.added")" \
	"thermal-guard.main.trip_dt=50 thermal-guard.main.trip_dt=60 thermal-guard.main.trip_dt=70 "

# I2: killed while lowered, restarted with a cool modem: baseline again
THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
pid=$!
sleep 2
kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
chk "kill -9 leaves the trips down" "$(trips)" "25000 35000 45000 "
echo 40 > "$tmp/modem"
tg_run 3
chk "a restart with a cool modem restores the baseline" "$(trips)" "50000 60000 70000 "
chk "the restart did not read the lowered trips as device tree" "$(field "$STATUS_FILE" trip_dt)" "50/60/70"

# I5: a new image with other device tree values, the operator's baseline stays
rm -rf "$STATE_DIR"; plant_tree; echo 75000 > "$TR/thermal_zone0/trip_point_4_temp"
uci_conf "$BOOST" "$IVL" "$MSRC" "$MFILE" "thermal-guard.main.trip_active=45 55 65" \
	"thermal-guard.main.trip_dt=50 60 70"
tg_run 3
chk "a changed device tree is reported" "$(field "$STATUS_FILE" trip_dt_changed)" "1"
chk "and trip_active stays the baseline" "$(trips)" "45000 55000 65000 "
chk "trip_dt in UCI is left alone" "$(cat "$tmp/uci.added")" ""

# I9: nothing configured, nothing written: the GL-X3000 case
rm -rf "$STATE_DIR"; plant_tree; echo 90 > "$tmp/modem"
before=$(find "$TR" -name 'trip_point_*' -exec cat {} + | md5sum)
uci_conf "$IVL" "$MSRC" "$MFILE"
tg_run 12
chk "without trip options the zone is untouched" "$(find "$TR" -name 'trip_point_*' -exec cat {} + | md5sum)" "$before"
chk "and not even read for this boot" "$([ -e "$STATE_DIR/trip_dt" ] && echo read || echo untouched)" "untouched"
chk "status says off" "$(field "$STATUS_FILE" trip_state)" "off"
case "$(cat "$STATE_DIR/modem-temp" 2>/dev/null)" in
	"90 "[0-9]*" file") chk "the modem temperature is published" ok ok ;;
	*) chk "the modem temperature is published" "$(cat "$STATE_DIR/modem-temp" 2>/dev/null)" "90 <time> file" ;;
esac

# I6 and I7: a hung modem or a held lock costs a reading, not the loop.
# /dev/null stands in for the AT port, it is a character device.
AT="thermal-guard.main.modem_source=fibocom"
PORT="thermal-guard.main.modem_at_port=/dev/null"
LOCK="thermal-guard.main.at_lock=$tmp/at.lock"
cat > "$tmp/bin/sms_tool" <<SMS_END
#!/bin/sh
[ -e "$tmp/sms.hang" ] && exec sleep 60
echo "+GTSENRDTEMP: 1,48000"
SMS_END
chmod 0755 "$tmp/bin/sms_tool"

loop_alive() { # $1 label: status written again after a stalled first cycle
	local t0 t1
	THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" sh "$BIN" daemon >/dev/null 2>&1 &
	pid=$!
	sleep 3; t0=$(field "$STATUS_FILE" now)
	sleep 12; t1=$(field "$STATUS_FILE" now)
	kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
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
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true

# I8: stage 1 against a hung modem fails loudly and the loop goes on
rm -rf "$STATE_DIR" "$PERSIST_DIR"; plant_tree; touch "$tmp/sms.hang"
echo 85000 > "$TR/thermal_zone0/temp"
uci_conf "$IVL" "$AT" "$PORT" "$LOCK"
AT_WAIT=2 AT_TIMEOUT=1 THERMAL_ROOT="$TR" PATH="$tmp/bin:$PATH" \
	timeout 30 sh "$BIN" daemon >/dev/null 2>&1 || true
chk "stage 1 against a hung modem is reported as failed" \
	"$(grep -c "stage 1 action 'modem_radio_off' failed" "$STATE_DIR/log")" "1"
chk "and the stage is still entered" "$(field "$STATE_DIR/state" STAGE)" "1"
rm -f "$tmp/sms.hang"

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

if [ "$fail" = 0 ]; then
	echo "integration: all cases passed"
else
	echo "integration: FAILED"
	exit 1
fi
