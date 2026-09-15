# SentryLog — Automated Security Digest

A scheduled log analysis service for RHEL 10. It reads the system
journal, extracts security-relevant events, counts authentication
failures per source IP address, and writes a dated report without
anyone having to run it.

---

## Problem Statement

An operations team runs a RHEL server that writes thousands of journal
entries a day. Two engineers spend the first hour of every shift
scrolling through logs looking for failed logins. Nothing gets reviewed
until 10 AM, so anything that happens overnight is found late or not at
all.

The work is repetitive, it is done inconsistently depending on who is
on shift, and it happens at the wrong time of day. It is exactly the
kind of task that should be running on a schedule instead.

SentryLog replaces the manual scan with a script that runs at 06:00,
before the shift starts, and leaves a dated summary ready to read.

---

## Objectives

1. Make the system journal persistent so log history survives a reboot.
2. Confirm the system clock is synchronised, and explain why log
   analysis depends on it.
3. Extract failed authentication attempts, service failures, and
   entries at priority `err` or above using `journalctl` and `grep -E`.
4. Count failures per event type and per source IP, flagging any
   address above a threshold as SUSPECT.
5. Schedule the script with a systemd timer, then with cron, and
   document the difference.
6. Configure automatic removal of reports older than 30 days.

---

## Environment

| Item | Value |
|---|---|
| Operating system | Red Hat Enterprise Linux 10 |
| Virtualisation | VMware, NAT networking |
| VM address | 192.168.73.130/24 (`ens160`) |
| Host address | 192.168.73.1 (VMware NAT gateway) |
| Timezone | Asia/Kolkata (IST, +0530) |
| Script location | `/usr/local/bin/sentrylog.sh` |
| Report location | `/var/log/sentrylog/` |
| Run as | root |

---

## RH134 References

| Chapter | Applied to |
|---|---|
| Ch 1 — Shell Scripting and the Command Line | `for` loops, `if`/`then`/`else`, `[[ ]]` numeric tests, `$(( ))` arithmetic, command substitution, positional parameters, exit codes |
| Ch 2 — Using Regular Expressions | `grep -E` extended regex, alternation, character classes, quantifiers |
| Ch 3 — Scheduling User Tasks | cron time-field syntax, `crontab` mechanics |
| Ch 4 — Scheduling System Tasks | `[Unit]`/`[Timer]`/`[Install]` structure, `OnCalendar=`, `Type=oneshot`, `systemctl daemon-reload`, `/etc/cron.d/`, `/etc/tmpfiles.d/`, `systemd-tmpfiles --create` and `--clean` |
| Ch 5 — Analyzing and Storing Logs | `/var/log/journal` persistence, `journalctl --flush`, `--list-boots`, `-b -1`, `-p err`, `--since`, `chronyc sources -v`, `timedatectl` |

### Beyond the course material

Five things in this project are not taught in Chapters 1–5 and are
flagged here rather than presented as course content:

1. **Writing unit files from scratch.** Ch 4 only copies and edits a
   vendor-supplied timer. Both `sentrylog.service` and
   `sentrylog.timer` were written directly.
2. **`Persistent=true`.** Not in Ch 4, and the single most important
   directive in this project — see `timer_vs_cron.md`.
3. **`systemctl list-timers`.** Ch 4 teaches
   `systemctl list-units -t timer`. `list-timers` gives NEXT, LEFT,
   LAST and PASSED columns, which is far better evidence.
4. **`sort`, `uniq -c` and `grep -o`.** Needed for per-IP counting and
   for summarising repeated error messages. Ch 1 states that
   associative arrays are out of scope, so counting is done with a
   `for` loop over a sorted unique list.
5. **`stat`** for inspecting inode timestamps, used to explain the
   tmpfiles behaviour documented below.

---

## Architecture

