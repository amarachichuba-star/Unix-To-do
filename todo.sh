#!/usr/bin/env bash
#
# todo.sh - Command-line To-Do List Manager (POSIX-ish Bash)
#
# Features:
#  - Multiple lists (each list is a separate file)
#  - Add, view, search, modify, delete, complete tasks
#  - Task fields: ID, description, due (YYYY-MM-DD), priority (high|medium|low), tags (comma separated), status (Incomplete|Done), recurrence (none|daily|weekly|monthly|yearly)
#  - Recurring tasks: next instance auto-created when marking complete
#  - Filtering (by priority, tag, due range), sorting (due, priority, id)
#  - Archive completed tasks
#  - Default list setting via config (~/.todo/config)
#
# Storage:
#  - Data directory: ~/.todo (or $PWD/.todo if you prefer)
#  - List files: <listname>.todo (pipe-separated fields)
#  - Archive files: <listname>.archive
#  - File format (pipe-separated):
#    id|description|due|priority|tags|status|recurrence
#
# Requirements:
#  - bash
#  - GNU date for date math (uses `date -I -d ...`). If on BSD/macOS, consider installing coreutils or adjust date handling.
#
# Examples:
#  ./todo.sh --list work --add "Finish report" --due 2025-12-01 --priority high --tags work,report
#  ./todo.sh --list personal --view --priority high --sort due
#  ./todo.sh --list work --complete 3
#  ./todo.sh --list home --search "groceries"
#
###############################################################################

set -euo pipefail
IFS=$'\n\t'

# Configuration and paths
TODO_DIR="${HOME}/.todo"
CONFIG_FILE="${TODO_DIR}/config"
mkdir -p "$TODO_DIR"

# helper: ensure list file exists
ensure_list_file() {
  local listfile="$1"
  if [[ ! -f "$listfile" ]]; then
    # create with header comment (not used programmatically)
    echo "# id|description|due|priority|tags|status|recurrence" > "$listfile"
  fi
}

list_path() {
  local listname="$1"
  echo "${TODO_DIR}/${listname}.todo"
}

archive_path() {
  local listname="$1"
  echo "${TODO_DIR}/${listname}.archive"
}

########### Utilities ###########

usage() {
  cat <<EOF
Usage: $0 [--list <name>] <command> [options]

Commands:
  --add "desc"               Add a new task (use --due, --priority, --tags, --recurrence)
  --view                     View tasks (use --priority, --tag, --due, --sort, --status)
  --search "keyword"         Search tasks by keyword (description or tags)
  --complete <id>            Mark task <id> as completed (creates next instance if recurring)
  --delete <id>              Delete task <id>
  --modify <id> --field val  Modify fields: --desc, --due, --priority, --tags, --recurrence
  --archive                  Move completed tasks to archive file
  --export --field val       Export list. Export fields: --csv, --json, --txt
  --set-default <list>       Set default list
  --help                     Show this help

Global options:
  --list <name>              Select list to work with (default from config)
  --list-create <name>       Create a new list
  --show-lists               Show existing lists
  --export --field val       Export default list. Export fields: --csv, --json, --txt
Examples:
  $0 --list work --add "Finish report" --due 2025-12-01 --priority high --tags work,report
  $0 --list personal --view --priority high --sort due
EOF
  exit 0
}

err() { echo "ERROR: $*" >&2; exit 1; }

# read default list from config if no --list provided
get_default_list() {
  if [[ -f "$CONFIG_FILE" ]]; then
    awk -F'=' '/^default_list=/ { print substr($0, index($0,$2)) }' "$CONFIG_FILE" | tr -d ' \t'
  fi
}

set_default_list() {
  local list="$1"
  mkdir -p "$TODO_DIR"
  echo "default_list=${list}" > "$CONFIG_FILE"
  echo "Default list set to: $list"
}

# sanitize description (strip newlines and pipes)
sanitize() {
  local s="$*"
  s="${s//$'\n'/ }"
  s="${s//|/ }"
  echo "$s"
}

# get next numeric ID for a list
next_id() {
  local listfile="$1"
  # ignore commented lines
  if [[ ! -s "$listfile" ]] || [[ "$(grep -v '^#' "$listfile" | wc -l)" -eq 0 ]]; then
    echo 1
    return
  fi
  awk -F'|' '!/^#/ { if($1+0>max) max=$1 } END{ print (max+1) }' "$listfile"
}

