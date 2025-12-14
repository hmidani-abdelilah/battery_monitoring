#!/bin/bash
capacity=/sys/class/power_supply/BAT1/capacity
STATUSS=/sys/class/power_supply/BAT1/status
STATUSS="${STATUSS//[$'\t\r\n ']}"
# $(cat ${capacity}) -lt 33  && 
if [ $(cat ${capacity}) -lt 33 ] && [ $(cat ${STATUSS}) == Discharging ]; then
	su abdelilah -c "DISPLAY=':0' notify-send -t 60000  'The Power is Low Plug The Power Alimentation Now               hiiiii abdelilah' --icon=csd-power --app-name='csd power'"
fi
#grep Discharging $STATUSS
