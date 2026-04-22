#!/bin/bash
# =============================================================================
# screentime-tracker.sh
# =============================================================================

export LANG=C
VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/screentime-log.csv"
TEMPLATE="$SCRIPT_DIR/screentime-dashboard.html"
REPORT="$SCRIPT_DIR/screentime-report.html"

usage() {
    cat <<EOF
screentime-tracker v$VERSION

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
    python3 - "$LOG_FILE" "$TEMPLATE" "$REPORT" "$VERSION" <<'PYEOF'
import subprocess, sys, re, json, socket, os
from datetime import datetime, timedelta, date

log_file, template_path, report_path, version = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
now = datetime.now()
current_year = now.year

# 1. Boot times from multiple sources
boots = []
env = {**os.environ, 'LANG': 'C'}

# 1a. Try 'last reboot -F', fall back to 'wtmpdb last reboot'
try:
    r = subprocess.run(["last", "reboot", "-F"], capture_output=True, text=True, env=env)
    for line in r.stdout.splitlines():
        m = re.search(r'system boot\s+\S+\s+(\w{3}\s+\w{3}\s+\d+\s+\d+:\d+:\d+\s+\d{4})', line)
        if m:
            try:
                boots.append(datetime.strptime(m.group(1).strip(), "%a %b %d %H:%M:%S %Y"))
            except: pass
except FileNotFoundError:
    try:
        r = subprocess.run(["wtmpdb", "last", "reboot"], capture_output=True, text=True, env=env)
        for line in r.stdout.splitlines():
            if 'reboot' not in line.lower(): continue
            m = re.search(r'(\w{3}\s+\w{3}\s+\d+\s+\d+:\d+:\d+\s+\d{4})', line)
            if m:
                try:
                    boots.append(datetime.strptime(m.group(1).strip(), "%a %b %d %H:%M:%S %Y"))
                except: pass
    except FileNotFoundError:
        print("Note: 'last' not found. On Ubuntu/Debian: sudo apt install util-linux-extra", file=sys.stderr)
except Exception: pass

# 1b. journalctl --list-boots (boot start + end times)
boot_ends = []
try:
    r = subprocess.run(["journalctl", "--list-boots", "--no-pager"],
                       capture_output=True, text=True, env=env)
    for line in r.stdout.splitlines():
        matches = re.findall(r'(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})', line)
        if matches:
            try:
                bt = datetime.strptime(f"{matches[0][0]} {matches[0][1]}", "%Y-%m-%d %H:%M:%S")
                if not any(abs((bt - b).total_seconds()) < 60 for b in boots):
                    boots.append(bt)
            except: pass
        if len(matches) >= 2:
            try:
                et = datetime.strptime(f"{matches[1][0]} {matches[1][1]}", "%Y-%m-%d %H:%M:%S")
                if (now - et).total_seconds() > 300:
                    boot_ends.append(et)
            except: pass
except: pass

# 1c. 'who -b' as fallback for current boot time
try:
    r = subprocess.run(["who", "-b"], capture_output=True, text=True, env=env)
    m = re.search(r'(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})', r.stdout)
    if m:
        bt = datetime.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H:%M")
        if not any(abs((bt - b).total_seconds()) < 120 for b in boots):
            boots.append(bt)
except: pass

# 2. Journal events
since_month = now.month - 3
since_year = now.year
if since_month < 1:
    since_month += 12
    since_year -= 1
since_date = date(since_year, since_month, 1)
if boots:
    earliest = min(boots).date()
    limit = (now - timedelta(days=365)).date()
    if earliest >= limit and earliest < since_date:
        since_date = date(earliest.year, earliest.month, 1)

cmd = ["journalctl", "--since", since_date.isoformat(), "--no-pager", "-q",
       "--output", "short-iso",
       "-t", "systemd-sleep", "-t", "systemd-logind"]
try:
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60, env=env)
    lines = result.stdout.splitlines()
except:
    lines = []

LINE_RE = re.compile(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\S*)\s+\S+\s+(.+)$')
events = []

for line in lines:
    m = LINE_RE.match(line)
    if not m: continue
    ts_str, rest = m.group(1), m.group(2)
    try:
        dt = datetime.strptime(ts_str[:19], "%Y-%m-%dT%H:%M:%S")
    except: continue
    if ("will suspend now" in rest or "Entering sleep state" in rest or
        "Suspending system" in rest or "Performing sleep operation" in rest):
        events.append((dt, 'suspend'))
    elif "returned from sleep" in rest or "System resumed" in rest:
        events.append((dt, 'resume'))
    elif ("System is powering off" in rest or "System is powering down" in rest or
          "System is rebooting" in rest or "System is halting" in rest or
          "will power off" in rest or "will reboot" in rest):
        events.append((dt, 'shutdown'))

