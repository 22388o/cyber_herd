#!/bin/bash

# Configuration variables
hex_key="669ebbcccf409ee0467a33660ae88fd17e5379e646e41d7c236ff4963f3c36b6"  # pubkey in hex of original author
tags=("CyberHerd" "LightningGoats")  # Tags to match ex: tags=("cyberherd" "lightning-goats")
limit=10  # Number of npubs to track, cyberherd size
relay_urls=("wss://lnb.bolverker.com/nostrclient/api/v1/relay" "wss://relay.damus.io" "wss://relay.primal.net")  # Relays to use
webhook_url="http://127.0.0.1:8090/cyber_herd"

relay_urls_string="${relay_urls[@]}"
tag_string=$(printf " -t t=%s" "${tags[@]}")
midnight=$(date -d "$(date '+%Y-%m-%d 00:00:00')" '+%s')

# Fetch existing cyberherd public keys and the most recent event_id from the API
view_cyber_herd_response=$(curl -s "http://127.0.0.1:8090/view_cyber_herd")
existing_pubkeys=($(echo "$view_cyber_herd_response" | jq -r '.[].pubkey'))
event_id=$(echo "$view_cyber_herd_response" | jq -r '.[0].event_id') #event_id is the same in all records, use the first one.

# Remove repeating substrings
remove_repeats() {
    local segment=$1
    local prev=""
    while [ "$segment" != "$prev" ]; do
        prev=$segment
        segment=$(echo $segment | /usr/bin/sed -r 's/(.*)\1+/\1/')
    done
    echo -n $segment
}

# Process the input string remove repeating values
process_string() {
    local input_string=$1

    # Remove newlines
    input_string=$(echo "$input_string" | /usr/bin/tr -d '\n')

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

# Check if event_id is empty or null and fetch if necessary
if [ -z "$event_id" ] || [ "$event_id" == "null" ]; then
    initial_output=$(/usr/local/bin/nak -s req -k 1 $tag_string -a $hex_key --since $midnight $relay_urls_string | /usr/bin/jq -s 'sort_by(.created_at) | last | .id')
    
    if [ -z "$initial_output" ] || [ "$initial_output" == "null" ]; then
        echo "Error: Initial command returned null or empty output."
        exit 1
    fi

    # Remove quotes from the initial output
    event_id=$(echo $initial_output | tr -d '"')
fi

# Get id of most recent tagged post
initial_output=$(/usr/local/bin/nak -s req -k 1 $tag_string -a $hex_key --since $midnight $relay_urls_string | /usr/bin/jq -s 'sort_by(.created_at) | last | .id')

if [ -z "$initial_output" ] || [ "$initial_output" == "null" ]; then
  echo "Error: Initial command returned null or empty output."
  exit 1
fi

# Remove quotes from the initial output
event_id=$(echo $initial_output | tr -d '"')

# get pubkeys which have resposted the tagged note
pubkeys=$(/usr/local/bin/nak -s req -k 6 -e $event_id -l $limit --since $midnight $relay_urls_string | /usr/bin/jq -s 'sort_by(.created_at)'| /usr/bin/jq '[.[] | .pubkey]') #get event id for repost as well pass that along

if [ -z "$pubkeys" ] || [ "$pubkeys" == "null" ]; then
  echo "Error: Second command returned null or empty output."
  exit 1
fi

# Convert the JSON array to a Bash array
readarray -t keys <<< "$(echo $pubkeys | /usr/bin/jq -r '.[]')"

# Initialize an empty array for JSON objects
json_objects=()

# Loop through each public key, get associated name and lightning address
for pubkey in "${keys[@]}"
do
    if [[ " ${existing_pubkeys[*]} " =~ " $pubkey " ]]; then
        continue
    fi
    
    #get metadata for pubkey
    output=$(/usr/local/bin/nak -s req -k 0 -a "$pubkey" -l 1 $relay_urls_string | /usr/bin/jq)
    
    if [ -z "$output" ] || [ "$output" == "null" ]; then
      echo "Error: Third command returned null or empty output for pubkey $pubkey."
      exit 1
    fi
    
    # Extract nip05 and LUD-16 values
    nip05=$(echo "$output" | /usr/bin/jq -r '.content | fromjson | .nip05')
    lud16=$(echo "$output" | /usr/bin/jq -r '.content | fromjson | .lud16')

    if [[ "$lud16" != "" ]] && [[ "$nip05" != "" ]]; then
        processed_string=$(process_string "$pubkey,$lud16")
        
        # Split processed string into pubkey and lud16
        IFS=',' read -r processed_pubkey processed_lud16 <<< "$processed_string"
	
	# encode pubkey to npub
	npub=$(/usr/local/bin/nak encode npub $processed_pubkey)
	nprofile=$(/usr/local/bin/nak encode nprofile $processed_pubkey)
	
        # Construct JSON object and add it to the array
        json_object="{\"event_id\":\"$event_id\",\"author_pubkey\":\"$hex_key\",\"pubkey\":\"$processed_pubkey\",\"npub\":\"$npub\",\"nprofile\":\"$nprofile\",\"lud16\":\"$processed_lud16\"}" 
        json_objects+=("$json_object")
    fi
done

# Combine array elements into a JSON array and send the payload
json_payload=$(printf "[%s]" "$(IFS=,; echo "${json_objects[*]}")")
if [ "$json_payload" != "[]" ]; then
    /usr/bin/curl -X POST -H "Content-Type: application/json" -d "$json_payload" "$webhook_url"
fi
