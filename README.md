# thermal-guard

Overheating protection for OpenWrt routers with staged mitigation.

![Status page on a Banana Pi R3 Mini](screenshots/status-bpi-r3-mini.png)

## Why this exists

The idea for this project came after a fan malfunction on my Banana Pi R3 Mini
damaged its Fibocom FM350-GL 5G module beyond repair. An inexpensive part
failed and took a much pricier one with it. Since one of my BPI R3 Minis runs
in a motorhome, I did not want to go through that again and set out to build
something that prevents it. This package is the result.

A better fan controller would not have helped: the one on the board was
convinced it had the fan at full speed. What was missing was something that
ignores what the fan is supposed to be doing and only looks at the temperature.

**This is not a fan controller.** OpenWrt has several of those and they do the
job better: they map temperature onto a curve and keep the box in its normal
band. This one does nothing at all until a threshold is crossed, and then does
something drastic that does not undo itself. Thermostat and thermal fuse, two
layers rather than two opinions.

So where a fan controller is already installed, leave it in charge: `fan_mode`
is `none` by default, and that is the regular configuration for such a board,
not a workaround. The built-in fan handling exists for boards that have nothing else,
and "force it to maximum" is a poor substitute for a curve. What this package
adds is the layer above: the one that assumes the controller can fail, or can
be wrong, and acts on the temperature rather than on what the fan reports.

A fan that stops is rarely noticed until something dies. `thermal-guard` watches
SoC and modem temperature and, when the box runs hot, escalates in three stages:

| Stage | Default action | Triggered by |
|---|---|---|
| 1 of 3 | Warning; fan forced to full speed where `fan_mode` lets the daemon drive it | `cpu_warn` or `modem_warn` reached |
| 2 of 3 | Modem radio off (`AT+CFUN=4`) | `cpu_crit`/`modem_crit`, or stage 1 held for `hold_minutes` without any drop |
| 3 of 3 | Wi-Fi off | `cpu_emergency`, or stage 2 held for `hold_minutes` while still climbing |

The web interface counts stages from one, the daemon and the status file count
them from zero, so stage 1 of 3 is `stage=0` in `thermal-guard status`. What
stages 2 and 3 do is configurable; the table shows the defaults. Each action is
read back rather than assumed: the modem is asked for its state (`AT+CFUN?`),
`interface_down` waits for netifd to report the interface down. An action that
does not confirm counts as failed, and the failure is notified.

Three design decisions worth knowing before you deploy it:

* **Stages never roll back on their own.** Cooling down is reported once, the
  stage stays. A fan that failed once will fail again, and a silent recovery
  hides the fault. Clearing is an operator decision: `thermal-guard reset`.
* **A reboot does not clear them either.** A stage change is mirrored to
  `/etc/thermal-guard/state`, and the daemon reapplies it at startup. The box
  did not get a new fan while it was down, so coming back up with the modem
  enabled would just repeat the incident. The restore is logged and notified.
* **A crash leaves the fan running.** The daemon only hands the fan back on an
  explicit reset, so dying mid-incident is the safe direction.

If a restored stage ever locks you out, reach the box over a wired port or
serial and run `thermal-guard reset`. Only a device that reached stage 3 can
have Wi-Fi switched off at boot, and such a device has a fan and a modem, so it
has wired ports too.

Every transition needs two consecutive readings above the threshold, which keeps
sensor glitches from triggering anything. A missing reading counts as "condition
met", so a modem that stopped answering never blocks an escalation.

Escalating from stage 1 on time alone, when the temperature has not dropped, is
the part that earns its keep. The guard never asks whether the fan turned; it
asks whether the box got cooler. That covers a fan that failed, a fan cable
that came off, and the case that prompted this package: a fan controller whose
pwm polarity was configured the wrong way round, which stopped the fan while
reporting that it had gone to full speed. No software can tell those apart on
a board without a tachometer, and none of them have to be told apart, because
the answer is the same. Set `hold_minutes` with that in mind: it is how long a
stage is given to prove it worked before the next one starts.

## Screenshots

The status page on two boards: a Banana Pi R3 Mini with a Fibocom modem, an NVMe
drive and the MediaTek vendor Wi-Fi driver, where another program drives the fan,
and a GL-iNet GL-X3000 with a Quectel modem, where the kernel does. Wi-Fi 1 and 2
come from `iwpriv` on the one and from hwmon on the other.

