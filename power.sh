#!/bin/bash
capacity=/sys/class/power_supply/BAT1/capacity
STATUSS=/sys/class/power_supply/BAT1/status
STATUSS="${STATUSS//[$'\t\r\n ']}"
# $(cat ${capacity}) -lt 33  && 
if [ $(cat ${capacity}) -lt 33 ] && [ $(cat ${STATUSS}) == Discharging ]; then
	su abdelilah -c "DISPLAY=':0' notify-send -t 60000  'The Power is Low Plug The Power Alimentation Now               hiiiii ' --icon=csd-power --app-name='csd power'"
fi
#grep Discharging $STATUSS
# crontab edit 
# m h  dom mon dow   command
#*/2 * * * * /home/abdelilah/.local/bin/power.sh 2> /home/abdelilah/error-powery.txt