# date validation YYYY-MM-DD
is_valid_date() {
  local d="$1"
  if [[ -z "$d" ]]; then
    return 1
  fi
  if ! date -d "$d" "+%Y-%m-%d" >/dev/null 2>&1; then
    return 1
  fi
  # ensure output equals input when formatted
  local out
  out=$(date -d "$d" "+%Y-%m-%d")
  [[ "$out" == "$d" ]]
}

# add days/weeks/months/years to date
date_add() {
  local date="$1"
  local recurrence="$2"
  case "$recurrence" in
    daily) echo "$(date -I -d "$date + 1 day")" ;;
    weekly) echo "$(date -I -d "$date + 1 week")" ;;
    monthly) echo "$(date -I -d "$date + 1 month")" ;;
    yearly) echo "$(date -I -d "$date + 1 year")" ;;
    *) return 1 ;;
  esac
}

# priority numeric for sorting: high=1, medium=2, low=3, else 4
priority_num() {
  case "$1" in
    high) echo 1 ;;
    medium) echo 2 ;;
    low) echo 3 ;;
    *) echo 4 ;;
  esac
}

# human-readable pretty print
pretty_line() {
  local id="$1"; shift
  local desc="$1"; shift
  local due="$1"; shift
  local pr="$1"; shift
  local tags="$1"; shift
  local status="$1"; shift
  local rec="$1"; shift

  # compute due status (Overdue / Today / In X days)
  local due_note=""
  if [[ -n "$due" && "$due" != "none" ]]; then
    if is_valid_date "$due"; then
      local today=$(date -I)
      if [[ "$due" < "$today" && "$status" != "Done" ]]; then
        due_note="Overdue"
      elif [[ "$due" == "$today" ]]; then
        due_note="Today"
      else
        # compute days difference
        local diff=$(( ( $(date -d "$due" +%s) - $(date -d "$today" +%s) ) / 86400 ))
        due_note="${diff}d"
      fi
    fi
  fi

  printf "[%s] %s | %s | %s | %s | %s" "$id" "$desc" "${due:--}" "${pr:--}" "${tags:--}" "${status:--}"
  if [[ -n "$rec" && "$rec" != "none" ]]; then
    printf " | recur:%s" "$rec"
  fi
  if [[ -n "$due_note" ]]; then
    printf " | %s" "$due_note"
  fi
  printf "\n"
}

# print header for viewing
print_view_header() {
  echo "ID | Description | Due | Priority | Tags | Status | (recurrence)"
  echo "-------------------------------------------------------------------"
}

########### Core actions ###########

