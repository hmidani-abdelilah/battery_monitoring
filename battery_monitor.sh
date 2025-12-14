#!/bin/bash
# -*- coding: utf-8 -*-
# مراقب البطارية - نسخة Shell Script
# يؤدي نفس عمل البرنامج Python: مراقبة البطارية وإرسال إشعارات
# يدعم خيارات CLI مشابهة

# ==========================
# إعدادات افتراضية
# ==========================
DEFAULT_INTERVAL=60
DEFAULT_TIMEOUT=8000
LOG_PATH="${HOME}/battery_monitor.log"
LOW_THRESHOLD=20
HIGH_THRESHOLD=85
UNPLUG_THRESHOLD=95
FULL_THRESHOLD=100

# ==========================
# معالج CLI باستخدام getopts
# ==========================
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Battery monitor script with notifications and logging"
    echo ""
    echo "Options:"
    echo "  -i, --interval SEC    Check interval in seconds (default: $DEFAULT_INTERVAL)"
    echo "  -t, --timeout MS      Notification timeout in milliseconds (default: $DEFAULT_TIMEOUT)"
    echo "  -l, --log-path PATH   Log file path (default: $LOG_PATH)"
    echo "  --no-log              Disable logging to file"
    echo "  --no-notify           Disable notifications (dry run)"
    echo "  --show-log            Show log and exit"
    echo "  --tail NUM            Number of lines to show with --show-log (default: 100)"
    echo "  --debug               Enable debug mode (print raw battery data)"
    echo "  -h, --help            Show this help"
    exit 0
}

# متغيرات للخيارات
INTERVAL=$DEFAULT_INTERVAL
TIMEOUT=$DEFAULT_TIMEOUT
NO_LOG=false
NO_NOTIFY=false
SHOW_LOG=false
TAIL=100
DEBUG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--interval)
            INTERVAL="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -l|--log-path)
            LOG_PATH="$2"
            shift 2
            ;;
        --no-log)
            NO_LOG=true
            shift
            ;;
        --no-notify)
            NO_NOTIFY=true
            shift
            ;;
        --show-log)
            SHOW_LOG=true
            shift
            ;;
        --tail)
            TAIL="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# ==========================
# دوال مساعدة
# ==========================
log() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if [[ "$NO_LOG" == false ]]; then
        echo "[$timestamp] $msg" >> "$LOG_PATH"
    fi
    echo "[$timestamp] $msg" >&2
}

notify() {
    local title="$1"
    local message="$2"
    local icon="$3"
    local timeout="$4"
    local urgency="$5"

    if [[ "$NO_NOTIFY" == true ]]; then
        log "[DRY-RUN] Notify: $title — $message (icon=$icon timeout=$timeout urgency=$urgency)"
        return
    fi

    if command -v notify-send >/dev/null 2>&1; then
        notify-send -u "$urgency" -i "$icon" -t "$timeout" "$title" "$message"
        log "NOTIFY: $title — $message"
    else
        log "notify-send not available — Command: notify-send -u $urgency -i $icon -t $timeout '$title' '$message'"
    fi
}