<table>
  <tr>
    <td><img src="screenshots/status-bpi-r3-mini.png" alt="Status page, Banana Pi R3 Mini"></td>
    <td><img src="screenshots/status-gl-x3000.png" alt="Status page, GL-X3000"></td>
  </tr>
</table>

The same readings in a block on the LuCI overview page:

<table>
  <tr>
    <td><img src="screenshots/overview-bpi-r3-mini.png" alt="Overview block, Banana Pi R3 Mini"></td>
    <td><img src="screenshots/overview-gl-x3000.png" alt="Overview block, GL-X3000"></td>
  </tr>
</table>

<details>
<summary>Configuration page, System → Thermal Guard</summary>

General

![General tab](screenshots/settings-general.png)

Thresholds for the three stages

![Thresholds tab](screenshots/settings-thresholds.png)

Fan, including the switching temperatures of a kernel-driven fan

![Fan tab](screenshots/settings-fan.png)

Modem, Fibocom on the Banana Pi and Quectel on the GL-X3000

![Modem tab, Fibocom](screenshots/settings-modem-fibocom.png)
![Modem tab, Quectel](screenshots/settings-modem-quectel.png)

Actions and notifications

![Actions tab](screenshots/settings-actions.png)

</details>

## Install

```sh
opkg install thermal-guard luci-app-thermal-guard   # or: apk add ...
/etc/init.d/thermal-guard enable
/etc/init.d/thermal-guard start
```

Two LuCI pages: **Status → Thermal Guard** shows the temperatures, the fan and
the current stage, and clears the stages; **System → Thermal Guard** edits the
configuration. A changed option is picked up within one interval, so Apply
needs no restart.

The package depends on `coreutils-timeout`: every AT query runs under a time
limit, so a hung modem costs one reading instead of the whole loop. Optional
runtime helpers, none of them a hard dependency: `sms_tool` for the modem AT
commands, `flock` for the AT lock, `ip` for the uplink check, and `curl` for
notification headers.

## Configuration

`/etc/config/thermal-guard`, section `main`. Defaults leave the fan alone and
read a Quectel or Fibocom modem; driving the fan is an explicit choice.

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `1` | Pauses the checks when `0`; stages and the fan stay until a reset |
| `interval` | `20` | Seconds between readings, minimum 5 |
| `cpu_warn` / `cpu_crit` / `cpu_emergency` | `70` / `80` / `90` | SoC thresholds in °C, must be ordered |
| `modem_warn` / `modem_crit` | `80` / `88` | Modem thresholds in °C |
| `hold_minutes` | `3` | How long a stage must persist before time alone escalates |
| `hysteresis` | `10` | Degrees below the warn thresholds that count as cooled down |
| `cpu_temp_path` | `/sys/class/thermal/thermal_zone0/temp` | Sysfs source under `/sys/class/thermal/` or `/sys/class/hwmon/`, degrees or millidegrees. A sensor is looked for when this does not read |
| `fan_mode` | `none` | `cooling_device`, `pwm`, `auto`. `auto` takes the cooling device if there is one, otherwise it stays `none`; it never picks `pwm` |
| `fan_cooling_device_type` | `pwm-fan` | Type string used to find the cooling device |
| `fan_governor` | `step_wise` | Governor the zone is handed back to on reset |
| `pwm_path`, `pwm_enable_path` | unset | `pwm` mode only; found by hwmon name when left empty |
| `pwm_full`, `pwm_idle` | unset | Raw values for fastest and slowest, both required for `pwm`. Without both the fan is left alone |
| `modem_source` | `auto` | `quectel`, `fibocom`, `file`, `command`, `none` |
| `modem_at_port` | `auto` | Serial port for AT commands |
| `modem_temp_file` | unset | Source for `file` mode; `command` mode reads the `modem-temp` hook |
| `at_lock` | `/var/lock/modem-at.lock` | Shared lock. Every other AT user on this port has to take the same one, see below |
| `trip_boost` | `off` | `modem` lowers the fan's trip points while the modem runs hotter than the CPU, see below |
| `trip_boost_offset` | `15` | Degrees the modem may run above the CPU before the trips go down, 0 to 40 |
| `trip_active` | unset | List, baseline of the fan's active trips in °C, ascending, one per trip. Unset means the device tree values |
| `trip_dt` | set by the daemon | Device tree trips the baseline was made for; a new image with other values is reported |
| `stage1_action` / `stage2_action` | `modem_radio_off` / `wifi_off` | Also `interface_down`, `command`, which runs a hook, or `none` |
| `modem_radio_off_at` | `AT+CFUN=4` | Or `AT+CFUN=0` for a modem without flight mode. Nothing else is accepted |
| `action_interface` | unset | Interface `interface_down` takes down; `uplink_interface` when unset |
| `notify_url` | unset | The warning text is posted here |
| `notify_header` | unset | Extra header for the post, needs `curl` |
| `uplink_interface` | unset | Modem interface name, lets the daemon tell whether another uplink exists |

