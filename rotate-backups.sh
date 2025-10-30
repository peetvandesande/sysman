#!/usr/bin/env bash
# rotate-backups.sh
# Retention:
# - 1st-of-month: keep 12 months
# - Mondays: keep 4 weeks (28 days)
# - Others: keep 6 days

set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

usage() {
  cat <<EOF
Usage: $0 [--delete] [--dir /backup] [--glob "*.sql.gz"]

Options:
  --delete           Actually delete files (default is dry-run).
  --dir DIR          Directory to scan (default: /backup).
  --glob PATTERN     Glob pattern to match backups (default: *.sql.gz).

Notes:
- Files must contain a date in the form YYYYMMDD before the extension, e.g. prefix-20251029.sql.gz
- Dry-run shows what WOULD be deleted; no changes made unless --delete is specified.
EOF
}

# Defaults
DO_DELETE=0
DIR="/backup"
GLOB="*.sql.gz"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete) DO_DELETE=1; shift;;
    --dir)    DIR="${2:-}"; shift 2;;
    --glob)   GLOB="${2:-}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ ! -d "$DIR" ]]; then
  echo "ERROR: Directory not found: $DIR" >&2
  exit 1
fi

# Compute cutoff timestamps
now_ts=$(date +%s)
cutoff_daily_ts=$(date -d '-6 days' +%s)
cutoff_monday_ts=$(date -d '-28 days' +%s)
cutoff_monthly_ts=$(date -d '-12 months' +%s)

printf 'Rotation policy:\n'
printf '  Monthly (1st): keep since %s\n'  "$(date -d @${cutoff_monthly_ts} +%Y-%m-%d)"
printf '  Mondays:       keep since %s\n'  "$(date -d @${cutoff_monday_ts}  +%Y-%m-%d)"
printf '  Others:        keep since %s\n\n' "$(date -d @${cutoff_daily_ts}   +%Y-%m-%d)"

shopt -s nullglob
cd "$DIR"

to_delete=()
kept=()

match_any=0
for f in $GLOB; do
  [[ -f "$f" ]] || continue
  match_any=1

  # Extract YYYYMMDD just before the first . in the final component
  # Accept names like: prefix-YYYYMMDD.sql.gz or just YYYYMMDD.sql.gz
  if [[ "$f" =~ ([0-9]{8})\. ]]; then
    ymd="${BASH_REMATCH[1]}"
  else
    printf 'SKIP (no date): %s\n' "$f" >&2
    continue
  fi

  # Parse date parts
  yyyy=${ymd:0:4}
  mm=${ymd:4:2}
  dd=${ymd:6:2}

  # Validate with date(1)
  if ! file_ts=$(date -d "${yyyy}-${mm}-${dd}" +%s 2>/dev/null); then
    printf 'SKIP (invalid date): %s\n' "$f" >&2
    continue
  fi

  # Determine weekday and first-of-month
  # %u: 1..7 (Mon..Sun)
  wday=$(date -d "${yyyy}-${mm}-${dd}" +%u)
  is_first_of_month=0
  [[ "$dd" == "01" ]] && is_first_of_month=1
  is_monday=0
  [[ "$wday" == "1" ]] && is_monday=1

  # Decide retention class
  action="keep"
  reason=""

  if (( is_first_of_month )); then
    # Monthly retention
    if (( file_ts < cutoff_monthly_ts )); then
      action="delete"; reason="monthly>12mo"
    else
      reason="monthly<=12mo"
    fi
  elif (( is_monday )); then
    # Monday retention
    if (( file_ts < cutoff_monday_ts )); then
      action="delete"; reason="monday>28d"
    else
      reason="monday<=28d"
    fi
  else
    # Daily retention
    if (( file_ts < cutoff_daily_ts )); then
      action="delete"; reason="daily>6d"
    else
      reason="daily<=6d"
    fi
  fi

  # Report and record
  iso_date=$(date -d @${file_ts} +%Y-%m-%d)
  printf '%-7s %s  (%s; %s)\n' "$action" "$f" "$iso_date" "$reason"

  if [[ "$action" == "delete" ]]; then
    to_delete+=("$f")
  else
    kept+=("$f")
  fi
done

if (( ! match_any )); then
  echo "No files matched '$DIR/$GLOB'."
  exit 0
fi

echo
echo "Summary:"
echo "  Keep   : ${#kept[@]} file(s)"
echo "  Delete : ${#to_delete[@]} file(s)"
echo

if (( DO_DELETE )); then
  for f in "${to_delete[@]}"; do
    rm -f -- "$f"
  done
  echo "Deleted ${#to_delete[@]} file(s)."
else
  echo "Dry-run complete. Use --delete to actually remove files."
fi