```
/usr/local/bin/sentrylog.sh [tag]
        |
root check ---> exit 1 if not root
        |
mkdir -p /var/log/sentrylog, chmod 0700
        |
capture two journal views once:
    full 24h window          -> .window.tmp
    24h at priority err+     -> .errs.tmp
        |
filter authentication failures -> .auth.tmp
filter rejected credentials    -> .fails.tmp
        |
Section 1  failed authentication
Section 2  service failures
Section 3  priority err and above (frequency table + recent tail)
Section 4  for loop over unique IPs -> grep -c -> threshold test
Section 5  summary counts
        |
remove working files
```

**Why the working files live in `/var/log/sentrylog` and not `/tmp`.**
They contain raw log lines, and a root-owned process writing to a
predictable path inside a world-writable directory is a symlink-attack
pattern. The report directory is mode `0700 root root`, which also
means the digest itself — containing usernames and source addresses —
is unreadable by ordinary users.

**Why matching is on message text, not process name.** RHEL 10 logs SSH
sessions under `sshd-session`, not `sshd`:

```
sshd-session[3685]: Failed password for invalid user baduser from 192.168.73.1
```

A pattern anchored on `sshd\[` would match nothing and the report would
show zero SSH failures on a system that had plenty.

---

## Task 1 — Persistent Journal

By default `Storage=auto` in `/etc/systemd/journald.conf` keeps the
journal in `/run/log/journal`, which is memory-backed and lost on
reboot. Creating `/var/log/journal` is sufficient to switch to
persistent storage; `journalctl --flush` moves the existing runtime
journal across immediately rather than waiting for the next boot.

Before:

```
$ ls /var/log/journal
ls: cannot access '/var/log/journal': No such file or directory

$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
  0 e3d9b17b4e3f41ac9dd924820873a2d1 Wed 2026-06-24 19:34:12 IST Tue 2026-09-15 17:40:18 IST
```

After `mkdir` and `--flush`:

```
$ sudo ls /var/log/journal
6385b12322774591b8bf9289a42027af
```

After a reboot, the previous boot is still queryable:

```
$ journalctl --list-boots
IDX BOOT ID                          FIRST ENTRY                 LAST ENTRY
 -1 e3d9b17b4e3f41ac9dd924820873a2d1 Tue 2026-09-15 17:40:46 IST Tue 2026-09-15 17:44:30 IST
  0 5a3a323686f24fa7a35f1438324ae8e0 Tue 2026-09-15 17:44:44 IST Tue 2026-09-15 17:46:39 IST

$ sudo journalctl -b -1 | tail -5
... systemd-shutdown[1]: Sending SIGTERM to remaining processes...
... systemd-journald[1006]: Journal stopped
```

The `-1` index is the proof. Before the change there was only boot `0`,
because nothing survived a restart.

---

## Task 2 — Time Accuracy

```
$ timedatectl
               Local time: Tue 2026-09-15 17:33:30 IST
           Universal time: Tue 2026-09-15 12:03:30 UTC
                Time zone: Asia/Kolkata (IST, +0530)
System clock synchronized: yes
              NTP service: active

$ chronyc sources -v
MS Name/IP address         Stratum Poll Reach LastRx Last sample
^+ ntp5.mum-in.hosts.301-mo>     2  10   377    15    -15ms
^+ 139.59.55.93                  2  10   377   984  -2652us
^+ ec2-3-7-223-15.ap-south->     2  10   377   504  -1491us
^* 172-236-180-15.ip.linode>     5  10   377   932  -6323us

$ systemctl is-active chronyd
active
$ systemctl is-enabled chronyd
enabled
```

`^*` marks the currently selected source; `^+` marks sources combined
into the estimate. `Reach 377` is octal for eight consecutive
successful polls, meaning the source has been reliably contactable.

### Why log correlation is worthless without it

Every line in this report is identified by a timestamp, and nothing
else. If the clock drifts, three things break:

- **Ordering within a host becomes unreliable.** A digest that says an
  SSH failure happened before a service crash is only meaningful if
  the timestamps are trustworthy. A clock that jumps can reverse the
  apparent order of events that were seconds apart.
- **Correlation across hosts becomes impossible.** In a real
  deployment the same intruder appears in the firewall log on one
  machine, the SSH log on another, and the application log on a third.
  Joining those into one timeline requires all three clocks to agree.
  Two servers thirty seconds apart cannot be correlated at all.
