#!/bin/bash

# Configuration variables
hex_key="669ebbcccf409ee0467a33660ae88fd17e5379e646e41d7c236ff4963f3c36b6"  # pubkey in hex of original author
tags=("cyber-herd" "lightning-goats")  # Tags to match
limit=10  # Number of npubs to track
relay_urls=("wss://lnb.bolverker.com/nostrclient/api/v1/relay" "wss://relay.damus.io" "wss://relay.primal.net")  # Relays to use
webhook_url="https://127.0.0.1:8090/cyber_herd"

# Convert relay URLs array to a space-separated string
relay_urls_string="${relay_urls[@]}"

# Convert tags array to a string with '-t t=' prefix for each tag
tag_string=$(printf " -t t=%s" "${tags[@]}")

# Temporary file to store LUD-16 values
temp_file="/tmp/lud16_values.txt"

# Read the existing file to get an array of known public keys
existing_pubkeys=()
if [ -f "$temp_file" ]; then
    while IFS=, read -r pubkey lud16; do
        existing_pubkeys+=("$pubkey")
    done < "$temp_file"
fi

# Initial command
initial_output=$(nak -s req -k 1 $tag_string -a $hex_key $relay_urls_string | jq -s 'sort_by(.created_at) | last | .id')

# Check if initial_output is null or empty
if [ -z "$initial_output" ] || [ "$initial_output" == "null" ]; then
  echo "Error: Initial command returned null or empty output."
  exit 1
fi

# Remove quotes from the initial output
event_id=$(echo $initial_output | tr -d '"')

# Second command
pubkeys=$(nak -s req -k 6 -e $event_id -l $limit $relay_urls_string | jq -s 'sort_by(.created_at)' | jq '[.[] | .pubkey]')

# Check if pubkeys is null or empty
if [ -z "$pubkeys" ] || [ "$pubkeys" == "null" ]; then
  echo "Error: Second command returned null or empty output."
  exit 1
fi

# Convert the JSON array to a Bash array
readarray -t keys <<< "$(echo $pubkeys | jq -r '.[]')"

# Initialize an empty JSON payload
json_payload="{" 

# Loop through each public key and run the third command
for pubkey in "${keys[@]}"
do
    if [[ " ${existing_pubkeys[*]} " =~ " $pubkey " ]]; then
        continue
    fi

    output=$(nak -s req -k 0 -a "$pubkey" -l 1 $relay_urls_string | jq)
    
    if [ -z "$output" ] || [ "$output" == "null" ]; then
      echo "Error: Third command returned null or empty output for pubkey $pubkey."
      continue
    fi
    
    # Extract nip05, name, and LUD-16 value
    nip05=$(echo "$output" | jq -r '.content | fromjson | .nip05')
    name=$(echo "$output" | jq -r '.content | fromjson | .name')
    lud16=$(echo "$output" | jq -r '.content | fromjson | .lud16' | tr -d '\n')

    # Append to the temporary file and update JSON payload if lud16 is set and nip05 is set
    if [[ "$lud16" != "" ]] && [[ "$nip05" != "" ]]; then
        echo "$pubkey,$name,$lud16" >> "$temp_file"
        # Add to JSON payload
        json_payload+="\"$name\":\"$lud16\","
    fi
done

# Finalize the JSON payload
json_payload="${json_payload%,}}"
json_payload+="}"

# Send the JSON payload to the webhook URL if it is not empty
if [ "$json_payload" != "{}" ]; then
    curl -X POST -H "Content-Type: application/json" -d "$json_payload" "$webhook_url"
fi
