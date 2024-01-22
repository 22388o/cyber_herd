-
# Cyber Herd Bash Script

## Description

This Bash script is designed to interact with Nostr relays to fetch and process specific data based on predefined tags and a public key. It focuses on aggregating LUD-16 values from different sources in a decentralized network and sends updated information to a specified webhook URL.

## Features

- **Filtering by Tags**: Filters events based on the specified tags (`cyber-herd`, `lightning-goats`).
- **Relay Integration**: Queries multiple Nostr relays to collect data.
- **Data Processing**: Extracts `name` and `LUD-16` values from the fetched events.
- **Webhook Notification**: Sends updated `name` and `LUD-16` pairs to a webhook URL in JSON format.

## Configuration

Before running the script, the following variables need to be set:

- `hex_key`: The public key in hexadecimal format of the original author.
- `tags`: An array of tags to match when filtering events.
- `limit`: The number of public keys (npubs) to track.
- `relay_urls`: An array of Nostr relay URLs to query.
- `webhook_url`: The URL of the webhook where the script sends the updated data.

## Workflow

1. **Initial Data Fetch**: Queries the Nostr relays for the latest event ID matching the specified tags and public key.
2. **Event Data Retrieval**: Fetches repost (kind 6) events using this ID and extracts public keys from these events.
3. **Data Processing**: For each unique public key, retrieves related data, extracts the `name` and `LUD-16` values, and sends them to the specified webhook URL if they are new.  In the context of the Lightning Goats project these values are later used to reward up to 10 users who have joined the Lightning Goats Cyber Herd by reposting the daily "Zap notes. Feed Goats." post with a #CyberHerd tag.  This happens each time the feeder is triggered giving "treats" (sats) to the cyber herd along with dispensing actual goat treats to the Lightning Goats goat herd irl.


## Dependencies

- `jq`: A command-line JSON processor.
- `curl`: A tool to transfer data from or to a server.
- `nak`: A command-line utility specific to Nostr network interactions https://github.com/fiatjaf/nak/tree/master.
- Ensure these tools are installed and accessible from your command line.

## Usage

1. Set the configuration variables in the script as per your requirement.
2. chmod +x /home/user/bin/herd.sh
3. Run the script via cron: */3 * * * * /home/user/bin/herd.sh, or use unit files for controlling execution.
4. The script will process data and send updates to the configured webhook URL.

## Note

- Ensure your webhook endpoint is configured to accept and process the incoming JSON data correctly.
- This script is designed to run in environments where Nostr relays and the specified webhook are accessible.
