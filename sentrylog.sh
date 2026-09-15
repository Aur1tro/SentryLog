#!/usr/bin/bash
#
# SentryLog - automated security digest of the system journal
#
# Extracts failed authentication attempts, service failures and
# high-priority events from the last 24 hours, counts failures per
# source IP address, and writes a dated report.
#
# Usage:  sentrylog.sh [tag]
#         The optional tag is appended to the report file name so that
#         the systemd timer and the cron job can run side by side
#         without overwriting each other's output.

REPORT_DIR="/var/log/sentrylog"
WINDOW="-24 hours"
THRESHOLD=5
MAX_LINES=20
TAG="$1"

# journalctl exposes the complete journal only to root.
if [[ $(id -u) -ne 0 ]]; then
    echo "sentrylog: this script must be run as root" >&2
    exit 1
fi

# Mode 0700 matters: the working files below hold raw log lines, and a
# predictable path in a world-writable directory such as /tmp would be
# a symlink-attack target for a root-owned process.
mkdir -p "$REPORT_DIR"
chmod 0700 "$REPORT_DIR"

DATE=$(date +%F)
if [[ -n "$TAG" ]]; then
    REPORT="${REPORT_DIR}/security_report_${DATE}_${TAG}.txt"
else
    REPORT="${REPORT_DIR}/security_report_${DATE}.txt"
fi

WORK="${REPORT_DIR}/.window.tmp"
AUTH="${REPORT_DIR}/.auth.tmp"
FAILS="${REPORT_DIR}/.fails.tmp"
ERRS="${REPORT_DIR}/.errs.tmp"

# Read each journal view once rather than per section.
journalctl --since "$WINDOW" --no-pager > "$WORK"
journalctl --since "$WINDOW" -p err --no-pager > "$ERRS"

# Match on the message text rather than the process name. RHEL 10 logs
# SSH sessions under sshd-session, so a pattern anchored on sshd[ would
# silently miss every SSH failure on this system.
grep -E 'Failed password|Failed publickey|Invalid user|authentication failure' \
    "$WORK" > "$AUTH"

# Per-IP counting uses rejected credentials only. One SSH session with
# three wrong passwords also logs an Invalid user line and two PAM
# summary lines, so counting every line that mentions the address would
# report roughly double the real number of attempts.
grep -E 'Failed password|Failed publickey' "$AUTH" > "$FAILS"

AUTH_COUNT=$(wc -l < "$AUTH")
SERVICE_COUNT=$(grep -c -E 'Failed to start|Main process exited|Failed with result' "$WORK")
ERR_COUNT=$(wc -l < "$ERRS")

{
    echo "========================================"
    echo "SENTRYLOG SECURITY DIGEST"
    echo "========================================"
    echo "Host           : $(hostname)"
    echo "Generated      : $(date '+%F %T %Z')"
    echo "Journal window : last 24 hours"
    echo "Suspect rule   : more than ${THRESHOLD} rejected credentials from one IP"
    echo

    echo "----------------------------------------"
    echo "1. FAILED AUTHENTICATION (${AUTH_COUNT})"
    echo "----------------------------------------"
    if [[ "$AUTH_COUNT" -eq 0 ]]; then
        echo "No failed authentication attempts in this window."
    else
        cat "$AUTH"
    fi
    echo

    echo "----------------------------------------"
    echo "2. SERVICE FAILURES (${SERVICE_COUNT})"
    echo "----------------------------------------"
    if [[ "$SERVICE_COUNT" -eq 0 ]]; then
        echo "No service failures in this window."
    else
        grep -E 'Failed to start|Main process exited|Failed with result' "$WORK"
    fi
    echo

    echo "----------------------------------------"
    echo "3. PRIORITY err AND ABOVE (${ERR_COUNT})"
    echo "----------------------------------------"
    if [[ "$ERR_COUNT" -eq 0 ]]; then
        echo "No entries at priority err or above in this window."
    else
        # A single faulty driver can log tens of thousands of identical
        # lines. Printing them all would bury the security findings, so
        # the report shows the most frequent messages and the most
        # recent few instead of the raw flood.
        echo "Most frequent messages:"
        cut -d' ' -f5- "$ERRS" | sort | uniq -c | sort -rn | head -10
        echo
        echo "Most recent ${MAX_LINES} entries:"
        tail -n "$MAX_LINES" "$ERRS"
    fi
    echo

    echo "----------------------------------------"
    echo "4. REJECTED CREDENTIALS BY SOURCE IP"
    echo "----------------------------------------"
    IP_LIST=$(grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$FAILS" | sort -u)

    if [[ -z "$IP_LIST" ]]; then
        echo "No source IP addresses found in the failed authentication entries."
        echo "(Local su and login failures are recorded without an IP address.)"
    else
        SUSPECTS=0
        for IP in $IP_LIST; do
            COUNT=$(grep -c "$IP" "$FAILS")
            if [[ "$COUNT" -gt "$THRESHOLD" ]]; then
                echo "  ${IP}  ${COUNT} rejected  SUSPECT"
                SUSPECTS=$((SUSPECTS + 1))
            else
                echo "  ${IP}  ${COUNT} rejected  ok"
            fi
        done
        echo
        echo "Suspect addresses: ${SUSPECTS}"
    fi
    echo

    echo "----------------------------------------"
    echo "5. SUMMARY"
    echo "----------------------------------------"
    echo "Failed authentication entries  : ${AUTH_COUNT}"
    echo "Rejected credential attempts   : $(wc -l < "$FAILS")"
    echo "Service failures               : ${SERVICE_COUNT}"
    echo "Entries at err or above        : ${ERR_COUNT}"
    echo
    echo "End of report."
} > "$REPORT"

rm -f "$WORK" "$AUTH" "$FAILS" "$ERRS"

echo "Report written to ${REPORT}"
