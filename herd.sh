#!/bin/bash
echo "Warning: This script is deprecated and will no longer be maintained. Please use herd.py instead."


# Configuration variables
hex_key="669ebbcccf409ee0467a33660ae88fd17e5379e646e41d7c236ff4963f3c36b6"
tags=("CyberHerd")
limit=10
relay_urls=("ws://127.0.0.1:3002/nostrclient/api/v1/relay")
webhook_url="http://127.0.0.1:8090/cyber_herd"

relay_urls_string="${relay_urls[@]}"
tag_string=""

# Construct tag_string
for tag in "${tags[@]}"; do
    tag_string+="-t t=$tag "
done

midnight=$(date -d "$(date '+%Y-%m-%d 00:00:00')" '+%s')

# Function to check if input is valid JSON
is_json_valid() {
    echo "$1" | jq empty >/dev/null 2>&1
    return $?
}

# Fetch existing cyberherd public keys and most recent event_id
view_cyber_herd_response=$(curl -s "http://127.0.0.1:8090/get_cyber_herd")
if ! is_json_valid "$view_cyber_herd_response"; then
    echo "Error: Invalid JSON received from cyber herd service."
    exit 1
fi

existing_pubkeys=($(echo "$view_cyber_herd_response" | jq -r '.[].pubkey'))
event_id=$(echo "$view_cyber_herd_response" | jq -r '.[0].event_id')

# Remove repeating substrings
remove_repeats() {
    echo "$1" | sed -r 's/(.*)\1+/\1/'
}

process_string() {
    local input_string="$1"
    input_string=$(echo "$input_string" | tr -d '\n' | tr -d '\r' | tr -d '\t')  # Remove newlines, carriage returns, and tabs
    local output=""
    IFS=',' read -ra segments <<< "$input_string"
    for segment in "${segments[@]}"; do
        local result=$(remove_repeats "$segment")
        output="${output:+$output,}$result"
    done
    echo "$output"
}

# Fetch initial event_id if necessary
if [ -z "$event_id" ] || [ "$event_id" == "null" ]; then
    raw_event_id=$(/usr/local/bin/nak req -k 1 $tag_string -a $hex_key --since $midnight $relay_urls_string)
    if ! is_json_valid "$raw_event_id"; then
        echo "Error: Invalid JSON received for initial event_id."
        exit 1
    fi
    event_id=$(echo "$raw_event_id" | jq -r -s 'sort_by(.created_at) | last | .id')
    
    [ -z "$event_id" ] && { echo "Error: Unable to fetch initial event_id."; exit 1; }
fi

# Fetch pubkeys which have reposted or liked the tagged note
raw_pubkeys=$(/usr/local/bin/nak req -k 6 -e $event_id -l $limit --since $midnight $relay_urls_string)

if ! is_json_valid "$raw_pubkeys"; then
    echo "Error: Invalid JSON received for public keys."
    exit 1
fi

# Store pubkeys and their associated kind in an associative array
declare -A pubkey_kinds

# Read JSON lines into an array
readarray -t json_lines <<< "$raw_pubkeys"

# Process each line as a separate JSON object
for line in "${json_lines[@]}"; do
    # Check if the line is valid JSON
    if ! is_json_valid "$line"; then
        echo "Invalid JSON line: $line"
        continue
    fi

    pubkey=$(echo "$line" | jq -r '.pubkey')
    kind=$(echo "$line" | jq -r '.kind')

    if [ -n "$pubkey" ]; then
        pubkey_kinds["$pubkey"]=$kind
    else
        echo "Warning: Invalid public key found in JSON line."
    fi
done

# Loop through each public key to get metadata #TODO  maybe rewrite using authors, no loop.
declare -a json_objects

for pubkey in "${!pubkey_kinds[@]}"; do
    kind=${pubkey_kinds[$pubkey]}

    # Skip if pubkey is in existing_pubkeys or if pubkey is the same as hex_key
    if [[ " ${existing_pubkeys[*]} " =~ " $pubkey " ]] || [[ $pubkey == $hex_key ]]; then
        continue
    fi
    
    # Fetch metadata for each pubkey and ensure only the most recent record is used
    raw_output=$(/usr/local/bin/nak req -k 0 -a "$pubkey" $relay_urls_string)
    
    # Sort the results by 'created_at' in descending order and get the most recent record
    most_recent_record=$(echo "$raw_output" | jq -s 'sort_by(.created_at) | reverse | .[0]')

    if ! is_json_valid "$most_recent_record"; then
        echo "Error: Invalid JSON received for pubkey $pubkey."
        continue
    fi

    # Extract metadata fields from most_recent_record
   nip05=$(process_string "$(echo "$most_recent_record" | jq -r '.content | fromjson | .nip05')")
   lud16=$(process_string "$(echo "$most_recent_record" | jq -r '.content | fromjson | .lud16')")
   display_name=$(process_string "$(echo "$most_recent_record" | jq -r '.content | fromjson | .display_name')")

    # Check and construct JSON object
    if [[ -n "$lud16" && "$lud16" != "null" ]] && [[ -n "$nip05" ]]; then
        processed_string=$(process_string "$pubkey,$lud16")
        IFS=',' read -r processed_pubkey processed_lud16 <<< "$processed_string"
        npub=$(/usr/local/bin/nak encode npub $processed_pubkey)
        nprofile=$(/usr/local/bin/nak encode nprofile $processed_pubkey)

        # Append a new JSON object to the array
        json_object="{\"display_name\":\"$display_name\",\"event_id\":\"$event_id\",\"kind\":\"$kind\",\"pubkey\":\"$processed_pubkey\",\"nprofile\":\"$nprofile\",\"lud16\":\"$processed_lud16\",\"notified\":\"False\",\"payouts\":\"0\"}"
        json_objects+=("$json_object")
    fi
done
if [ ${#json_objects[@]} -ne 0 ]; then
	json_payload=$(printf "[%s]" "$(IFS=,; echo "${json_objects[*]}")")
        if is_json_valid "$json_payload"; then
            curl -X POST -H "Content-Type: application/json" -d "$json_payload" "$webhook_url"
            json_objects=()  # Reset json_objects after successful sending
        else
            echo "Error: Invalid JSON payload."
            echo "$json_payload"
        fi
fi