cmd_add() {
  # expects vars: LIST, ADD_DESC, ADD_DUE, ADD_PRIORITY, ADD_TAGS, ADD_RECURRENCE
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  if [[ -z "${ADD_DESC:-}" ]]; then
    err "No description given. Use --add \"description\""
  fi

  local desc
  desc="$(sanitize "$ADD_DESC")"

  local due="${ADD_DUE:-}"
  if [[ -n "$due" ]]; then
    if ! is_valid_date "$due"; then
      err "Invalid due date: $due (use YYYY-MM-DD)"
    fi
  else
    due="none"
  fi

  local pr="${ADD_PRIORITY:-}"
  pr="${pr:-none}"
  pr=$(echo "$pr" | tr '[:upper:]' '[:lower:]')

  local tags="${ADD_TAGS:-}"
  tags="${tags// /}"   # remove spaces in tag list

  local rec="${ADD_RECURRENCE:-none}"
  rec=$(echo "$rec" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$rec" ]]; then rec="none"; fi
  if [[ "$rec" != "none" && ! "$rec" =~ ^(daily|weekly|monthly|yearly)$ ]]; then
    err "Recurrence must be: none,daily,weekly,monthly,yearly"
  fi

  local id
  id=$(next_id "$listfile")

  echo "${id}|${desc}|${due}|${pr}|${tags}|Incomplete|${rec}" >> "$listfile"
  echo "Added task [${id}] to list '$LIST'."
}

cmd_view() {
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  print_view_header

  # build awk filter based on filters
  # filters: VIEW_PRIORITY, VIEW_TAG, VIEW_DUE (like "week"), VIEW_STATUS
  local awk_prog='BEGIN { FS="|"; OFS="|" } !/^#/ { keep=1; desc=$2; due=$3; pr=$4; tags=$5; status=$6; rec=$7; id=$1;'
  if [[ -n "${VIEW_PRIORITY:-}" ]]; then
    awk_prog+=' if(tolower(pr) != "'"$VIEW_PRIORITY"'" ) keep=0;'
  fi
  if [[ -n "${VIEW_TAG:-}" ]]; then
    awk_prog+=' if(index(","tags",",tolower("'"${VIEW_TAG}"'")",")==0 && index(tolower(tags),tolower("'"${VIEW_TAG}"'"))==0) keep=0;'
  fi
  if [[ -n "${VIEW_STATUS:-}" ]]; then
    awk_prog+=' if(tolower(status) != "'"$VIEW_STATUS"'" ) keep=0;'
  fi
  if [[ -n "${VIEW_DUE:-}" ]]; then
    # support "today", "overdue", "week" (7 days)
    if [[ "$VIEW_DUE" == "today" ]]; then
      local today
      today=$(date -I)
      awk_prog+=' if(due != "'"$today"'" ) keep=0;'
    elif [[ "$VIEW_DUE" == "overdue" ]]; then
      local today
      today=$(date -I)
      awk_prog+=' if(due >= "'"$today"'" || status == "Done") keep=0;'
    elif [[ "$VIEW_DUE" == "week" ]]; then
      local today weekend
      today=$(date -I)
      weekend=$(date -I -d "$today + 7 days")
      awk_prog+=' if(due < "'"$today"'" || due > "'"$weekend"'" ) keep=0;'
    else
      # exact date
      awk_prog+=' if(due != "'"$VIEW_DUE"'" ) keep=0;'
    fi
  fi

  awk_prog+=' if(keep==1) { print id,desc,due,pr,tags,status,rec } }'

  # produce lines to be sorted if required
  local raw_lines
  raw_lines=$(awk "$awk_prog" "$listfile" | sed '/^$/d')

  if [[ -z "$raw_lines" ]]; then
    echo "(no tasks match)"
    return
  fi

  # Sorting
  if [[ -n "${VIEW_SORT:-}" ]]; then
    case "$VIEW_SORT" in
      due)
        # lines: id|desc|due|pr|tags|status|rec
        # sort by due (none goes last)
        sorted=$(echo "$raw_lines" | awk -F'|' '{ if($3=="none") d="9999-12-31"; else d=$3; print d "|" $0 }' | sort -t'|' -k1,1 | cut -d'|' -f2-)
        ;;
      priority)
        # convert priority to numeric then sort
        sorted=$(echo "$raw_lines" | awk -F'|' '{ pr=tolower($4); if(pr=="high") p=1; else if(pr=="medium") p=2; else if(pr=="low") p=3; else p=4; print p "|" $0 }' | sort -n -t'|' -k1,1 | cut -d'|' -f2-)
        ;;
      id)
        sorted=$(echo "$raw_lines" | sort -t'|' -k1,1n)
        ;;
      *)
        sorted="$raw_lines"
        ;;
    esac
  else
    sorted="$raw_lines"
  fi

  # Print pretty
  while IFS='|' read -r id desc due pr tags status rec; do
    pretty_line "$id" "$desc" "$due" "$pr" "$tags" "$status" "$rec"
  done <<< "$sorted"
}

cmd_search() {
  local query="$1"
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  print_view_header

  # Convert query to lowercase one time
  local lq
  lq=$(echo "$query" | tr '[:upper:]' '[:lower:]')

  awk -F'|' -v q="$lq" '
    BEGIN { }
    !/^#/ {
      # convert fields to lowercase for comparison
      desc = tolower($2)
      tags = tolower($5)

      if (index(desc, q) > 0 || index(tags, q) > 0) {
        printf("[%s] %s | %s | %s | %s | %s\n",
               $1,$2,$3,$4,$5,$6)
      }
    }
  ' "$listfile"
}