- **The report window becomes wrong.** This script selects on
  `--since "-24 hours"`. If the clock is wrong, the window silently
  covers the wrong period and events are missed without any error.

A wrong clock does not produce an error message. It produces a report
that looks correct and is not, which is worse.

---

## Tasks 3 and 4 — Extraction and Counting

The script produces five sections. Section 4's logic:

```bash
IP_LIST=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$FAILS" | sort -u)

for IP in $IP_LIST; do
    COUNT=$(grep -c "$IP" "$FAILS")
    if [[ "$COUNT" -gt "$THRESHOLD" ]]; then
        echo "  ${IP}  ${COUNT} rejected  SUSPECT"
    else
        echo "  ${IP}  ${COUNT} rejected  ok"
    fi
done
```

### A counting bug that was found and fixed

The first working version counted every log line containing an IP
address. That over-reported by roughly a factor of two, because a
single SSH session with three wrong passwords writes six matching
lines: an `Invalid user` line, a `pam_unix ... authentication failure`
line, three `Failed password` lines, and a `PAM 2 more authentication
failures` summary.

The first run reported:

```
  127.0.0.1  12 failures  SUSPECT
  192.168.73.1  6 failures  SUSPECT
```

Both addresses were flagged, so the `else` branch had never executed
and nothing demonstrated that the threshold could decide *not* to flag.
Restricting the count to `Failed password` and `Failed publickey` — the
lines that represent an actual rejected credential — gives:

```
  127.0.0.1  6 rejected  SUSPECT
  192.168.73.1  3 rejected  ok
```

Six attempts from loopback (two sessions of three), three from the
host. Both branches now execute, and the number reported matches the
number of attempts actually made.

### Section 3 needed a limit

The first report was 9.8 MB. `journalctl -p err` returned 78,464
entries, of which 78,446 were one repeating VMware graphics driver
message:

```
kernel: [drm:vmw_kms_fb_create [vmwgfx]] *ERROR* failed to create vmw_framebuffer: -22
```

Printing all of them recreated the exact problem the project exists to
solve — burying the security findings in noise. Section 3 now prints a
frequency table of the ten most common messages plus the twenty most
recent entries. The report dropped from 9.8 MB to 8.5 KB.

The frequency table also surfaced something useful that was not
specifically searched for:

```
      1 sudo[20451]:     dev3 : command not allowed ; TTY=pts/0 ; USER=root ; COMMAND=list
      1 sudo[20282]:     dev2 : command not allowed ; TTY=pts/0 ; USER=root ; COMMAND=list
```

Two genuine privilege-escalation refusals, logged at error priority.

### Local failures have no IP

`su` failures are recorded without a source address:

```
su[3696]: pam_unix(su-l:auth): authentication failure; logname=auritro
          uid=1000 euid=0 tty=/dev/pts/0 ruser=auritro rhost=  user=dev2
```

`rhost=` is empty, because the attempt came from a local terminal.
These appear in section 1 but cannot appear in section 4. The script
handles the case where section 4 would otherwise be empty with an
explicit message rather than printing nothing.

---

## Task 5 — Scheduling

The timer was first run at `OnCalendar=*:0/5` to capture real evidence
of it firing, then switched to the production schedule. Five triggers
were observed in twenty minutes:

```
Sep 15 18:10:12 systemd[1]: Starting sentrylog.service ...
Sep 15 18:10:14 sentrylog.sh[4464]: Report written to /var/log/sentrylog/security_report_2026-09-15.txt
Sep 15 18:10:14 systemd[1]: Finished sentrylog.service ...
Sep 15 18:15:12 systemd[1]: Starting sentrylog.service ...
Sep 15 18:20:12 systemd[1]: Starting sentrylog.service ...
Sep 15 18:25:12 systemd[1]: Starting sentrylog.service ...
Sep 15 18:30:10 systemd[1]: Starting sentrylog.service ...
```

Production schedule confirmed:

