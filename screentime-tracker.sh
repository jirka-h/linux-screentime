#!/bin/bash
# =============================================================================
# screentime-tracker.sh — Fedora 42
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/screentime-log.csv"
TEMPLATE="$SCRIPT_DIR/screentime-dashboard.html"
REPORT="$SCRIPT_DIR/screentime-report.html"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [CSV_FILE]

Generate and display screen time reports from systemd journal data.

Options:
  -h, --help      Show this help message
  --report        Show text report and generate HTML from existing CSV

Arguments:
  CSV_FILE        Path to CSV file (default: $LOG_FILE)

With no options, reads the systemd journal, writes CSV + HTML, and prints
the text report. If CSV_FILE is given, it is used for all operations.
EOF
}

rebuild_log() {
    python3 - "$LOG_FILE" "$TEMPLATE" "$REPORT" <<'PYEOF'
import subprocess, sys, re, json, socket, os
from datetime import datetime, timedelta, date

log_file, template_path, report_path = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.now()
current_year = now.year

# 1. Boot times
boots = []
try:
    r = subprocess.run(["last", "reboot", "-F"], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        m = re.search(r'system boot\s+\S+\s+(\w{3}\s+\w{3}\s+\d+\s+\d+:\d+:\d+\s+\d{4})', line)
        if m:
            try:
                boots.append(datetime.strptime(m.group(1).strip(), "%a %b %d %H:%M:%S %Y"))
            except: pass
except: pass

# 2. Journal events
since_month = now.month - 3
since_year = now.year
if since_month < 1:
    since_month += 12
    since_year -= 1
since_date = date(since_year, since_month, 1)
cmd = ["journalctl", "--since", since_date.isoformat(), "--no-pager", "-q",
       "--output", "short", "-g",
       "The system will suspend now|System returned from sleep operation"]
try:
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    lines = result.stdout.splitlines()
except:
    lines = []

LINE_RE = re.compile(r'^(\w{3}\s+\d+\s+\d{2}:\d{2}:\d{2})\s+\S+\s+(.+)$')
events = []

for line in lines:
    m = LINE_RE.match(line)
    if not m: continue
    ts_str, rest = m.group(1), m.group(2)
    try:
        dt = datetime.strptime(f"{ts_str} {current_year}", "%b %d %H:%M:%S %Y")
        if dt > now + timedelta(days=1):
            dt = datetime.strptime(f"{ts_str} {current_year-1}", "%b %d %H:%M:%S %Y")
    except: continue
    if "will suspend now" in rest:
        events.append((dt, 'suspend'))
    elif "returned from sleep" in rest:
        events.append((dt, 'resume'))

for b in boots:
    events.append((b, 'resume'))

events.sort(key=lambda x: x[0])

# 3. Build sessions
since = datetime(since_year, since_month, 1)
sessions = []
last_wake = None

window_events = [(dt, et) for dt, et in events if dt >= since]
if window_events and window_events[0][1] == 'suspend':
    last_wake = since

for dt, etype in events:
    if dt < since:
        if etype == 'resume': last_wake = dt
        elif etype == 'suspend': last_wake = None
        continue
    if etype == 'resume':
        if last_wake is None:
            last_wake = dt
    elif etype == 'suspend':
        if last_wake is not None:
            if (dt - last_wake).total_seconds() > 30:
                sessions.append((last_wake, dt))
            last_wake = None

if last_wake is not None and (now - last_wake).total_seconds() > 30:
    sessions.append((last_wake, now))

# 4. Write CSV
hostname  = socket.gethostname()
collected = now.strftime('%Y-%m-%d %H:%M:%S')

with open(log_file, 'w') as f:
    f.write(f"# hostname: {hostname}\n")
    f.write(f"# collected: {collected}\n")
    f.write("date,wake_time,sleep_time,duration_seconds\n")
    for wake, sleep in sessions:
        dur = int((sleep - wake).total_seconds())
        f.write(f"{wake.strftime('%Y-%m-%d')},{wake.strftime('%H:%M:%S')},{sleep.strftime('%Y-%m-%d %H:%M:%S')},{dur}\n")

print(f"Done. {len(sessions)} sessions written to {log_file}")
if sessions:
    print(f"Date range: {sessions[0][0].strftime('%Y-%m-%d')} -> {sessions[-1][1].strftime('%Y-%m-%d')}")

# 5. Generate self-contained HTML
if not os.path.exists(template_path):
    print(f"Warning: {template_path} not found, skipping HTML generation.")
else:
    rows = []
    for wake, sleep in sessions:
        dur = int((sleep - wake).total_seconds())
        rows.append({'date': wake.strftime('%Y-%m-%d'), 'wake': wake.strftime('%H:%M:%S'), 'dur': dur})
    generated = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    inline = {'rows': rows, 'hostname': hostname, 'collected': collected, 'generated': generated}
    with open(template_path) as f:
        html = f.read()
    html = html.replace('/*__INLINE_DATA__*/null/**/', f'/*__INLINE_DATA__*/{json.dumps(inline)}/**/')
    with open(report_path, 'w') as f:
        f.write(html)
    print(f"Dashboard: {report_path}")

PYEOF
}

show_report() {
    python3 - "$LOG_FILE" <<'PYEOF'
import sys, csv
from datetime import datetime, timedelta, date
import calendar

log_file = sys.argv[1]

def fmt(secs):
    secs = max(0, int(secs))
    return f"{secs//3600}h {(secs%3600)//60:02d}m"

day_totals = {}
today_sessions = []

try:
    with open(log_file, newline='') as f:
        # Skip comment lines so DictReader sees the correct header
        lines = [l for l in f if not l.startswith('#')]
    for row in csv.DictReader(lines):
        try:
            wake = datetime.strptime(f"{row['date']} {row['wake_time']}", "%Y-%m-%d %H:%M:%S")
            sleep_str = row['sleep_time'].strip()
            if len(sleep_str) > 8:
                sleep = datetime.strptime(sleep_str, "%Y-%m-%d %H:%M:%S")
            else:
                sleep = datetime.strptime(f"{row['date']} {sleep_str}", "%Y-%m-%d %H:%M:%S")
        except: continue

        cur = wake
        while True:
            midnight = datetime(cur.year, cur.month, cur.day) + timedelta(days=1)
            end = min(sleep, midnight)
            secs = (end - cur).total_seconds()
            if secs > 0:
                ds = cur.strftime('%Y-%m-%d')
                day_totals[ds] = day_totals.get(ds, 0) + secs
                if ds == date.today().isoformat():
                    today_sessions.append((cur.strftime('%H:%M:%S'), end.strftime('%H:%M:%S'), int(secs)))
            if sleep <= midnight:
                break
            cur = midnight

except FileNotFoundError:
    print(f"No log file found at {log_file}")
    print("Run: ./screentime-tracker.sh --rebuild")
    sys.exit(1)

today = date.today()

print("=" * 52)
print("  SCREEN TIME REPORT")
print("=" * 52)
print(f"\n📅 TODAY ({today.strftime('%A, %d %b %Y')})")
print(f"   Active time: {fmt(day_totals.get(today.isoformat(), 0))}")
for w, s, d in today_sessions:
    print(f"     {w} - {s}  ({fmt(d)})")

print(f"\n📊 LAST 7 DAYS")
week_total = 0
week_active = 0
for i in range(6, -1, -1):
    d = today - timedelta(days=i)
    ds = d.isoformat()
    secs = day_totals.get(ds, 0)
    label = "today" if d == today else d.strftime("%a %d")
    print(f"   {label:<10} {fmt(secs):>8}")
    week_total += secs
    if secs > 0: week_active += 1
print(f"   {'Average':<10} {fmt(week_total // max(week_active,1)):>8}  (active days: {week_active})")

# -- Complete Mon-Sun weeks within our data window -----------------
cm = today.month - 3
cy = today.year
if cm < 1:
    cm += 12
    cy -= 1
cutoff = date(cy, cm, 1)
last_sunday = today - timedelta(days=(today.weekday() + 1) % 7)
if today.weekday() == 6:
    last_sunday = today - timedelta(days=7)

weeks = []
w_end = last_sunday
while True:
    w_start = w_end - timedelta(days=6)
    if w_start < cutoff:
        break
    weeks.append((w_start, w_end))
    w_end = w_start - timedelta(days=1)

if weeks:
    week_totals = []
    for w_start, w_end in weeks:
        day_secs = [day_totals.get((w_start + timedelta(days=i)).isoformat(), 0) for i in range(7)]
        week_totals.append(sum(day_secs))
    ranked = sorted(set(week_totals))
    top3 = set(ranked[-3:])
    bot3 = set(ranked[:3])
    GREEN = '\033[32m'
    RED   = '\033[31m'
    RESET = '\033[0m'
    print(f"\n📅 COMPLETE WEEKS (Mon–Sun)")
    for idx, (w_start, w_end) in enumerate(weeks):
        day_secs = [day_totals.get((w_start + timedelta(days=i)).isoformat(), 0) for i in range(7)]
        w_secs = week_totals[idx]
        active_secs = sorted(s for s in day_secs if s > 0)
        active_count = len(active_secs)
        avg    = w_secs // max(active_count, 1)
        mn     = active_secs[0]  if active_secs else 0
        mx     = active_secs[-1] if active_secs else 0
        mid    = len(active_secs) // 2
        median = active_secs[mid] if active_count % 2 else (active_secs[mid-1] + active_secs[mid]) // 2
        label  = f"{w_start.day}.{w_start.month}. – {w_end.day}.{w_end.month}."
        ratio  = f"({active_count}/7)"
        line   = f"   {label:<18} {fmt(w_secs):>9}  avg {fmt(avg):>7}/day  {ratio:>7}  min {fmt(mn):>7}  med {fmt(median):>7}  max {fmt(mx):>7}"
        if w_secs in top3:
            print(f"{RED}{line}{RESET}")
        elif w_secs in bot3:
            print(f"{GREEN}{line}{RESET}")
        else:
            print(line)

print(f"\n📈 MONTHLY STATISTICS")
month_data = {}
for ds, secs in day_totals.items():
    try: d = date.fromisoformat(ds)
    except: continue
    if d >= cutoff:
        ym = (d.year, d.month)
        if ym not in month_data:
            month_data[ym] = {'total': 0, 'active_days': []}
        month_data[ym]['total'] += secs
        month_data[ym]['active_days'].append(secs)

for (y, m) in sorted(month_data, reverse=True):
    info = month_data[(y, m)]
    name = date(y, m, 1).strftime("%B %Y")
    month_start  = date(y, m, 1)
    month_end    = date(y, m, calendar.monthrange(y, m)[1])
    window_start = max(month_start, cutoff)
    window_end   = min(month_end, today)
    days_in_window = (window_end - window_start).days + 1
    active = sorted(info['active_days'])
    active_count = len(active)
    avg    = info['total'] // max(active_count, 1)
    mn     = active[0]  if active else 0
    mx     = active[-1] if active else 0
    mid    = len(active) // 2
    median = active[mid] if active_count % 2 else (active[mid-1] + active[mid]) // 2
    ratio = f"({active_count}/{days_in_window})"
    print(f"   {name:<18} {fmt(info['total']):>9}  avg {fmt(avg):>7}/day  {ratio:>7}  min {fmt(mn):>7}  med {fmt(median):>7}  max {fmt(mx):>7}")

print("\n" + "=" * 52)
PYEOF
}

generate_html() {
    python3 - "$LOG_FILE" "$TEMPLATE" "$REPORT" <<'PYEOF'
import sys, csv, json, os
from datetime import datetime

log_file, template_path, report_path = sys.argv[1], sys.argv[2], sys.argv[3]

if not os.path.exists(template_path):
    print(f"Warning: {template_path} not found, skipping HTML generation.")
    sys.exit(0)

hostname = ''
collected = ''
rows = []

with open(log_file, newline='') as f:
    for line in f:
        if line.startswith('#'):
            if 'hostname:' in line:  hostname  = line.split(':', 1)[1].strip()
            if 'collected:' in line: collected = line.split(':', 1)[1].strip()
            continue
        break
    f.seek(0)
    lines = [l for l in f if not l.startswith('#')]
    for row in csv.DictReader(lines):
        try:
            dur = int(row['duration_seconds'])
            if dur > 0:
                rows.append({'date': row['date'], 'wake': row['wake_time'], 'dur': dur})
        except:
            continue

generated = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
inline = {'rows': rows, 'hostname': hostname, 'collected': collected, 'generated': generated}
with open(template_path) as f:
    html = f.read()
html = html.replace('/*__INLINE_DATA__*/null/**/', f'/*__INLINE_DATA__*/{json.dumps(inline)}/**/')
with open(report_path, 'w') as f:
    f.write(html)
print(f"Dashboard: {report_path}")
PYEOF
}

ACTION="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)   usage; exit 0 ;;
        --report)    ACTION="report"; shift ;;
        *)
            if [[ -f "$1" || "$1" == *.csv ]]; then
                LOG_FILE="$1"
                REPORT="${LOG_FILE%.csv}-report.html"
            else
                echo "Unknown option or file not found: $1" >&2
                usage >&2
                exit 1
            fi
            shift ;;
    esac
done

case "$ACTION" in
    report)
        if [ ! -f "$LOG_FILE" ]; then
            echo "No CSV found at $LOG_FILE" >&2
            exit 1
        fi
        show_report
        generate_html
        ;;
    all)
        echo "Reading systemd journal..."
        rebuild_log
        show_report
        ;;
esac
