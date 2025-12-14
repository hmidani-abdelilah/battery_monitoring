#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
مراقب بطارية متكامل مع إشعارات وسجل
- نسخة مُصحَّحة ومحسَّنة
- يدعم عدة بطاريات وإعادة التهيئة عند التغيير
- يتعامل مع الأخطاء بشكل صارم وواضح
- يُحذّر من المشكلات في السجل
"""

import time
import shutil
import subprocess
import os
import argparse
import sys
import logging
from pathlib import Path
from typing import List, Dict, Optional, Tuple

# ==========================
# إعدادات افتراضية وثوابت
# ==========================
DEFAULT_CHECK_INTERVAL = 60  # ثانية
LOW_THRESHOLD = 20
HIGH_THRESHOLD = 85
UNPLUG_THRESHOLD = 95
FULL_THRESHOLD = 100

ICONS = {
    "low": "battery-caution",
    "high": "battery-good",
    "unplug": "battery-full-charged",
    "full": "battery-full",
    "default": "battery",
}

# ==========================
# معالج CLI
# ==========================
parser = argparse.ArgumentParser(description="مراقب بطارية مع إشعارات وسجل")
parser.add_argument("--interval", "-i", type=int, default=DEFAULT_CHECK_INTERVAL,
                    help="فترة التحقق بالثواني (default: %(default)s)")
parser.add_argument("--timeout", "-t", type=int, default=8000,
                    help="مهلة الإشعار بالميلي ثانية (notify-send -t) الافتراضية")
parser.add_argument("--no-log-file", action="store_true",
                    help="عدم كتابة ملف السجل")
parser.add_argument("--print-log", action="store_true",
                    help="طباعة السجل إلى stdout أثناء التشغيل")
parser.add_argument("--show-log", action="store_true",
                    help="طباعة سجل الأحداث ثم الخروج")
parser.add_argument("--tail", nargs='?', const=100, type=int, default=100,
                    help="عدد الأسطر الأخيرة للطباعة عند --show-log")
parser.add_argument("--log-path", "-l", type=str,
                    default=str(Path.home() / "battery_monitor.log"),
                    help="مسار ملف السجل")
parser.add_argument("--no-notify", action="store_true",
                    help="عدم استدعاء notify-send (مفيد للاختبار)")
args = parser.parse_args()

CHECK_INTERVAL = max(1, args.interval)
DEFAULT_TIMEOUT_MS = int(args.timeout)
LOG_PATH = None if args.no_log_file else args.log_path

# ==========================
# إعداد الـ Logging
# ==========================
logger = logging.getLogger("battery_monitor")
logger.setLevel(logging.INFO)
formatter = logging.Formatter("[%(asctime)s] %(message)s")

if LOG_PATH:
    try:
        # إن لم يكن مجلد المسار موجودًا حاول إنشاؤه (قد يفشل لصلاحية)
        parent = Path(LOG_PATH).parent
        if not parent.exists():
            parent.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(LOG_PATH, encoding="utf-8")
        fh.setLevel(logging.INFO)
        fh.setFormatter(formatter)
        logger.addHandler(fh)
    except PermissionError:
        # فشل بسبب صلاحيات → التراجع للكتابة إلى stdout فقط
        print(f"⚠️  Permission denied for log file {LOG_PATH}; falling back to stdout.", file=sys.stderr)
        LOG_PATH = None
    except Exception as e:
        print(f"⚠️  Failed to set up file logging ({LOG_PATH}): {e}; falling back to stdout.", file=sys.stderr)
        LOG_PATH = None

if args.print_log or not LOG_PATH:
    sh = logging.StreamHandler(sys.stdout)
    sh.setLevel(logging.INFO)
    sh.setFormatter(formatter)
    logger.addHandler(sh)

def log(msg: str) -> None:
    logger.info(msg)

# ==========================
# عرض السجل ثم الخروج
# ==========================
if args.show_log:
    if not LOG_PATH or not Path(LOG_PATH).exists():
        print("لا يوجد ملف سجل مفعّل أو غير موجود.")
        sys.exit(0)
    try:
        lines = Path(LOG_PATH).read_text(encoding="utf-8").splitlines()
        for line in lines[-args.tail:]:
            print(line)
    except Exception as e:
        print(f"خطأ أثناء قراءة السجل: {e}", file=sys.stderr)
    sys.exit(0)

# ==========================
# كشف أجهزة الطاقة
# ==========================
def detect_power_devices() -> Tuple[List[Path], List[Path]]:
    base = Path("/sys/class/power_supply")
    if not base.exists():
        log("⚠️  /sys/class/power_supply غير موجود — هل هذا جهاز لوحي؟")
        return [], []
    bats = [p for p in base.iterdir() if p.name.lower().startswith("bat")]
    acs = [p for p in base.iterdir() if p.name.lower().startswith(("ac", "acadapter", "ac0", "adapter"))]
    return bats, acs

BATTERIES, AC_ADAPTERS = detect_power_devices()

if not BATTERIES:
    log("❌ لا توجد بطاريات متصلة — الخروج.")
    sys.exit(1)

# ==========================
# قراءة البيانات من sysfs
# ==========================
def safe_read(path: Path, fname: str) -> Optional[str]:
    try:
        return (path / fname).read_text().strip()
    except Exception as e:
        log(f"⚠️  خطأ أثناء قراءة {path}/{fname}: {e}")
        return None

def read_all_batteries() -> List[Dict]:
    results = []
    for bat in BATTERIES:
        cap = safe_read(bat, "capacity")
        status = safe_read(bat, "status")
        try:
            percent = int(cap) if cap else None
        except ValueError:
            log(f"⚠️  قيمة غير رقمية في capacity للبطارية {bat.name}: {cap}")
            percent = None
        results.append({
            "name": bat.name,
            "percent": percent,
            "status": (status or "").lower(),
        })
    return results

def is_plugged_any(batts: List[Dict]) -> bool:
    for b in batts:
        if b["status"] in ("charging", "full"):
            return True
    for a in AC_ADAPTERS:
        if safe_read(a, "online") == "1":
            return True
    return False

# ==========================
# التحقق من notify-send
# ==========================
NOTIFY_AVAILABLE = bool(shutil.which("notify-send"))

def notify(title: str, message: str, icon_key: str = "default",
           timeout_ms: Optional[int] = None, urgency: str = "normal") -> None:
    if args.no_notify:
        log(f"[DRY-RUN] Notify: {title} — {message} (icon={icon_key} timeout={timeout_ms} urgency={urgency})")
        return
    icon = ICONS.get(icon_key, ICONS["default"])
    tm = DEFAULT_TIMEOUT_MS if timeout_ms is None else timeout_ms
    timeout_arg = "0" if tm <= 0 else str(tm)
    cmd = ["notify-send", "-u", urgency, "-i", icon, "-t", timeout_arg, title, message]
    if NOTIFY_AVAILABLE:
        try:
            subprocess.run(cmd, check=False)
            log(f"NOTIFY: {title} — {message}")
        except Exception as e:
            log(f"⚠️  فشل إرسال الإشعار: {e}")
    else:
        log(f"⚠️  notify-send غير متاح — الأمر: {' '.join(cmd)}")

# ==========================
# قواعد الإشعارات
# ==========================
def check_low(bat: Dict, plugged: bool, notified: bool) -> bool:
    p = bat.get("percent")
    if p is None:
        return notified
    if p <= LOW_THRESHOLD and not plugged and not notified:
        notify("البطارية منخفضة", f"{bat['name']} عند {p}% — الرجاء توصيل الشاحن.",
               icon_key="low", timeout_ms=0, urgency="critical")
        return True
    return False if plugged else notified

def check_high(bat: Dict, plugged: bool, notified: bool) -> bool:
    p = bat.get("percent")
    if p is None:
        return notified
    if plugged and p >= HIGH_THRESHOLD and not notified:
        notify("تجنب الشحن الزائد", f"{bat['name']} عند {p}% — يفضل فصل الشاحن.",
               icon_key="high", timeout_ms=10000)
        return True
    return False if not plugged else notified

def check_unplug(bat: Dict, plugged: bool, notified: bool) -> bool:
    p = bat.get("percent")
    if p is None:
        return notified
    if plugged and p >= UNPLUG_THRESHOLD and not notified:
        notify("اقتراب الامتلاء", f"{bat['name']} عند {p}% — الرجاء فصل الشاحن.",
               icon_key="unplug", timeout_ms=12000)
        return True
    return False if (not plugged or p < UNPLUG_THRESHOLD) else notified

def check_full(bat: Dict, plugged: bool, notified: bool) -> bool:
    p = bat.get("percent")
    if p is None:
        return notified
    if plugged and p >= FULL_THRESHOLD and not notified:
        notify("الشحن مكتمل", f"{bat['name']} وصل 100% — الرجاء فصل الشاحن.",
               icon_key="full", timeout_ms=0, urgency="critical")
        return True
    return False if (not plugged or p < FULL_THRESHOLD) else notified

# ==========================
# تدوير السجل مع إعادة تهيئة handlers
# ==========================
def rotate_log():
    if not LOG_PATH:
        return
    try:
        log_path = Path(LOG_PATH)
        # التحقق من وجود الملف أولاً
        if not log_path.exists():
            return
        # التحقق من الحجم
        if log_path.stat().st_size > 1_000_000:
            backup = LOG_PATH + ".1"
            Path(backup).unlink(missing_ok=True)
            log_path.rename(backup)
            
            log(f"ℹ️  تم تدوير السجل: {LOG_PATH} → {backup}")
            log("✅ تم تدوير ملف السجل بنجاح")

            # إعادة تهيئة handlers لإنشاء ملف جديد
            for handler in logger.handlers[:]:
                if isinstance(handler, logging.FileHandler):
                    handler.close()
                    logger.removeHandler(handler)
            
            # إنشاء handler جديد للملف الجديد
            fh = logging.FileHandler(LOG_PATH, encoding="utf-8")
            fh.setLevel(logging.INFO)
            formatter = logging.Formatter("[%(asctime)s] %(message)s")
            fh.setFormatter(formatter)
            logger.addHandler(fh)
            log("✅ تم إنشاء ملف سجل جديد بعد التدوير")

    except Exception as e:
        log(f"⚠️  خطأ أثناء تدوير السجل: {e}")

# ==========================
# فاصل زمني ديناميكي
# ==========================
def dynamic_interval(min_percent: int) -> int:
    if min_percent <= 20:
        return 20
    if min_percent <= 40:
        return 40
    return CHECK_INTERVAL

# ==========================
# تهيئة حالة الإشعارات لكل بطارية
# ==========================
def init_notified() -> Dict[str, Dict[str, bool]]:
    return {
        bat.name: {"low": False, "high": False, "unplug": False, "full": False}
        for bat in BATTERIES
    }

# ==========================
# الحلقة الرئيسية
# ==========================
def main() -> None:
    notified = init_notified()

    while True:
        rotate_log()
        bats = read_all_batteries()
        plugged = is_plugged_any(bats)

        # إعادة تهيئة الحالة إذا تغيرت البطاريات
        current_names = {b["name"] for b in bats}
        if set(notified.keys()) != current_names:
            log("⚠️  تغيرت البطاريات — إعادة تهيئة الحالة")
            notified = init_notified()

        for b in bats:
            name = b["name"]
            log(f"Battery {name}: {b['percent']}% | status={b['status']} | plugged={plugged}")

            notified[name]["low"] = check_low(b, plugged, notified[name]["low"])
            notified[name]["high"] = check_high(b, plugged, notified[name]["high"])
            notified[name]["unplug"] = check_unplug(b, plugged, notified[name]["unplug"])
            notified[name]["full"] = check_full(b, plugged, notified[name]["full"])

        percents = [b["percent"] for b in bats if b["percent"] is not None]
        interval = dynamic_interval(min(percents) if percents else CHECK_INTERVAL)
        time.sleep(interval)

if __name__ == "__main__":
    main()