### Fan modes

`cooling_device` sets the cooling device to its maximum step, taking the thermal
zone off its governor first if one drives it. Prefer this mode wherever the
board offers it: `max_state` means maximum cooling whichever way the device tree
runs its `cooling-levels`, so this mode cannot get the polarity wrong.

A cooling device that no thermal zone binds still works, there is simply nothing
to take over and nothing to hand back. Whether one is bound is worth knowing,
because it decides whether there is a kernel backstop underneath at all:

```sh
ls /sys/class/thermal/thermal_zone*/cdev* 2>/dev/null || echo "no zone drives any cooling device"
```

Where nothing is printed, the device tree defines no `cooling-maps`, the zone's
trip points fire into nothing, and the only regulation on the board is whatever
runs in userspace. That is worth fixing in the device tree, because it is the
difference between a fan controller that can fail safely and one whose failure
nobody catches until this package escalates.

`pwm` writes the duty cycle to sysfs directly. Use it on boards where the fan is
not wired into a thermal zone. Before taking the chip over, the daemon records
what it was set to and writes that back on reset, so nothing has to be
configured for the way out. Leaving `pwm_path` empty is fine: the fan chip is
looked up by its hwmon name, which survives the renumbering that happens when
another sensor appears.

Polarity is not something the daemon can work out, and getting it wrong stops
the fan in an emergency instead of speeding it up. Several boards, the Banana Pi
R3 Mini among them, run the signal inverted: `1` is full speed and `255` stops
the fan. So there is no default: `pwm` needs both `pwm_full` and `pwm_idle`, and
with either missing the daemon logs it once and leaves the fan alone. For the
same reason `auto` never resolves to `pwm`. Confirm the values by ear rather
than by reading the number.

If another service already controls the fan, keep `fan_mode` at `none`. Stage
1 of 3 is then a warning only. Setting a fan mode anyway works: the daemon notices when a value it wrote has been replaced, says so in the log and
reasserts, but two controllers writing one file is worth avoiding, and the
other one almost certainly has the better curve. Nothing is lost: the stage
that forces the fan is the one a working controller has already covered, and
the stages that matter come after it.

### Trip management

Where the kernel drives the fan through a thermal zone, it only compares the
CPU against the zone's trip points; a modem running hotter than the CPU does not
reach it. With `trip_boost 'modem'` the daemon lowers the zone's active trips by

```
delta = (modem - trip_boost_offset) - cpu, 0 if negative,
        rounded up to 5 K, at most 40 K
```

which is the same as regulating on `max(cpu, modem - offset)`, but leaves the
regulator in the kernel. The zone is the one whose `cdevN` points at the fan's
cooling device, the trips are the `active` ones bound to it, whatever their
numbers are. `hot` and `critical` are never written.

The trips only ever go below the baseline, never above it. A wrong modem reading
can therefore only make the fan louder, not slower. A missing reading keeps the
trips where they are, raising them again takes three cool readings in a row, and
not at all while a stage is in force. Stopping the daemon leaves them as they
are; setting `trip_boost 'off'` with `trip_active` unset hands the zone its
device tree values back once and leaves it alone from then on.

Nothing is written unless `trip_boost` or `trip_active` is set, so a board whose
fan the kernel already drives keeps its trips as they are.

### Sharing the modem with another program

A modem answers two overlapping AT conversations with nothing useful, and the
program that gets the nothing rarely says so. This daemon takes `at_lock` around
every query. **Anything else on the box that talks to the same port has to take
the same lock**, or both readings become unreliable.

That is not a theoretical concern. On a Banana Pi R3 Mini this package was
installed next to a fan controller that queried the modem without a lock. The
collisions garbled the controller's modem reading, its control temperature
collapsed, and it set the fan to its minimum while the board sat at 68 °C.
Nothing in either program reported a fault: the fan controller believed it was
regulating correctly, and this daemon believed the fan was somebody else's
business. The symptom appeared at the fan, the cause was at the serial port.