for e in boot_ends:
    events.append((e, 'shutdown'))
for b in boots:
    events.append((b, 'resume'))

events.sort(key=lambda x: x[0])

# Deduplicate consecutive same-type events within 60s
deduped = []
for dt, etype in events:
    if deduped and etype == deduped[-1][1] and abs((dt - deduped[-1][0]).total_seconds()) < 60:
        continue
    deduped.append((dt, etype))
events = deduped

# 3. Build sessions
since = datetime(since_date.year, since_date.month, since_date.day)
sessions = []
last_wake = None

window_events = [(dt, et) for dt, et in events if dt >= since]
if window_events and window_events[0][1] in ('suspend', 'shutdown'):
    last_wake = since

for dt, etype in events:
    if dt < since:
        if etype == 'resume': last_wake = dt
        elif etype in ('suspend', 'shutdown'): last_wake = None
        continue
    if etype == 'resume':
        if last_wake is not None:
            if (dt - last_wake).total_seconds() > 300:
                sessions.append((last_wake, dt))
                last_wake = dt
        else:
            last_wake = dt
    elif etype in ('suspend', 'shutdown'):
        if last_wake is not None:
            if (dt - last_wake).total_seconds() > 30:
                sessions.append((last_wake, dt))
            last_wake = None

if last_wake is not None and (now - last_wake).total_seconds() > 30:
    sessions.append((last_wake, now))

# 3b. Build sleep sessions (gaps between wake sessions)
all_sessions = [(w, s, 'wake') for w, s in sessions]
for i in range(len(sessions) - 1):
    gap_start = sessions[i][1]
    gap_end = sessions[i+1][0]
    if (gap_end - gap_start).total_seconds() > 30:
        all_sessions.append((gap_start, gap_end, 'sleep'))
all_sessions.sort(key=lambda x: x[0])

# 4. Write CSV
hostname  = socket.gethostname()
collected = now.strftime('%Y-%m-%d %H:%M:%S')

with open(log_file, 'w') as f:
    f.write(f"# hostname: {hostname}\n")
    f.write(f"# collected: {collected}\n")
    f.write("date,start_time,end_time,duration_seconds,type\n")
    for start, end, stype in all_sessions:
        dur = int((end - start).total_seconds())
        f.write(f"{start.strftime('%Y-%m-%d')},{start.strftime('%H:%M:%S')},{end.strftime('%Y-%m-%d %H:%M:%S')},{dur},{stype}\n")

wake_count = sum(1 for _, _, t in all_sessions if t == 'wake')
sleep_count = sum(1 for _, _, t in all_sessions if t == 'sleep')
print(f"Done. {wake_count} wake + {sleep_count} sleep sessions written to {log_file}")
if all_sessions:
    print(f"Date range: {all_sessions[0][0].strftime('%Y-%m-%d')} -> {all_sessions[-1][1].strftime('%Y-%m-%d')}")

# 5. Generate self-contained HTML
if not os.path.exists(template_path):
    print(f"Warning: {template_path} not found, skipping HTML generation.")
else:
    rows = []
    for start, end, stype in all_sessions:
        dur = int((end - start).total_seconds())
        rows.append({'date': start.strftime('%Y-%m-%d'), 'wake': start.strftime('%H:%M:%S'), 'dur': dur, 'type': stype})
    generated = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    inline = {'rows': rows, 'hostname': hostname, 'collected': collected, 'generated': generated, 'version': version}
    with open(template_path) as f:
        html = f.read()
    html = html.replace('/*__INLINE_DATA__*/null/**/', f'/*__INLINE_DATA__*/{json.dumps(inline)}/**/')
    with open(report_path, 'w') as f:
        f.write(html)
    print(f"Dashboard: {report_path}")

PYEOF
}

