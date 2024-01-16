#!/bin/bash

# Configuration variables
hex_key="669ebbcccf409ee0467a33660ae88fd17e5379e646e41d7c236ff4963f3c36b6"
tags=("CyberHerd" "LightningGoats")
limit=10
relay_urls=("wss://lnb.bolverker.com/nostrclient/api/v1/relay" "wss://relay.damus.io" "wss://relay.primal.net")
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

# Process string to remove repeating values
process_string() {
    local input_string="$1"
    input_string=$(echo "$input_string" | tr -d '\n')
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
    raw_event_id=$(/usr/local/bin/nak -s req -k 1 $tag_string -a $hex_key --since $midnight $relay_urls_string)
    if ! is_json_valid "$raw_event_id"; then
        echo "Error: Invalid JSON received for initial event_id."
        exit 1
    fi
    event_id=$(echo "$raw_event_id" | jq -r -s 'sort_by(.created_at) | last | .id')
    #TODO send event id to fast_api_ap
    
    [ -z "$event_id" ] && { echo "Error: Unable to fetch initial event_id."; exit 1; }
fi

# Fetch pubkeys which have reposted the tagged note
raw_pubkeys=$(/usr/local/bin/nak -s req -k 6 -e $event_id -l $limit --since $midnight $relay_urls_string)
if ! is_json_valid "$raw_pubkeys"; then
    echo "Error: Invalid JSON received for public keys."
    exit 1
fi
pubkeys=$(echo "$raw_pubkeys" | jq -r -s 'sort_by(.created_at) | .[] | .pubkey')
[ -z "$pubkeys" ] && { echo "Error: Unable to fetch public keys."; exit 1; }

# Loop through each public key to get metadata
json_objects=()
for pubkey in $pubkeys; do
    [[ " ${existing_pubkeys[*]} " =~ " $pubkey " ]] && continue
    raw_output=$(/usr/local/bin/nak -s req -k 0 -a "$pubkey" -l 1 $relay_urls_string)
    if ! is_json_valid "$raw_output"; then
        echo "Error: Invalid JSON received for pubkey $pubkey."
        continue
    fi

    output=$(echo "$raw_output" | jq)
    nip05=$(echo "$output" | jq -r '.content | fromjson | .nip05')
    lud16=$(echo "$output" | jq -r '.content | fromjson | .lud16')
    display_name=$(echo "$output" | jq -r '.content | fromjson | .display_name')
    
    if [[ -n "$lud16" ]] && [[ -n "$nip05" ]]; then
        processed_string=$(process_string "$pubkey,$lud16")
        IFS=',' read -r processed_pubkey processed_lud16 <<< "$processed_string"
        npub=$(/usr/local/bin/nak encode npub $processed_pubkey)
        nprofile=$(/usr/local/bin/nak encode nprofile $processed_pubkey)
        json_objects+=("{\"display_name\":\"$display_name\",\"event_id\":\"$event_id\",\"author_pubkey\":\"$hex_key\",\"pubkey\":\"$processed_pubkey\",\"npub\":\"$npub\",\"nprofile\":\"$nprofile\",\"lud16\":\"$processed_lud16\",\"notified\":\"False\",\"payouts\":\"0\"}")
    fi
done

# Send JSON payload if not empty
if [ ${#json_objects[@]} -ne 0 ]; then
    json_payload=$(printf "[%s]" "$(IFS=,; echo "${json_objects[*]}")")
    curl -X POST -H "Content-Type: application/json" -d "$json_payload" "$webhook_url"
fi

