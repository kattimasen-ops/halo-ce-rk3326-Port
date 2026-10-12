#!/bin/sh
# Runs on the handheld: keeps Knulli's battery saver from dimming or
# suspending it (which drops USB) for the given hours, then exits.
#   setsid sh device-keepalive.sh [hours, default 6] &
# The battery saver counts files created or deleted in /dev/input as
# activity (/usr/bin/battery-saver.sh); nothing else is changed.
end=$(( $(date +%s) + ${1:-6} * 3600 ))
while [ "$(date +%s)" -lt "$end" ]; do
	touch /dev/input/.keepalive && rm -f /dev/input/.keepalive
	sleep 60
done