cmd_complete() {
  local id="$1"
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  # find line
  local ln
  ln=$(awk -F'|' -v id="$id" '!/^#/ && $1==id { print NR ":" $0; exit }' "$listfile" || true)
  if [[ -z "$ln" ]]; then
    err "Task id $id not found in list '$LIST'."
  fi
  local lineno="${ln%%:*}"
  local line="${ln#*:}"

  IFS='|' read -r tid desc due pr tags status rec <<< "$line"

  # mark as Done and replace the line
  awk -F'|' -v id="$id" 'BEGIN{OFS=FS} !/^#/ { if($1==id){ $6="Done"; print $0 } else print $0 }' "$listfile" > "${listfile}.tmp" && mv "${listfile}.tmp" "$listfile"
  echo "Marked task [$id] Done."

  # handle recurrence
  if [[ -n "$rec" && "$rec" != "none" ]]; then
    if [[ "$due" == "none" ]]; then
      echo "Recurring task had no due date; not auto-creating next occurrence."
      return
    fi
    if ! is_valid_date "$due"; then
      echo "Original due date invalid; skipping recurrence creation."
      return
    fi

    local next_due
    if next_due=$(date_add "$due" "$rec" 2>/dev/null); then
      local newid
      newid=$(next_id "$listfile")
      # create new task with same desc, priority, tags, recurrence and Incomplete status
      echo "${newid}|${desc}|${next_due}|${pr}|${tags}|Incomplete|${rec}" >> "$listfile"
      echo "Created recurring next instance as task [${newid}] due ${next_due}."
    else
      echo "Could not compute next due date for recurrence '$rec'."
    fi
  fi
}

cmd_delete() {
  local id="$1"
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  if ! awk -F'|' -v id="$id" '!/^#/ && $1==id { found=1 } END{ if(found) exit 0; else exit 1 }' "$listfile"; then
    err "Task id $id not found."
  fi

  awk -F'|' -v id="$id" 'BEGIN{OFS=FS} !/^#/ { if($1==id) { next } else print $0 }' "$listfile" > "${listfile}.tmp" && mv "${listfile}.tmp" "$listfile"
  echo "Deleted task [$id]."
}

cmd_modify() {
  local id="$1"
  shift
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  if ! awk -F'|' -v id="$id" '!/^#/ && $1==id { found=1 } END{ if(found) exit 0; else exit 1 }' "$listfile"; then
    err "Task id $id not found."
  fi

  # read original and prepare modifications
  local orig
  orig=$(awk -F'|' -v id="$id" '!/^#/ && $1==id { print $0; exit }' "$listfile")
  IFS='|' read -r tid desc due pr tags status rec <<< "$orig"

  # parse modifications from env vars: MOD_DESC, MOD_DUE, MOD_PRIORITY, MOD_TAGS, MOD_RECURRENCE
  desc="${MOD_DESC:-$desc}"
  due="${MOD_DUE:-$due}"
  pr="${MOD_PRIORITY:-$pr}"
  tags="${MOD_TAGS:-$tags}"
  rec="${MOD_RECURRENCE:-$rec}"

  # sanitize/validate
  desc="$(sanitize "$desc")"
  if [[ -n "$due" && "$due" != "none" ]]; then
    if ! is_valid_date "$due"; then
      err "Invalid due date: $due"
    fi
  fi
  if [[ -n "$rec" && "$rec" != "none" ]]; then
    if ! [[ "$rec" =~ ^(daily|weekly|monthly|yearly)$ ]]; then
      err "Invalid recurrence: $rec"
    fi
  fi

  # update file
  awk -F'|' -v id="$id" -v desc="$desc" -v due="$due" -v pr="$pr" -v tags="$tags" -v rec="$rec" 'BEGIN{OFS=FS} !/^#/ { if($1==id){ $2=desc; $3=due; $4=pr; $5=tags; $7=rec; print $0 } else print $0 }' "$listfile" > "${listfile}.tmp" && mv "${listfile}.tmp" "$listfile"
  echo "Modified task [$id]."
}

cmd_archive() {
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"
  local archivefile
  archivefile="$(archive_path "$LIST")"

  # move completed tasks to archive
  awk -F'|' 'BEGIN{OFS=FS} !/^#/ { if($6=="Done") print $0 > "'"$archivefile"'" ; else print $0 > "'"${listfile}.tmp"'" }' "$listfile"
  # If temporary file missing (no incomplete tasks), create empty file
  if [[ ! -f "${listfile}.tmp" ]]; then
    touch "${listfile}.tmp"
  fi
  mv "${listfile}.tmp" "$listfile"
  echo "Archived completed tasks to $archivefile"
}

