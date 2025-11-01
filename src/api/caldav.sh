#!/usr/bin/env bash

if ! type to_upper >/dev/null 2>&1; then
    SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd -P)"
    source "${SCRIPT_DIR}/../lib/shell_compat.sh"
fi

caldav_tag_prefix="#cv"

caldav_slugify() {
    local input="$1"
    local slug
    slug=$(echo "$input" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '-')
    slug=${slug#-}
    slug=${slug%-}
    if [[ -z $slug ]]; then
        slug="caldav-$(date +%s)"
    fi
    echo "$slug"
}

caldav_encode_secret() {
    if [[ -z $1 ]]; then
        echo ""
        return
    fi
    printf '%s' "$1" | base64 | tr -d '\n'
}

caldav_decode_secret() {
    local encoded="$1"
    if [[ -z $encoded || $encoded == "" || $encoded == "null" ]]; then
        echo ""
        return
    fi
    if decoded=$(printf '%s' "$encoded" | base64 --decode 2>/dev/null); then
        printf '%s' "$decoded"
        return
    fi
    if decoded=$(printf '%s' "$encoded" | base64 -d 2>/dev/null); then
        printf '%s' "$decoded"
        return
    fi
    printf '%s' "$encoded"
}

caldav_remove_lines() {
    local slug="$1"
    local tempfile
    tempfile=$(mktemp)
    awk -v tag="${caldav_tag_prefix}:${slug}" 'BEGIN{FS=OFS=" "} $0 !~ tag"$" {print}' "$INPUT_FILE" >| "$tempfile" && mv "$tempfile" "$INPUT_FILE"
}

caldav_update_entry() {
    local slug="$1" name="$2" url="$3" username="$4" password="$5" category="$6" start_date="$7" end_date="$8" imported_date="$9" sync_hours="${10}" synced_at="${11}"
    jq \
        --arg slug "$slug" \
        --arg name "$name" \
        --arg url "$url" \
        --arg username "$username" \
        --arg password "$password" \
        --arg category "$category" \
        --arg start_date "$start_date" \
        --arg end_date "$end_date" \
        --arg imported_date "$imported_date" \
        --arg sync_hours "$sync_hours" \
        --arg synced_at "$synced_at" \
        '
        .caldav = (
            (.caldav // [])
            | map(if .slug == $slug then . else . end)
        )
        | if (.caldav | map(.slug == $slug) | any)
          then .caldav |= map(if .slug == $slug then . + {
                name: $name,
                url: $url,
                username: $username,
                password: $password,
                category: $category,
                start_date: $start_date,
                end_date: $end_date,
                imported_date: $imported_date,
                sync_interval_hours: $sync_hours,
                synced_at: $synced_at
            } else . end)
          else .caldav += [{
                slug: $slug,
                name: $name,
                url: $url,
                username: $username,
                password: $password,
                category: $category,
                start_date: $start_date,
                end_date: $end_date,
                imported_date: $imported_date,
                sync_interval_hours: $sync_hours,
                synced_at: $synced_at
            }]
          end
        ' "$SETTINGS" > tmp.$$.json && mv tmp.$$.json "$SETTINGS"
}

caldav_delete_entry() {
    local slug="$1"
    jq --arg slug "$slug" '.caldav = (.caldav // []) | map(select(.slug != $slug))' "$SETTINGS" > tmp.$$.json && mv tmp.$$.json "$SETTINGS"
}

caldav_select_category() {
    jq -r '.categories | to_entries[] | select(.key != "0") | "\(.key)\t\(.value.name)"' ${SETTINGS} | awk -v yellow="${yellow}" -v reset="${reset}" 'BEGIN{FS="\t"}{printf " [%s%s%s] %s\n", yellow, $1, reset, $2}'
    echo
    local selection
    while true; do
        read -p "Enter a category code: " selection
        if [[ -z ${defaults["categories[${selection}][name]"]} ]]; then
            echo "Invalid choice. Please enter a valid option."
            echo
        else
            echo "▸▸▸ Selected: ${defaults["categories[${selection}][name]"]}"
            echo
            break
        fi
    done
    echo "$selection"
}

caldav_prompt_range() {
    local prompt default_value input
    prompt="$1"
    default_value="$2"
    read -p "${prompt} [${default_value}]: " input
    if [[ -z $input ]]; then
        input=$default_value
    fi
    if [[ ! $input =~ ^[0-9]+$ ]]; then
        echo "Invalid number. Using ${default_value}."
        input=$default_value
    fi
    echo "$input"
}

caldav_fetch_response() {
    local url="$1" username="$2" password="$3" start="$4" end="$5"
    local outfile
    outfile=$(mktemp)
    local curl_args=("-fsSL")
    if [[ -n $username ]]; then
        curl_args+=("--user" "${username}:${password}")
    fi

    if [[ $url == *".ics" || $url == *"?export" ]]; then
        if ! curl "${curl_args[@]}" "$url" -o "$outfile"; then
            rm -f "$outfile"
            return 1
        fi
    else
        local start_utc end_utc
        start_utc=$(date -d "${start} 00:00:00" -u +%Y%m%dT000000Z 2>/dev/null)
        end_utc=$(date -d "${end} 23:59:59" -u +%Y%m%dT235959Z 2>/dev/null)
        read -r -d '' report_body <<XML
<?xml version="1.0" encoding="UTF-8"?>
<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  <D:prop>
    <D:getetag/>
    <C:calendar-data>
      <C:comp name="VCALENDAR">
        <C:comp name="VEVENT"/>
      </C:comp>
      <C:expand start="${start_utc}" end="${end_utc}"/>
    </C:calendar-data>
  </D:prop>
  <C:filter>
    <C:comp-filter name="VCALENDAR">
      <C:comp-filter name="VEVENT">
        <C:time-range start="${start_utc}" end="${end_utc}"/>
      </C:comp-filter>
    </C:comp-filter>
  </C:filter>
</C:calendar-query>
XML
        if ! curl "${curl_args[@]}" -X REPORT -H "Depth: 1" -H "Content-Type: application/xml; charset=utf-8" --data "${report_body}" "$url" -o "$outfile"; then
            rm -f "$outfile"
            return 1
        fi
    fi

    echo "$outfile"
}

caldav_parse_events() {
    local file="$1" category="$2" tag="$3" start="$4" end="$5"
    python3 - "$file" <<'PY'
import sys
import html
import re
from datetime import datetime, date, timedelta

path = sys.argv[1]
category = sys.argv[2]
tag = sys.argv[3]
range_start_date = datetime.strptime(sys.argv[4], "%Y/%m/%d").date()
range_end_date = datetime.strptime(sys.argv[5], "%Y/%m/%d").date()

try:
    with open(path, 'r', encoding='utf-8', errors='ignore') as handle:
        raw = handle.read()
except OSError:
    sys.exit(1)

if '<' in raw and '</' in raw:
    matches = re.findall(r'<(?:[A-Za-z0-9]+:)?calendar-data[^>]*>(.*?)</(?:[A-Za-z0-9]+:)?calendar-data>', raw, flags=re.S | re.I)
    if matches:
        raw = '\n'.join(matches)
    raw = html.unescape(raw)

lines = raw.splitlines()
unfolded = []
for line in lines:
    if not line:
        continue
    if line.startswith((' ', '\t')) and unfolded:
        unfolded[-1] += line[1:]
    else:
        unfolded.append(line.strip())

events = []
current = {}
for line in unfolded:
    if line.upper() == 'BEGIN:VEVENT':
        current = {}
        continue
    if line.upper() == 'END:VEVENT':
        if current:
            events.append(current)
        current = {}
        continue
    if ':' not in line:
        continue
    key_part, value = line.split(':', 1)
    key_tokens = key_part.split(';')
    key = key_tokens[0].upper()
    params = {}
    for token in key_tokens[1:]:
        if '=' in token:
            k, v = token.split('=', 1)
            params[k.upper()] = v
    current[key] = (value, params)

if not events:
    sys.exit(0)

def parse_dt(value, params):
    if params.get('VALUE') == 'DATE' or (len(value) == 8 and value.isdigit()):
        return datetime.strptime(value, '%Y%m%d').date()
    clean = value.rstrip('Z')
    fmt = '%Y%m%dT%H%M%S'
    if len(clean) == 13:
        fmt = '%Y%m%dT%H%M'
    try:
        return datetime.strptime(clean, fmt)
    except ValueError:
        return None

def normalize_summary(text):
    text = text.replace('\\n', ' ').replace('\n', ' ').strip()
    return re.sub(r'\s+', ' ', text)

output = []
for event in events:
    status = event.get('STATUS', ('', {}))[0].upper()
    if status == 'CANCELLED':
        continue
    summary = normalize_summary(event.get('SUMMARY', ('', {}))[0])
    if not summary:
        continue
    dtstart_raw = event.get('DTSTART')
    if not dtstart_raw:
        continue
    dtstart = parse_dt(*dtstart_raw)
    if dtstart is None:
        continue
    all_day = isinstance(dtstart, date) and not isinstance(dtstart, datetime)

    dtend_raw = event.get('DTEND')
    dtend_value = None
    if dtend_raw:
        dtend_value = parse_dt(*dtend_raw)
    if dtend_value is None:
        dtend_value = dtstart

    start_date_only = dtstart.date() if isinstance(dtstart, datetime) else dtstart

    if isinstance(dtend_value, datetime):
        event_end_date = dtend_value.date()
    else:
        event_end_date = dtend_value
    if all_day and event_end_date > start_date_only:
        event_end_date = event_end_date - timedelta(days=1)

    if event_end_date < range_start_date or start_date_only > range_end_date:
        continue

    range_start = max(start_date_only, range_start_date)
    range_end = min(event_end_date, range_end_date)

    if range_end < range_start:
        continue

    time_part = None
    if isinstance(dtstart, datetime):
        time_part = dtstart.strftime('%H:%M')

    detect = summary.lower()
    summary_output = summary
    category_override = category
    if detect.endswith('birthday') or detect.endswith('name day') or detect.endswith('anniversary'):
        category_override = '4'

    current_day = range_start
    while current_day <= range_end:
        date_str = current_day.strftime('%Y/%m/%d')
        if time_part and current_day == start_date_only:
            line = f"{date_str} {category_override} {time_part} {summary_output} {tag}"
        else:
            line = f"{date_str} {category_override} {summary_output} {tag}"
        output.append(line)
        current_day += timedelta(days=1)

if output:
    sys.stdout.write('\n'.join(output))
PY
}

caldav_sync_calendar() {
    local slug="$1" name="$2" url="$3" username="$4" password_encoded="$5" category="$6" start_date="$7" end_date="$8" sync_hours="$9"
    [[ -z $sync_hours ]] && sync_hours=24
    local tag="${caldav_tag_prefix}:${slug}"
    local password
    password=$(caldav_decode_secret "$password_encoded")
    if [[ -z $start_date ]]; then
        start_date="$TODAY"
    fi
    if [[ -z $end_date ]]; then
        end_date=$(date -d "${TODAY} +365 days" +%Y/%m/%d)
    fi
    local response_file
    response_file=$(caldav_fetch_response "$url" "$username" "$password" "$start_date" "$end_date") || {
        echo "CalDAV (${name}): Unable to fetch events."
        return 1
    }

    local events_file
    events_file=$(mktemp)
    if ! caldav_parse_events "$response_file" "$category" "$tag" "$start_date" "$end_date" > "$events_file"; then
        rm -f "$response_file" "$events_file"
        echo "CalDAV (${name}): Unable to parse calendar data."
        return 1
    fi

    rm -f "$response_file"

    caldav_remove_lines "$slug"

    if [[ -s "$events_file" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local leading trailing
            leading=$(echo "$line" | awk '{print substr($0, 1, 11)}')
            trailing=$(echo "$line" | awk '{print substr($0, 13)}')
            if ! grep "^${leading}[[:alnum:]]${trailing}$" "$INPUT_FILE" >/dev/null; then
                echo "$line" >> "$INPUT_FILE"
            fi
        done < "$events_file"
    fi

    rm -f "$events_file"

    local imported_date synced_at
    imported_date=${TODAY////-}
    synced_at=$(date +%s)
    caldav_update_entry "$slug" "$name" "$url" "$username" "$password_encoded" "$category" "$start_date" "$end_date" "$imported_date" "$sync_hours" "$synced_at"

    return 0
}

caldav_bind_calendar() {
    local calendar_url calendar_name username password category days_back days_forward start_date end_date slug

    echo "Provide details for the CalDAV calendar to import:"
    read -p "Calendar URL: " calendar_url
    calendar_url=$(echo "$calendar_url" | xargs)
    if [[ -z $calendar_url ]]; then
        echo "A calendar URL is required."
        echo
        return 1
    fi

    read -p "Display name [CalDAV calendar]: " calendar_name
    if [[ -z $calendar_name ]]; then
        calendar_name="CalDAV calendar"
    fi

    local auth_choice auth_choice_lower
    read -p "Does this calendar require authentication? [y/N] " auth_choice
    auth_choice_lower=$(to_lower "$auth_choice")
    if [[ $auth_choice_lower == "y" || $auth_choice_lower == "yes" ]]; then
        read -p "Username: " username
        read -s -p "Password or app password: " password
        echo
    fi

    category=$(caldav_select_category)

    days_back=$(caldav_prompt_range "Days in the past to include" "0")
    days_forward=$(caldav_prompt_range "Days in the future to include" "365")

    start_date=$(date -d "${TODAY} -${days_back} days" +%Y/%m/%d)
    end_date=$(date -d "${TODAY} +${days_forward} days" +%Y/%m/%d)

    local refresh_hours
    refresh_hours=$(caldav_prompt_range "Refresh interval in hours" "24")

    slug=$(caldav_slugify "$calendar_name")
    if [[ ${num_caldav:-0} -gt 0 ]]; then
        local base_slug="$slug"
        local counter=2
        local duplicate=1
        while [[ $duplicate -eq 1 ]]; do
            duplicate=0
            for (( i=0; i<${num_caldav}; i++ )); do
                if [[ ${defaults["caldav[$i][slug]"]} == "$slug" ]]; then
                    duplicate=1
                    slug="${base_slug}-${counter}"
                    ((counter++))
                    break
                fi
            done
        done
    fi
    local password_encoded
    password_encoded=$(caldav_encode_secret "$password")

    if caldav_sync_calendar "$slug" "$calendar_name" "$calendar_url" "$username" "$password_encoded" "$category" "$start_date" "$end_date" "$refresh_hours"; then
        parse_json
        assign_globals
        sort_input
        echo "CalDAV (${calendar_name}): Import completed."
        echo
        return 0
    else
        echo "CalDAV (${calendar_name}): Import failed."
        echo
        return 1
    fi
}

caldav_list_entries() {
    local index=0
    for (( index=0; index<${num_caldav}; index++ )); do
        local display_name=${defaults["caldav[$index][name]"]}
        [[ -z $display_name ]] && display_name="${defaults["caldav[$index][slug]"]}"
        echo -e " [${yellow}$((index+1))${reset}] ${display_name}"
    done
}

caldav_delete_calendars() {
    if [[ ${num_caldav:-0} -eq 0 ]]; then
        echo "No CalDAV calendars are currently bound."
        echo
        return
    fi

    echo "Please select a CalDAV calendar to delete:"
    caldav_list_entries
    [[ ${num_caldav} -gt 1 ]] && echo -e " [${yellow}A${reset}] All calendars"
    echo -e " [${yellow}X${reset}] Cancel"
    echo

    local choice choice_upper
    while true; do
        read -p "Enter a calendar code: " choice
        choice_upper=$(to_upper "$choice")
        if [[ $choice_upper == "X" ]]; then
            echo "Operation cancelled"
            echo
            return
        elif [[ $choice_upper == "A" && ${num_caldav} -gt 1 ]]; then
            for (( i=0; i<${num_caldav}; i++ )); do
                local slug=${defaults["caldav[$i][slug]"]}
                caldav_remove_lines "$slug"
            done
            jq '.caldav = []' "$SETTINGS" > tmp.$$.json && mv tmp.$$.json "$SETTINGS"
            parse_json
            assign_globals
            sort_input
            echo "All CalDAV calendars removed."
            echo
            return
        elif [[ $choice =~ ^[1-9][0-9]*$ && $choice -le ${num_caldav} ]]; then
            local idx=$((choice-1))
            local slug=${defaults["caldav[$idx][slug]"]}
            local name=${defaults["caldav[$idx][name]"]}
            caldav_remove_lines "$slug"
            caldav_delete_entry "$slug"
            parse_json
            assign_globals
            sort_input
            if [[ -n $name ]]; then
                echo "${name} removed."
            else
                echo "${slug} removed."
            fi
            echo
            return
        else
            echo "Invalid choice. Please enter a valid option."
            echo
        fi
    done
}

caldav_update_all() {
    if [[ ${num_caldav:-0} -eq 0 ]]; then
        echo "No CalDAV calendars are currently bound."
        echo
        return 1
    fi

    local i=0
    local updated=0
    for (( i=0; i<${num_caldav}; i++ )); do
        local slug=${defaults["caldav[$i][slug]"]}
        local name=${defaults["caldav[$i][name]"]}
        local url=${defaults["caldav[$i][url]"]}
        local username=${defaults["caldav[$i][username]"]}
        local password=${defaults["caldav[$i][password]"]}
        local category=${defaults["caldav[$i][category]"]}
        local start_date=${defaults["caldav[$i][start_date]"]}
        local end_date=${defaults["caldav[$i][end_date]"]}
        local sync_hours=${defaults["caldav[$i][sync_interval_hours]"]}

        if caldav_sync_calendar "$slug" "$name" "$url" "$username" "$password" "$category" "$start_date" "$end_date" "$sync_hours"; then
            updated=1
            echo "CalDAV (${name:-$slug}): Updated."
        else
            echo "CalDAV (${name:-$slug}): Update failed."
        fi
    done

    if [[ $updated -eq 1 ]]; then
        parse_json
        assign_globals
        sort_input
        echo "CalDAV: Operation completed."
    fi
    echo
}

caldav_auto_update() {
    if [[ ${num_caldav:-0} -eq 0 ]]; then
        return
    fi

    local now
    now=$(date +%s)
    local updated=0
    for (( i=0; i<${num_caldav}; i++ )); do
        local slug=${defaults["caldav[$i][slug]"]}
        local name=${defaults["caldav[$i][name]"]}
        local url=${defaults["caldav[$i][url]"]}
        local username=${defaults["caldav[$i][username]"]}
        local password=${defaults["caldav[$i][password]"]}
        local category=${defaults["caldav[$i][category]"]}
        local start_date=${defaults["caldav[$i][start_date]"]}
        local end_date=${defaults["caldav[$i][end_date]"]}
        local sync_hours=${defaults["caldav[$i][sync_interval_hours]"]}
        local synced_at=${defaults["caldav[$i][synced_at]"]}

        [[ -z $sync_hours || $sync_hours == "" ]] && sync_hours=24
        [[ -z $synced_at || $synced_at == "" ]] && synced_at=0

        local interval=$((sync_hours * 3600))
        if (( now - synced_at >= interval )); then
            if caldav_sync_calendar "$slug" "$name" "$url" "$username" "$password" "$category" "$start_date" "$end_date" "$sync_hours"; then
                updated=1
            fi
        fi
    done

    if [[ $updated -eq 1 ]]; then
        parse_json
        assign_globals
        sort_input
    fi
}

caldav_handle() {
    local action="$(to_upper "$1")"
    case "$action" in
        "IMPORT")
            caldav_bind_calendar
            ;;
        "UPDATE")
            caldav_update_all
            ;;
        "DELETE")
            caldav_delete_calendars
            ;;
        "" )
            caldav_auto_update
            ;;
        *)
            caldav_auto_update
            ;;
    esac
}
