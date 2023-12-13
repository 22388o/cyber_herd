#!/bin/bash

# Configuration variables
hex_key="669ebbcccf409ee0467a33660ae88fd17e5379e646e41d7c236ff4963f3c36b6"  # pubkey in hex of original author
tags=("cyber-herd")  # Tags to match ex: tags=("cyberherd" "lightning-goats")
limit=10  # Number of npubs to track, cyberherd size
relay_urls=("wss://lnb.bolverker.com/nostrclient/api/v1/relay" "wss://relay.damus.io" "wss://relay.primal.net")  # Relays to use
webhook_url="http://127.0.0.1:8090/cyber_herd"

relay_urls_string="${relay_urls[@]}"
tag_string=$(printf " -t t=%s" "${tags[@]}")
temp_file="/tmp/lud16_values.txt"

# Remove repeating substrings
remove_repeats() {
    local segment=$1
    local prev=""
    while [ "$segment" != "$prev" ]; do
        prev=$segment
        segment=$(echo $segment | sed -r 's/(.*)\1+/\1/')
    done
    echo -n $segment
}

# Process the input string remove repeating values
process_string() {
    local input_string=$1

    # Remove newlines
    input_string=$(echo "$input_string" | tr -d '\n')

    # Split the input by comma and process each segment
    local output=""
    IFS=',' read -ra ADDR <<< "$input_string"
    for i in "${ADDR[@]}"; do
        # Remove repeating substrings in each segment
        local result=$(remove_repeats "$i")
        # Append result to output
        if [ -z "$output" ]; then
            output=$result
        else
            output="$output,$result"
        fi
    done

    # Return the final output
    echo "$output"
}

# Read the existing file to get an array of cyberherd public keys
existing_pubkeys=()
if [ -f "$temp_file" ]; then
    while IFS=, read -r pubkey lud16; do
        existing_pubkeys+=("$pubkey")
    done < "$temp_file"
fi

# Get id of most recent tagged post
initial_output=$(nak -s req -k 1 $tag_string -a $hex_key $relay_urls_string | jq -s 'sort_by(.created_at) | last | .id')

if [ -z "$initial_output" ] || [ "$initial_output" == "null" ]; then
  echo "Error: Initial command returned null or empty output."
  exit 1
fi

# Remove quotes from the initial output
event_id=$(echo $initial_output | tr -d '"')

# get pubkeys which have resposted the tagged note
pubkeys=$(nak -s req -k 6 -e $event_id -l $limit $relay_urls_string | jq -s 'sort_by(.created_at)' | jq '[.[] | .pubkey]')

if [ -z "$pubkeys" ] || [ "$pubkeys" == "null" ]; then
  echo "Error: Second command returned null or empty output."
  exit 1
fi

# Convert the JSON array to a Bash array
readarray -t keys <<< "$(echo $pubkeys | jq -r '.[]')"

# Initialize an empty array for JSON objects
json_objects=()

# Loop through each public key, get associated name and lightning address
for pubkey in "${keys[@]}"
do
    if [[ " ${existing_pubkeys[*]} " =~ " $pubkey " ]]; then
        continue
    fi
    
    #get metadata for pubkey
    output=$(nak -s req -k 0 -a "$pubkey" -l 1 $relay_urls_string | jq)
    
    if [ -z "$output" ] || [ "$output" == "null" ]; then
      echo "Error: Third command returned null or empty output for pubkey $pubkey."
      continue
    fi
    
    # Extract nip05, name, and LUD-16 value
    nip05=$(echo "$output" | jq -r '.content | fromjson | .nip05')
    name=$(echo "$output" | jq -r '.content | fromjson | .name')
    lud16=$(echo "$output" | jq -r '.content | fromjson | .lud16' | tr -d '\n')

    if [[ "$lud16" != "" ]] && [[ "$nip05" != "" ]]; then
        processed_string=$(process_string "$pubkey,$name,$lud16")
        
        # Split processed string into pubkey, name, and lud16
        IFS=',' read -r processed_pubkey processed_name processed_lud16 <<< "$processed_string"

        echo "$processed_pubkey,$processed_name,$processed_lud16" >> "$temp_file"

        # Construct JSON object and add it to the array
        json_object="{\"name\":\"$processed_name\",\"lud16\":\"$processed_lud16\"}"
        json_objects+=("$json_object")
    fi
done

# Combine array elements into a JSON array
json_payload=$(printf "[%s]" "$(IFS=,; echo "${json_objects[*]}")")

# Send the JSON payload
if [ "$json_payload" != "[]" ]; then
    curl -X POST -H "Content-Type: application/json" -d "$json_payload" "$webhook_url"
fi
