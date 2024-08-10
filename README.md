CyberHerd

Description

This Python script is designed to interact with Nostr relays to fetch and process specific data based on predefined tags and a public key. It focuses on aggregating LUD-16 values from different sources in a decentralized network and sending updated information to a specified webhook URL.

Features

Filtering by Tags: Filters events based on the specified tags (CyberHerd).
Relay Integration: Queries multiple Nostr relays to collect data.
Data Processing: Extracts name and LUD-16 values from the fetched events.
Webhook Notification: Sends updated name and LUD-16 pairs to a webhook URL in JSON format.
Lightning Network Integration: Decodes BOLT11 invoices and processes related events.

Configuration

Before running the script, the following variables need to be set:

HEX_KEY: The public key in hexadecimal format of the original author.
TAGS: An array of tags to match when filtering events.
relays: A list of Nostr relay URLs to query.
WEBHOOK_URL: The URL of the webhook where the script sends the updated data.
API_KEY: The API key used for additional integrations or requests.
onfig: A dictionary containing additional configuration options, such as ENDPOINT_URL.

Workflow

Initial Data Fetch: Queries the Nostr relays for the latest event ID matching the specified tags and public key.
Event Data Retrieval: Fetches repost (kind 6) and zap (kind 9735) events using this ID and extracts relevant information from these events.
Data Processing: For each unique public key, retrieves related metadata, extracts the name and LUD-16 values, and sends them to the specified webhook URL if they are new. In the context of the Lightning Goats project, these values are later used to reward users who have joined the Lightning Goats Cyber Herd by reposting the daily "Zap notes. Feed Goats." post with a #CyberHerd tag. This happens each time the feeder is triggered, giving "treats" (sats) to the cyber herd and dispensing actual goat treats to the Lightning Goats herd in real life.

Dependencies

python3: Ensure Python 3.7 or higher is installed.
httpx: A modern, fast HTTP client for Python. Install via pip install httpx.
logging: Python's built-in logging module.
nak: A command-line utility specific to Nostr network interactions, available at https://github.com/fiatjaf/nak/tree/master.

Usage

Clone or download the script to your local environment.
Set the configuration variables in the script as per your requirements.
Ensure the required dependencies are installed: pip install httpx.
Run the script: python3 /path/to/script.py.
Optionally, schedule the script to run periodically using cron or as a systemd service.

Note

Ensure your webhook endpoint is configured to accept and process the incoming JSON data correctly.
This script is designed to run in environments where Nostr relays and the specified webhook are accessible.
Regularly check and update the script and its dependencies to ensure compatibility with the latest versions of Nostr protocols and related tools.