If the other program cannot be changed, give it the modem and set
`modem_source` to `none` here, but understand the cost. A modem die runs
appreciably hotter than the SoC, commonly by 10 to 20 K, so protecting it
through the processor thresholds alone means acting late for the part that is
actually at risk. Prefer fixing the lock.

Programs that only need the temperature do not have to ask the modem at all.
After every good reading the daemon writes one line to
`/var/run/thermal-guard/modem-temp`:

```
47 1790150400 at
```

degrees, Unix time of the reading, source (`at`, `file` or `command`). The file
is replaced atomically and not touched when a reading fails, so a reader that
finds it older than three intervals should treat the value as unknown.

### Notifications

Set `notify_url` and the message is posted there as the request body. That
covers ntfy, Gotify, Matrix, Slack and most other things you would want to be
woken by, and it needs no shell command in the configuration to do it.

```
option notify_url 'https://ntfy.sh/my-topic'
```

`curl` is used when it is installed, otherwise `uclient-fetch` from the OpenWrt
base. Only the former can send `notify_header`, so an authenticated webhook
either needs `curl` installed or a service that takes its token in the URL. The
url and the header are passed through a file rather than the command line,
since `/proc` would otherwise show the token to every local process.

For a delivery HTTP cannot express, put an executable at
`/etc/thermal-guard/hooks/notify`; it gets the text on stdin. With both set,
the URL is tried first and the hook is the fallback.

From stage 2 of 3 on the daemon checks whether a route exists that does not run
through the modem; if not, the message is queued and retried, because that
stage is about to switch the modem off.

### Hooks

`/etc/thermal-guard/hooks/` holds executables the daemon runs for `notify`,
for `stage1` and `stage2` when the action is `command`, and for `modem-temp`
when `modem_source` is `command`. See the `README` installed in that directory.
The whole of `/etc/thermal-guard/` is listed in `/lib/upgrade/keep.d/`, so
hooks, `matrix.env` and persisted stages survive a `sysupgrade`.

They are files rather than options because the rpcd ACL that lets the web
interface edit this configuration does not grant write or execute access to
that directory. Custom code therefore has to be put there by someone with
shell access, and editing the configuration cannot introduce any.

## Commands

```sh
thermal-guard status            # current stage, readings, fan state
thermal-guard reset             # clear all stages, hand the fan back, radio on
thermal-guard test 85 70        # feed readings through one cycle, actions logged only
thermal-guard selftest          # run the decision logic against its test cases
```

`/var/run/thermal-guard.status` holds a machine readable snapshot. Everything
else reads that file, so nothing but the daemon talks to the modem.

## Where the readings show up

* **Status -> Thermal Guard** is the monitor page: temperatures, fan state, stage.
* **Status -> Overview** gets a short temperature block, installed with the LuCI app.
* **Other sensors** of the board (`extra_sensors`, on by default): every hwmon and
  thermal zone temperature besides the processor, such as Wi-Fi chips, ethernet
  phys and NVMe drives. The proprietary MediaTek Wi-Fi driver `mt_wifi` exposes
  none of those; its radios are read with `iwpriv <interface> stat` instead, the
  way ImmortalWrt's own overview does it, and only while the interface is up.
  These readings are shown only, they never trigger a stage.
* **RRD graphs** through collectd. The package ships an exec plugin feed, enable it
  in `/etc/collectd.conf`:

  ```
  LoadPlugin exec
  <Plugin exec>
      Exec "nobody:nogroup" "/usr/libexec/thermal-guard-collectd"
  </Plugin>
  ```

  Needs `collectd-mod-exec` and `collectd-mod-rrdtool`. It emits
  `temperature-soc`, `temperature-modem`, `gauge-fan_step` and `gauge-stage`
  under the plugin name `thermal_guard`.

## Hardware

Developed against two boards, which is where the two fan modes come from:

| Board | Fan | Modem |
|---|---|---|
| GL.iNet GL-X3000 (MT7981) | kernel thermal zone, `cooling_device` | Quectel RM520N-GL |
| Banana Pi R3 Mini (MT7986) | sysfs PWM, `pwm` | Fibocom FM350-GL |

Nothing in the package is board specific, any OpenWrt device with a readable
thermal zone should work.

## License

GPL-2.0-only. The escalation logic started out as a device specific script for
the two boards above and was generalised for this package.
