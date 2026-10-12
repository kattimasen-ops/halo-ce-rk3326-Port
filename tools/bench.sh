#!/bin/bash
# Runs one benchmark of the Knulli port on the handheld over ADB.
#   tools/bench.sh <level> <seconds> <label> [HALO_SETTING=value ...]
#
# Loads levels\<level>\<level> at start-up (init.txt), plays for <seconds>,
# takes screenshots at 60% and 90% of the run with the threads' CPU use at
# the second, and saves the log and the screenshots in bench/<label>/. It
# exits 0 only when the game ran and exited cleanly.
#
# Before the first run: install the port in /userdata/roms/ports/halo and
# stop EmulationStation (adb shell /etc/init.d/S31emulationstation stop).
# This script copies tools/device/run.sh, the device-side runner, to
# /userdata/system/halo-dev/ on every run.
#
# Environment:
#   ADB, ANDROID_SERIAL  the adb executable and the handheld (tools/adb_target.sh)
#   BENCH_DIR            where the results go (default: bench/ in the current folder)
#   COOL_TO              start only once the CPU is below this temperature (default 50 C)
#   INIT_EXTRA           console commands for init.txt, separated by ';'
#   HALO_FB_BUFFERS      framebuffers for the run (default 2)
set -euo pipefail
# Git Bash on Windows: pass device paths to adb unchanged
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/adb_target.sh"
# a local path as adb understands it (cygpath: Git Bash with the Windows adb.exe)
local_path() {
	if command -v cygpath > /dev/null 2>&1; then cygpath -w "$1"; else printf '%s\n' "$1"; fi
}
# a word quoted for the handheld's shell
quote() {
	local escaped
	# (the x keeps the command substitution from dropping trailing newlines)
	escaped=$(printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf x)
	printf "'%s'" "${escaped%x}"
}
if [ $# -lt 3 ]; then
	echo "usage: $0 <level> <seconds> <label> [HALO_SETTING=value ...]" >&2
	exit 2
fi
level=$1
seconds=$2
label=$3
shift 3
case "$seconds" in
'' | *[!0-9]*) echo "seconds: a whole number" >&2; exit 2 ;;
esac
case "$level" in
'' | *[!A-Za-z0-9_]*) echo "level: a level's name, as a10 or b30" >&2; exit 2 ;;
esac
cool_to=${COOL_TO:-50}
buffers=${HALO_FB_BUFFERS:-2}
case "$cool_to$buffers" in
*[!0-9]*) echo "COOL_TO and HALO_FB_BUFFERS: whole numbers" >&2; exit 2 ;;
esac
settings=""
for setting in "$@"; do
	case "$setting" in
	[A-Z_]*=*) ;;
	*) echo "not a HALO_SETTING=value: $setting" >&2; exit 2 ;;
	esac
	case "${setting%%=*}" in
	*[!A-Z0-9_]*) echo "not a setting's name: ${setting%%=*}" >&2; exit 2 ;;
	esac
	settings="$settings $(quote "$setting")"
done
out="${BENCH_DIR:-bench}/$label"
mkdir -p "$out"
rm -f "$out/run.log" "$out/shot1.png" "$out/shot2.png" "$out/profile.txt" "$out/device.sh" "$out/init.txt"
# this run's files on the handheld, under names of their own (runs that
# overlap do not take each other's)
token=$$
staged=/userdata/system/halo-dev/init.$token.txt
runner_staged=/userdata/system/halo-dev/run.$token.sh
script=/tmp/bench.$token.sh
profile=/tmp/profile.$token.txt
top=/tmp/top.$token.txt

device_check
"$ADB" shell 'mkdir -p /userdata/system/halo-dev' > /dev/null
"$ADB" push "$(local_path "$HERE/device/run.sh")" "$runner_staged" > /dev/null
"$ADB" shell "chmod 755 $runner_staged" > /dev/null

{
	printf 'display_framerate true\r\n'
	if [ -n "${INIT_EXTRA:-}" ]; then
		printf '%s' "$INIT_EXTRA" | tr ';' '\n' | sed 's/$/\r/'
		printf '\r\n'
	fi
	printf 'map_name levels\%s\%s\r\n' "$level" "$level"
} > "$out/init.txt"
"$ADB" push "$(local_path "$out/init.txt")" "$staged" > /dev/null

first=$((seconds * 6 / 10))
second=$((seconds * 9 / 10 - first))
rest=$((seconds - first - second + 8))
cat > "$out/device.sh" <<EOF
# the game's lock (/var/run/halo-lock), held from here to the end and passed
# on to the runner and the game: none while the game runs, and nothing of it
# is touched
exec 9> /var/run/halo-lock
if ! { flock -n 9 || python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)'; } 2> /dev/null; then
	echo "Halo is running: no benchmark"
	rm -f $staged $runner_staged
	exit 1