# ==========================
# كشف الأجهزة
# ==========================
detect_devices() {
    local base="/sys/class/power_supply"
    BATTERIES=()
    AC_ADAPTERS=()

    # محاولة استخدام acpi لكشف البطاريات
    if command -v acpi >/dev/null 2>&1; then
        local acpi_bats=$(acpi -b 2>/dev/null | grep -oP 'Battery \d+' | sed 's/Battery /BAT/')
        if [[ -n "$acpi_bats" ]]; then
            BATTERIES=($acpi_bats)
        fi
    fi

    # إذا لم يجد acpi، استخدم sysfs
    if [[ ${#BATTERIES[@]} -eq 0 ]]; then
        if [[ ! -d "$base" ]]; then
            log "Warning: /sys/class/power_supply not found"
            return
        fi
        BATTERIES=($(ls "$base" | grep -i '^bat'))
    fi

    # كشف AC adapters من sysfs
    if [[ -d "$base" ]]; then
        AC_ADAPTERS=($(ls "$base" | grep -E '^(ac|acadapter|ac0|adapter|usb)'))
    fi
}

detect_devices

if [[ ${#BATTERIES[@]} -eq 0 ]]; then
    log "No batteries found — exiting"
    exit 1
fi

# ==========================
# قراءة البيانات
# ==========================
read_battery() {
    local bat="$1"
    local percent=""
    local status=""

    # محاولة استخدام acpi إذا كان متاحاً (أكثر موثوقية)
    if command -v acpi >/dev/null 2>&1; then
        # استخراج رقم البطارية من اسم (مثل BAT1 -> 1)
        local bat_num=$(echo "$bat" | sed 's/BAT//')
        local acpi_output=$(acpi -b 2>/dev/null | grep "Battery $bat_num:" | head -1)
        if [[ -n "$acpi_output" ]]; then
            # مثال: Battery 1: Discharging, 82%, 03:45:22 remaining
            percent=$(echo "$acpi_output" | sed 's/.* \([0-9]*\)%.*/\1/')
            status=$(echo "$acpi_output" | awk '{print tolower($3)}' | sed 's/,$//')
        fi
    fi

    # إذا فشل acpi، استخدم sysfs
    if [[ -z "$percent" ]]; then
        local capacity_file="/sys/class/power_supply/$bat/capacity"
        local status_file="/sys/class/power_supply/$bat/status"

        if [[ -f "$capacity_file" ]]; then
            percent=$(cat "$capacity_file" 2>/dev/null)
        fi

        if [[ -f "$status_file" ]]; then
            status=$(cat "$status_file" 2>/dev/null | tr '[:upper:]' '[:lower:]')
        fi
    fi

    # تنظيف البيانات
    if [[ -z "$percent" || ! "$percent" =~ ^[0-9]+$ ]]; then
        percent=""
    fi
    if [[ -z "$status" ]]; then
        status=""
    fi

    echo "$bat|$percent|$status"
}

is_plugged() {
    # Check batteries
    for bat in "${BATTERIES[@]}"; do
        local data=$(read_battery "$bat")
        local status=$(echo "$data" | cut -d'|' -f3)
        if [[ "$status" == "charging" || "$status" == "full" ]]; then
            return 0
        fi
    done

    # Check AC adapters
    for ac in "${AC_ADAPTERS[@]}"; do
        local online_file="/sys/class/power_supply/$ac/online"
        if [[ -f "$online_file" && $(cat "$online_file" 2>/dev/null) == "1" ]]; then
            return 0
        fi
    done

    return 1
}

# ==========================
# عرض السجل
# ==========================
if [[ "$SHOW_LOG" == true ]]; then
    if [[ "$NO_LOG" == true || ! -f "$LOG_PATH" ]]; then
        echo "No log file available"
        exit 0
    fi
    tail -n "$TAIL" "$LOG_PATH"
    exit 0
fi

# ==========================
# قواعد الإشعارات
# ==========================
check_low() {
    local bat="$1"
    local plugged="$2"
    local notified="$3"
    local data=$(read_battery "$bat")
    local percent=$(echo "$data" | cut -d'|' -f2)

    if [[ -z "$percent" || "$percent" -gt "$LOW_THRESHOLD" || "$plugged" == true || "$notified" == true ]]; then
        echo "$notified"
        return
    fi

    notify "البطارية منخفضة" "$bat عند ${percent}% — الرجاء توصيل الشاحن." "battery-caution" 0 "critical"
    echo "true"
}

check_high() {
    local bat="$1"
    local plugged="$2"
    local notified="$3"
    local data=$(read_battery "$bat")
    local percent=$(echo "$data" | cut -d'|' -f2)

    if [[ -z "$percent" || "$percent" -lt "$HIGH_THRESHOLD" || "$plugged" == false || "$notified" == true ]]; then
        echo "$notified"
        return
    fi

    notify "تجنب الشحن الزائد" "$bat عند ${percent}% — يفضل فصل الشاحن." "battery-good" 10000 "normal"
    echo "true"
}

check_unplug() {
    local bat="$1"
    local plugged="$2"
    local notified="$3"
    local data=$(read_battery "$bat")
    local percent=$(echo "$data" | cut -d'|' -f2)

    if [[ -z "$percent" || "$percent" -lt "$UNPLUG_THRESHOLD" || "$plugged" == false || "$notified" == true ]]; then
        echo "$notified"
        return
    fi

    notify "اقتراب الامتلاء" "$bat عند ${percent}% — الرجاء فصل الشاحن." "battery-full-charged" 12000 "normal"
    echo "true"
}

check_full() {
    local bat="$1"
    local plugged="$2"
    local notified="$3"
    local data=$(read_battery "$bat")
    local percent=$(echo "$data" | cut -d'|' -f2)

    if [[ -z "$percent" || "$percent" -lt "$FULL_THRESHOLD" || "$plugged" == false || "$notified" == true ]]; then
        echo "$notified"
        return
    fi

    notify "الشحن مكتمل" "$bat وصل 100% — الرجاء فصل الشاحن." "battery-full" 0 "critical"
    echo "true"
}

# ==========================
# تدوير السجل
# ==========================
rotate_log() {
    if [[ "$NO_LOG" == true || ! -f "$LOG_PATH" ]]; then
        return
    fi

    local size=$(stat -f%z "$LOG_PATH" 2>/dev/null || stat -c%s "$LOG_PATH" 2>/dev/null)
    if [[ $size -gt 1000000 ]]; then
        local backup="${LOG_PATH}.1"
        rm -f "$backup"
        mv "$LOG_PATH" "$backup"
        log "Log rotated to $backup"
    fi
}

# ==========================
# فاصل ديناميكي
# ==========================
dynamic_interval() {
    local min_percent="$1"
    if [[ ! "$min_percent" =~ ^[0-9]+$ ]]; then
        echo "$DEFAULT_INTERVAL"
        return
    fi
    if [[ $min_percent -le 20 ]]; then
        echo 20
    elif [[ $min_percent -le 40 ]]; then
        echo 40
    else
        echo "$INTERVAL"
    fi
}

# ==========================
# الحلقة الرئيسية
# ==========================
declare -A notified_low
declare -A notified_high
declare -A notified_unplug
declare -A notified_full

for bat in "${BATTERIES[@]}"; do
    notified_low["$bat"]=false
    notified_high["$bat"]=false
    notified_unplug["$bat"]=false
    notified_full["$bat"]=false
done

while true; do
    rotate_log

    plugged=false
    if is_plugged; then
        plugged=true
    fi

    min_percent=100
    for bat in "${BATTERIES[@]}"; do
        data=$(read_battery "$bat")
        percent=$(echo "$data" | cut -d'|' -f2)
        status=$(echo "$data" | cut -d'|' -f3)

        if [[ -n "$percent" && "$percent" =~ ^[0-9]+$ ]]; then
            if [[ $percent -lt $min_percent ]]; then
                min_percent=$percent
            fi
        fi

        log "Battery $bat: ${percent}% | status=$status | plugged=$plugged"

        notified_low["$bat"]=$(check_low "$bat" "$plugged" "${notified_low["$bat"]}")
        notified_high["$bat"]=$(check_high "$bat" "$plugged" "${notified_high["$bat"]}")
        notified_unplug["$bat"]=$(check_unplug "$bat" "$plugged" "${notified_unplug["$bat"]}")
        notified_full["$bat"]=$(check_full "$bat" "$plugged" "${notified_full["$bat"]}")
    done

    interval=$(dynamic_interval "$min_percent")
    if [[ -z "$interval" || ! "$interval" =~ ^[0-9]+$ ]]; then
        interval=$DEFAULT_INTERVAL
    fi
    sleep "$interval"
done