```
$ systemctl list-timers sentrylog.timer
NEXT                        LEFT LAST                        PASSED UNIT
Wed 2026-09-16 06:00:00 IST  11h Tue 2026-09-15 18:35:12 IST      - sentrylog.timer

$ systemctl is-enabled sentrylog.timer
enabled
```

Cron was tested the same way, temporarily at `*/5`:

```
Sep 15 18:45:01 CROND[5100]: (root) CMD (/usr/local/bin/sentrylog.sh cron)
Sep 15 18:45:02 CROND[5099]: (root) CMDOUT (Report written to .../security_report_2026-09-15_cron.txt)
Sep 15 18:50:01 CROND[5160]: (root) CMD (/usr/local/bin/sentrylog.sh cron)
```

Both schedulers were then set to 06:00. The comparison is in
`timer_vs_cron.md`.

`/etc/cron.d/` was used rather than `crontab -e` because this is a
system job owned by the machine, not by a user. A `/etc/cron.d` file
includes a user field, is version-controllable, and does not disappear
if the account that created it is removed.

---

## Task 6 — Housekeeping

`/etc/tmpfiles.d/sentrylog.conf`:

```
# Type Path               Mode UID  GID  Age
d /var/log/sentrylog 0700 root root 30d
```

Type `d` creates the directory if missing and, when `--clean` runs,
deletes contents older than the age field. The daily
`systemd-tmpfiles-clean.timer` applies it automatically:

```
$ systemctl status systemd-tmpfiles-clean.timer
     Active: active (waiting) since Tue 2026-09-15 17:45:03 IST
    Trigger: Wed 2026-09-16 18:00:10 IST; 23h left
```

### Why backdating a file with `touch` does not test this

The obvious test — `touch -d "40 days ago"` on a dummy file, then
`--clean` — does not work, and understanding why matters more than the
test itself.

`touch -d` sets atime and mtime. It cannot set **ctime**, which the
kernel updates on any inode change and which no userspace tool can
backdate. `systemd-tmpfiles --clean` considers all three timestamps and
deletes only when every one of them is older than the threshold. The
backdated file therefore has a ctime of seconds ago and survives:

```
$ sudo touch -d "40 days ago" /var/log/sentrylog/old_report_test.txt
$ sudo systemd-tmpfiles --clean /etc/tmpfiles.d/sentrylog.conf
$ sudo ls -l --time-style=long-iso /var/log/sentrylog/
-rw-r--r--. 1 root root 0 2026-08-06 19:14 old_report_test.txt
```

The rule was not broken. The test was.

### How it was actually verified

The age field was temporarily reduced to `60s`, letting all three
timestamps age naturally past the threshold:

```
$ sudo sed -i 's/ 30d$/ 60s/' /etc/tmpfiles.d/sentrylog.conf
$ sudo touch /var/log/sentrylog/short_age_test.txt
$ sudo ls -l --time-style=long-iso /var/log/sentrylog/
-rw-r--r--. 1 root root       0 2026-08-06 19:14 old_report_test.txt
-rw-r--r--. 1 root root 9811059 2026-09-15 18:50 security_report_2026-09-15_cron.txt
-rw-r--r--. 1 root root    8635 2026-09-15 19:12 security_report_2026-09-15.txt
-rw-r--r--. 1 root root       0 2026-09-15 19:17 short_age_test.txt

(90 seconds later)

$ sudo systemd-tmpfiles --clean /etc/tmpfiles.d/sentrylog.conf
$ sudo ls -l --time-style=long-iso /var/log/sentrylog/
total 0
```

Everything was removed, including the reports — correct behaviour, since
they were also older than 60 seconds. The rule acts on file age, not on
file name. The `30d` rule was then restored and the reports regenerated.

---

## Verification Summary