fi
mv -f $runner_staged /userdata/system/halo-dev/run.sh
init=/userdata/roms/ports/halo/init.txt
saved=/userdata/system/halo-dev/init.saved
none=/userdata/system/halo-dev/init.none
# the game's own init.txt put back: at the end, and first, after a benchmark
# that was stopped before it could
restore() {
	if [ -f \$saved ]; then
		mv -f \$saved \$init
	elif [ -f \$none ]; then
		rm -f \$init && rm -f \$none
	fi
	rm -f \$saved.part
}
if [ -f \$saved ] || [ -f \$none ]; then
	restore
	if [ -f \$saved ] || [ -f \$none ]; then
		echo "cannot put the game's own init.txt back: no benchmark"
		exit 1
	fi
fi
# the runner stopped (it stops the game, killed ten seconds later if it must
# be, then puts the clocks back), twenty seconds at most
runner=
stop_runner() {
	kill -TERM \$runner 2> /dev/null
	waited=0
	while kill -0 \$runner 2> /dev/null && [ \$waited -lt 20 ]; do
		sleep 1
		waited=\$((waited + 1))
	done
	! kill -0 \$runner 2> /dev/null || echo "the run could not be stopped"
}
trap 'restore; rm -f $staged /var/run/battery-saver/halo.pause' EXIT
# (a benchmark that is stopped stops its run first: the game's own init.txt
# and the battery saver come back only after it)
trap '[ -z "\$runner" ] || stop_runner > /dev/null 2>&1; exit 143' TERM INT HUP
# the benchmark's init.txt in place of the game's own, which is kept aside
# whole first (or noted as none)
if [ -f \$init ]; then
	{ cp \$init \$saved.part && mv -f \$saved.part \$saved; } || { echo "cannot keep init.txt aside: no benchmark"; exit 1; }
else
	touch \$none || exit 1
fi
mv -f $staged \$init || { echo "cannot put the benchmark's init.txt in place"; exit 1; }
rm -f /userdata/system/halo-dev/run.log /tmp/shot1.$token.png /tmp/shot2.$token.png $profile $top
# the battery saver must not suspend the handheld (and ADB) during the run
mkdir -p /var/run/battery-saver && touch /var/run/battery-saver/halo.pause
# the same start for every run: the CPU cooled below COOL_TO C (ten minutes at most)
waited=0
while [ \$(cat /sys/class/thermal/thermal_zone0/temp) -gt ${cool_to}000 ] && [ \$waited -lt 600 ]; do
	sleep 5
	waited=\$((waited + 5))
done
HALO_FB_BUFFERS=$buffers setsid /userdata/system/halo-dev/run.sh $seconds HALO_PROFILE_FILE=$profile$settings < /dev/null > /dev/null 2>&1 &
runner=\$!
sleep $first
knulli-screenshot /tmp/shot1.$token.png
sleep $second
knulli-screenshot /tmp/shot2.$token.png
top -b -H -n 2 -d 3 | grep -E '^%Cpu|halo' | tail -24 > $top
sleep $rest
# the runner's end, two minutes after the game's at most; then it is stopped
waited=0
while kill -0 \$runner 2> /dev/null && [ \$waited -lt 120 ]; do
	sleep 1
	waited=\$((waited + 1))
done
if kill -0 \$runner 2> /dev/null; then
	echo "the run did not end: stopped"
	stop_runner
fi
sleep 1
cat /userdata/system/halo-dev/run.log
echo ---top---
cat $top
EOF
"$ADB" push "$(local_path "$out/device.sh")" "$script" > /dev/null
"$ADB" shell "sh $script" > "$out/run.log" || true
# (the handheld's copies removed only once all that are there came over)
pulled=1
for pair in "/tmp/shot1.$token.png:shot1.png" "/tmp/shot2.$token.png:shot2.png" "$profile:profile.txt"; do
	# (adbd on the handheld gives no exit status: the answer is read instead,
	# and no answer keeps the files there)
	answer=$("$ADB" shell "if [ -f ${pair%%:*} ]; then echo here; else echo gone; fi" 2> /dev/null | tr -d '\r')
	case "$answer" in
	here) "$ADB" pull "${pair%%:*}" "$(local_path "$out/${pair##*:}")" > /dev/null 2>&1 || pulled=0 ;;
	gone) ;;
	*) pulled=0 ;;
	esac
done
if [ "$pulled" -eq 1 ]; then
	"$ADB" shell "rm -f $script /tmp/shot1.$token.png /tmp/shot2.$token.png $profile $top" > /dev/null 2>&1 || true
else
	echo "not all of the run's files came over: they stay on the handheld (/tmp/*.$token.*)" >&2
fi
grep -E "fps |^exit|signal|fatal|guest abort" "$out/run.log" || true
grep -q '^exit 0' "$out/run.log"
