# systemd Timers vs cron

Both schedulers were configured for SentryLog and both were observed
running the same script. This note records what actually differed.

## What was installed

**Timer** — `/etc/systemd/system/sentrylog.timer` paired with
`sentrylog.service`, `OnCalendar=*-*-* 06:00:00`, `Persistent=true`.

**Cron** — `/etc/cron.d/sentrylog`, one line:
`0 6 * * * root /usr/local/bin/sentrylog.sh cron`

The cron job passes the argument `cron` so the two write to different
file names and can coexist without one overwriting the other.

## Missed runs — the difference that matters here

This is the practical reason the timer is the better fit for this
project. The server in the business case is a VM that is not running
24 hours a day. If 06:00 passes while the machine is off:

- A **cron** job is simply skipped. `crond` only ever looks at the
  current time; a schedule that was missed is gone. On RHEL the
  `/etc/cron.daily` mechanism works around this with anacron, but a
  custom `/etc/cron.d` entry gets no such protection.
- A **systemd timer** with `Persistent=true` stores the last trigger
  time on disk and runs the job as soon as the machine is next
  available.

Since the whole purpose of SentryLog is that the night shift's events
get reviewed without anyone remembering to do it, a silently skipped
run defeats the project. `Persistent=true` is why the timer is the
primary mechanism and cron is the documented alternative.

## Logging and failure visibility

Both were observed in the journal, but with different detail.

The timer produces a full service lifecycle:

```
Starting sentrylog.service - Generate the daily SentryLog security digest...
sentrylog.sh[4464]: Report written to /var/log/sentrylog/security_report_2026-09-15.txt
sentrylog.service: Deactivated successfully.
Finished sentrylog.service - Generate the daily SentryLog security digest.
sentrylog.service: Consumed 1.406s CPU time, 24.5M memory peak.
```

Cron logs the invocation and the captured stdout:

```
CROND[5100]: (root) CMD (/usr/local/bin/sentrylog.sh cron)
CROND[5099]: (root) CMDOUT (Report written to .../security_report_2026-09-15_cron.txt)
CROND[5099]: (root) CMDEND (/usr/local/bin/sentrylog.sh cron)
```

The timer's output includes resource accounting and an explicit
success or failure result, and `systemctl status sentrylog.service`
shows the last run's state at any time. Cron's default failure channel
is email to the `MAILTO` address, which on a machine without a
configured mail transport means failures can go unnoticed.

## Inspecting the schedule

`systemctl list-timers sentrylog.timer` shows both the next and the
previous run in one command:

```
NEXT                        LEFT LAST                        PASSED
Wed 2026-09-16 06:00:00 IST  11h Tue 2026-09-15 18:35:12 IST      -
```

Cron has no equivalent. Working out when a job last ran means reading
the journal; working out when it will next run means interpreting the
five time fields yourself.

## Where cron is still the better choice

The comparison is not one-sided.

- A cron line is one line. The timer needed two unit files plus a
  `daemon-reload` and an `enable`.
- `crontab -e` lets an ordinary user schedule their own jobs without
  root. Installing a systemd system timer requires root.
- The five-field syntax is portable across essentially every Unix.
  `OnCalendar=` is systemd-specific.
- For a simple job on a server that never powers off, cron does the
  same work with less machinery.

## Conclusion for this project

The systemd timer is the primary scheduler because `Persistent=true`
guarantees the digest is produced even after downtime, and because the
journal gives per-run success, failure and resource data without extra
configuration. The cron job is kept as a documented equivalent and as
evidence that both mechanisms were understood.