| # | Requirement | Verified by | Result |
|---|---|---|---|
| 1 | Journal not persistent initially | `ls /var/log/journal` | PASS |
| 2 | Journal persistent | `ls /var/log/journal/` shows machine-ID directory | PASS |
| 3 | Survives reboot | `journalctl --list-boots` shows `-1` | PASS |
| 4 | Previous boot readable | `journalctl -b -1` | PASS |
| 5 | Clock synchronised | `timedatectl`, `chronyc sources -v` | PASS |
| 6 | Failed auth extraction | report section 1, 22 entries | PASS |
| 7 | Service failures | report section 2, 9 entries | PASS |
| 8 | Priority err and above | report section 3, 78464 summarised | PASS |
| 9 | Per-IP counting | report section 4 | PASS |
| 10 | SUSPECT threshold, both branches | 127.0.0.1 flagged, 192.168.73.1 not | PASS |
| 11 | Timer fires | 5 triggers in 20 minutes in the journal | PASS |
| 12 | Timer at 06:00 | `systemctl list-timers` NEXT = next 06:00 | PASS |
| 13 | Survives downtime | `Persistent=true` in `systemctl cat` | PASS |
| 14 | Cron equivalent | `_cron` report + CROND journal entries | PASS |
| 15 | 30-day retention | short-age demonstration, rule restored | PASS |
| 16 | Reports not world-readable | directory mode `drwx------ root root` | PASS |

---

## How to Run

```bash
# Persistent journal
sudo mkdir /var/log/journal
sudo journalctl --flush
sudo systemctl reboot

# Script
sudo cp sentrylog.sh /usr/local/bin/sentrylog.sh
sudo chmod +x /usr/local/bin/sentrylog.sh
sudo /usr/local/bin/sentrylog.sh

# Timer
sudo cp units/sentrylog.service /etc/systemd/system/
sudo cp units/sentrylog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now sentrylog.timer
systemctl list-timers sentrylog.timer

# Cron alternative
sudo cp units/cron-sentrylog /etc/cron.d/sentrylog
sudo chmod 0644 /etc/cron.d/sentrylog

# Retention
sudo cp units/tmpfiles-sentrylog.conf /etc/tmpfiles.d/sentrylog.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/sentrylog.conf
```

Reading a report requires root, since `/var/log/sentrylog` is mode
`0700`:

```bash
sudo cat /var/log/sentrylog/security_report_$(date +%F).txt
```

---

## Repository Layout

```
SentryLog/
├── README.md
├── timer_vs_cron.md
├── sentrylog.sh
├── security_report_2026-09-15.txt
├── commands.txt
└── units/
    ├── sentrylog.service
    ├── sentrylog.timer
    ├── cron-sentrylog
    └── tmpfiles-sentrylog.conf
```

---

## Limitations / Assumptions

- **The failed logins are synthetic.** A freshly installed VM on a NAT
  network receives no attack traffic, so the authentication failures in
  the sample report were generated deliberately: seven SSH attempts
  from the host at 192.168.73.1 and two sessions against 127.0.0.1.
  Nothing in this report represents a real intrusion attempt.
- **Two source IPs only.** Per-IP counting is demonstrated against the
  host and loopback. Behaviour with hundreds of distinct addresses is
  untested, and the `for` loop calling `grep -c` once per address would
  become slow at that scale. An `awk` or associative-array
  implementation would be the production approach; the loop was chosen
  because RH134 Ch 1 places associative arrays out of scope.
- **The threshold is arbitrary.** More than five rejected credentials
  from one address in 24 hours flags as SUSPECT. This is the value the
  assignment specifies, not a tuned figure. A real deployment would set
  it from observed baseline traffic.
- **No alerting.** The script writes a file. It does not email, page,
  or block anything. Adding `fail2ban` or a firewall response would be
  the natural next step and is outside this assignment.
- **Timestamps are local.** The VM runs IST, so report filenames and
  window boundaries follow Indian local time. A multi-site deployment
  would standardise on UTC so reports from different regions can be
  compared without conversion.
- **`grep -c "$IP"` matches substrings.** With the two addresses used
  here this is safe, but `192.168.73.1` would also match
  `192.168.73.10` if that host appeared. A production version would
  anchor the match on word boundaries.
- Tested on a single RHEL 10 VM under VMware. Journal sizes, error
  volumes and driver noise will differ on physical hardware — in
  particular the 78,000 `vmwgfx` errors are an artefact of the virtual
  graphics adapter and would not appear on a real server.