show_report() {
    python3 - "$LOG_FILE" "$VERSION" <<'PYEOF'
import sys, csv, locale
from datetime import datetime, timedelta, date
import calendar
locale.setlocale(locale.LC_ALL, 'C')

log_file = sys.argv[1]
version = sys.argv[2]

def fmt(secs):
    secs = max(0, int(secs))
    return f"{secs//3600}h {(secs%3600)//60:02d}m"

day_totals = {}
day_sleep = {}
today_sessions = []
today_sleep_sessions = []

try:
    with open(log_file, newline='') as f:
        # Skip comment lines so DictReader sees the correct header
        lines = [l for l in f if not l.startswith('#')]
    for row in csv.DictReader(lines):
        try:
            row_type = row.get('type', 'wake')
            start = datetime.strptime(f"{row['date']} {row['start_time']}", "%Y-%m-%d %H:%M:%S")
            end_str = row['end_time'].strip()
            if len(end_str) > 8:
                end = datetime.strptime(end_str, "%Y-%m-%d %H:%M:%S")
            else:
                end = datetime.strptime(f"{row['date']} {end_str}", "%Y-%m-%d %H:%M:%S")
        except: continue

        cur = start
        while True:
            midnight = datetime(cur.year, cur.month, cur.day) + timedelta(days=1)
            seg_end = min(end, midnight)
            secs = (seg_end - cur).total_seconds()
            if secs > 0:
                ds = cur.strftime('%Y-%m-%d')
                if row_type == 'wake':
                    day_totals[ds] = day_totals.get(ds, 0) + secs
                    if ds == date.today().isoformat():
                        today_sessions.append((cur.strftime('%H:%M:%S'), seg_end.strftime('%H:%M:%S'), int(secs)))
                else:
                    day_sleep[ds] = day_sleep.get(ds, 0) + secs
                    if ds == date.today().isoformat():
                        today_sleep_sessions.append((cur.strftime('%H:%M:%S'), seg_end.strftime('%H:%M:%S'), int(secs)))
            if end <= midnight:
                break
            cur = midnight

except FileNotFoundError:
    print(f"No log file found at {log_file}")
    print("Run: ./screentime-tracker.sh --rebuild")
    sys.exit(1)

today = date.today()

print("=" * 52)
print(f"  SCREEN TIME REPORT  v{version}")
print("=" * 52)
print(f"\n📅 TODAY ({today.strftime('%A, %d %b %Y')})")
print(f"   Active time: {fmt(day_totals.get(today.isoformat(), 0))}")
for w, s, d in today_sessions:
    print(f"     {w} - {s}  ({fmt(d)})")
print(f"   Sleep time:  {fmt(day_sleep.get(today.isoformat(), 0))}")
for w, s, d in today_sleep_sessions:
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
        median = 0 if not active_secs else (active_secs[mid] if active_count % 2 else (active_secs[mid-1] + active_secs[mid]) // 2)
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
    median = 0 if not active else (active[mid] if active_count % 2 else (active[mid-1] + active[mid]) // 2)
    ratio = f"({active_count}/{days_in_window})"
    print(f"   {name:<18} {fmt(info['total']):>9}  avg {fmt(avg):>7}/day  {ratio:>7}  min {fmt(mn):>7}  med {fmt(median):>7}  max {fmt(mx):>7}")

print("\n" + "=" * 52)
PYEOF
}

generate_html() {
    python3 - "$LOG_FILE" "$TEMPLATE" "$REPORT" "$VERSION" <<'PYEOF'
import sys, csv, json, os
from datetime import datetime

log_file, template_path, report_path, version = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

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
                rows.append({'date': row['date'], 'wake': row['start_time'], 'dur': dur, 'type': row.get('type', 'wake')})
        except:
            continue

generated = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
inline = {'rows': rows, 'hostname': hostname, 'collected': collected, 'generated': generated, 'version': version}
with open(template_path) as f:
    html = f.read()
html = html.replace('/*__INLINE_DATA__*/null/**/', f'/*__INLINE_DATA__*/{json.dumps(inline)}/**/')
with open(report_path, 'w') as f:
    f.write(html)
print(f"Dashboard: {report_path}")
PYEOF
}

check_deps() {
    local fail=0
    if ! command -v python3 &>/dev/null; then
        echo "ERROR: 'python3' is required but not found." >&2
        if [ -f /etc/debian_version ]; then
            echo "  Install with: sudo apt install python3" >&2
        elif [ -f /etc/redhat-release ]; then
            echo "  Install with: sudo dnf install python3" >&2
        fi
        fail=1
    fi
    if ! command -v journalctl &>/dev/null; then
        echo "ERROR: 'journalctl' is required but not found (systemd not available?)." >&2
        fail=1
    fi
    if [ $fail -ne 0 ]; then
        exit 1
    fi
    if ! command -v last &>/dev/null; then
        echo "WARNING: 'last' command not found — boot/shutdown history unavailable." >&2
        echo "  Results will be unreliable without it." >&2
        if [ -f /etc/debian_version ]; then
            echo "  Install with: sudo apt install util-linux-extra" >&2
        else
            echo "  Install the package that provides 'last' for your distribution." >&2
        fi
        echo "" >&2
    fi
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
        check_deps
        if [ ! -f "$LOG_FILE" ]; then
            echo "No CSV found at $LOG_FILE" >&2
            exit 1
        fi
        show_report
        generate_html
        ;;
    all)
        check_deps
        echo "Reading systemd journal..."
        rebuild_log
        show_report
        ;;
esac