export_selection_menu() {
  echo "Choose export format:"
  echo "  --csv      Export as CSV"
  echo "  --txt      Export as Pretty Text"
  echo "  --json     Export as JSON"
  echo
  echo "Usage examples:"
  echo "  $0 --list $LIST --export --csv"
  echo "  $0 --list $LIST --export --json"
  echo "  $0 --list $LIST --export --txt"
  exit 0
}

cmd_export_csv() {
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  local outfile="${LIST}.csv"

  echo "id,description,due,priority,tags,status,recurrence" > "$outfile"

  awk -F'|' '!/^#/ {
    printf "%s,%s,%s,%s,%s,%s,%s\n",
      $1,$2,$3,$4,$5,$6,$7
  }' "$listfile" >> "$outfile"

  echo "Exported CSV to $outfile"
}

cmd_export_json() {
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  local outfile="${LIST}.json"

  echo "[" > "$outfile"

  awk -F'|' '
    !/^#/ {
      printf "  {\"id\": %s, \"description\": \"%s\", \"due\": \"%s\", \"priority\": \"%s\", \"tags\": \"%s\", \"status\": \"%s\", \"recurrence\": \"%s\"},\n",
        $1,$2,$3,$4,$5,$6,$7
    }
  ' "$listfile" | sed '$ s/,$//' >> "$outfile"   # remove last comma safely

  echo "]" >> "$outfile"

  echo "Exported JSON to $outfile"
}

cmd_export_txt() {
  local listfile
  listfile="$(list_path "$LIST")"
  ensure_list_file "$listfile"

  local outfile="${LIST}.txt"

  {
    echo "ID | Description | Due | Priority | Tags | Status | Recurrence"
    echo "-------------------------------------------------------------------"
    awk -F'|' '!/^#/ {
      printf("[%s] %s | %s | %s | %s | %s | %s\n",
        $1,$2,$3,$4,$5,$6,$7)
    }'
  } < "$listfile" > "$outfile"

  echo "Exported pretty text to $outfile"
}

show_lists() {
  echo "Existing lists in $TODO_DIR:"
  local found=0
  for f in "$TODO_DIR"/*.todo; do
    [[ -e "$f" ]] || continue
    found=1
    basename="${f##*/}"
    echo "  - ${basename%.todo}"
  done
  if [[ $found -eq 0 ]]; then
    echo "  (no lists)"
  fi
}

########### Argument parsing ###########
if [[ $# -eq 0 ]]; then
  usage
fi

# Defaults
LIST=""
COMMAND=""
# Add-related
ADD_DESC=""
ADD_DUE=""
ADD_PRIORITY=""
ADD_TAGS=""
ADD_RECURRENCE=""
# View-related
VIEW_PRIORITY=""
VIEW_TAG=""
VIEW_DUE=""
VIEW_SORT=""
VIEW_STATUS=""
# Modify-related
MOD_DESC=""
MOD_DUE=""
MOD_PRIORITY=""
MOD_TAGS=""
MOD_RECURRENCE=""
IN_VIEW_MODE=0

# Parse basic args loop
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      ;;
    --list)
      shift
      LIST="${1:-}"
      shift
      ;;
    --list-create)
      shift
      if [[ -z "${1:-}" ]]; then err "--list-create requires a name"; fi
      newlist="${1}"
      touch "$(list_path "$newlist")"
      echo "Created list '$newlist' at $(list_path "$newlist")"
      shift
      ;;
    --show-lists)
      show_lists
      exit 0
      ;;
    --set-default)
      shift
      if [[ -z "${1:-}" ]]; then err "--set-default requires a list name"; fi
      set_default_list "$1"
      exit 0
      ;;
    --add)
      COMMAND="add"
      shift
      if [[ -z "${1:-}" ]]; then err "--add requires description in quotes"; fi
      ADD_DESC="${1}"
      shift
      ;;
--priority)
  shift
  if [[ $IN_VIEW_MODE -eq 1 ]]; then
    VIEW_PRIORITY="${1:-}"
  else
    ADD_PRIORITY="${1:-}"
  fi
  shift
  ;;
--due)
  shift
  if [[ $IN_VIEW_MODE -eq 1 ]]; then
    VIEW_DUE="${1:-}"
  else
    ADD_DUE="${1:-}"
  fi
  shift
  ;;
