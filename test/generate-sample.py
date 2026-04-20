#!/usr/bin/env python3
"""Generate a sample screentime CSV with realistic variation."""

import random
from datetime import datetime, date, timedelta

random.seed(42)
hostname = "myhost"
now = datetime(2026, 4, 20, 15, 30, 0)
start = date(2026, 1, 1)
end = date(2026, 4, 20)

sessions = []
d = start
while d <= end:
    weekday = d.weekday()

    if weekday in (5, 6) and random.random() < 0.12:
        d += timedelta(days=1)
        continue

    if weekday in (5, 6):
        target = random.randint(3 * 3600, 7 * 3600)
    else:
        base = random.choice([
            random.randint(4 * 3600, 6 * 3600),
            random.randint(8 * 3600, 10 * 3600),
            random.randint(11 * 3600, 14 * 3600),
        ])
        target = base

    n_sess = random.randint(2, 4)
    wake_hour = random.randint(7, 10)
    wake_min = random.randint(0, 59)
    cur = datetime(d.year, d.month, d.day, wake_hour, wake_min, random.randint(0, 59))

    remaining = target
    for i in range(n_sess):
        if i == n_sess - 1:
            dur = remaining
        else:
            chunk = remaining // (n_sess - i)
            jitter = random.randint(-1800, 1800)
            dur = max(1200, min(chunk + jitter, remaining - 1200 * (n_sess - i - 1)))

        sessions.append((cur, dur))
        cur = cur + timedelta(seconds=dur) + timedelta(minutes=random.randint(15, 120))
        remaining -= dur

    d += timedelta(days=1)

lines = []
lines.append(f"# hostname: {hostname}")
lines.append(f"# collected: {now.strftime('%Y-%m-%d %H:%M:%S')}")
lines.append("date,wake_time,sleep_time,duration_seconds")
for wake, dur in sessions:
    sleep = wake + timedelta(seconds=dur)
    lines.append(
        f"{wake.strftime('%Y-%m-%d')},{wake.strftime('%H:%M:%S')},"
        f"{sleep.strftime('%Y-%m-%d %H:%M:%S')},{dur}"
    )

import os
outpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), "sample-screentime-log.csv")
with open(outpath, "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"{len(sessions)} sessions written to {outpath}")