--tags)
  shift
  if [[ $IN_VIEW_MODE -eq 1 ]]; then
    VIEW_TAG="${1:-}"
  else
    ADD_TAGS="${1:-}"
  fi
  shift
  ;;

    --recurrence|--recur)
      shift
      ADD_RECURRENCE="${1:-}"
      shift
      ;;
--view)
  COMMAND="view"
  IN_VIEW_MODE=1
  shift
  ;;

    --due-filter|--due-filter)
      shift
      VIEW_DUE="${1:-}"
      shift
      ;;
    --sort)
      shift
      VIEW_SORT="${1:-}"
      shift
      ;;
    --status)
      shift
      VIEW_STATUS="${1:-}"
      shift
      ;;
    --search)
      COMMAND="search"
      shift
      SEARCH_Q="${1:-}"
      shift
      ;;
    --complete)
      COMMAND="complete"
      shift
      COMPLETE_ID="${1:-}"
      shift
      ;;
    --delete)
      COMMAND="delete"
      shift
      DELETE_ID="${1:-}"
      shift
      ;;
    --modify)
      COMMAND="modify"
      shift
      MODIFY_ID="${1:-}"
      shift
      ;;
    --desc)
      shift
      MOD_DESC="${1:-}"
      shift
      ;;
    --tags)
      shift
      MOD_TAGS="${1:-}"
      shift
      ;;
    --archive)
      COMMAND="archive"
      shift
      ;;
    --show-archive)
      # print archive contents
      shift
      SHOW_ARCHIVE=1
      ;;
    --export)
      COMMAND="export"
      shift
      # check if the user already provided a format
      case "${1:-}" in
        --csv) EXPORT_FORMAT="csv"; shift ;;
        --txt) EXPORT_FORMAT="txt"; shift ;;
        --json) EXPORT_FORMAT="json"; shift ;;
        csv|txt|json) EXPORT_FORMAT="${1}"; shift ;;
        *) EXPORT_FORMAT="" ;;   # no format yet, will show menu
      esac
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
done

# If list not provided, try config default
if [[ -z "$LIST" ]]; then
  LIST="$(get_default_list || true)"
fi
if [[ -z "$LIST" ]]; then
  # If still empty, default to "default"
  LIST="default"
fi

# Execute requested command
case "$COMMAND" in
  add)
    cmd_add
    ;;
  view|"" )
    # If no command specified, default to view
    if [[ "$COMMAND" == "" ]]; then
      COMMAND="view"
    fi
    cmd_view
    ;;
  search)
    if [[ -z "${SEARCH_Q:-}" ]]; then err "--search requires a query"; fi
    cmd_search "$SEARCH_Q"
    ;;
  complete)
    if [[ -z "${COMPLETE_ID:-}" ]]; then err "--complete requires an id"; fi
    cmd_complete "$COMPLETE_ID"
    ;;
  delete)
    if [[ -z "${DELETE_ID:-}" ]]; then err "--delete requires an id"; fi
    cmd_delete "$DELETE_ID"
    ;;
  modify)
    if [[ -z "${MODIFY_ID:-}" ]]; then err "--modify requires an id"; fi
    # pass modifications via environment variables used in cmd_modify
    MOD_DESC="${MOD_DESC:-}"
    MOD_DUE="${MOD_DUE:-}"
    MOD_PRIORITY="${MOD_PRIORITY:-}"
    MOD_TAGS="${MOD_TAGS:-}"
    MOD_RECURRENCE="${MOD_RECURRENCE:-}"
    export MOD_DESC MOD_DUE MOD_PRIORITY MOD_TAGS MOD_RECURRENCE
    cmd_modify "$MODIFY_ID"
    ;;
  archive)
    cmd_archive
    ;;
  export)
    if [[ -z "${EXPORT_FORMAT:-}" ]]; then
      export_selection_menu
    fi

    case "$EXPORT_FORMAT" in
      csv)  cmd_export_csv ;;
      txt)  cmd_export_txt ;;
      json) cmd_export_json ;;
      *) err "Unknown export format: $EXPORT_FORMAT" ;;
    esac
    ;;
  *)
    err "Unknown or unimplemented command: $COMMAND"
    ;;
esac

exit 0