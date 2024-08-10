#!/usr/bin/env python3

import subprocess
import logging
import json
import asyncio
import httpx
from datetime import datetime, timedelta
from typing import Optional, Dict, Any

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# Configuration variables
relays = ["ws://127.0.0.1:3002/nostrclient/api/v1/relay"]
WEBHOOK_URL = "http://127.0.0.1:8090/cyber_herd"
HEX_KEY = "669ebbcccf409ee0467a33660ae88fd17e5379e646e41d7c236ff4963f3c36b6"
TAGS = ["CyberHerd"]
API_KEY = "036ad4bb0dcb4b8c952230ab7b47ea52"
config = {
    'ENDPOINT_URL': "http://127.0.0.1:8090/messages/cyberherd_treats"
}

http_client = httpx.AsyncClient(http2=True, limits=httpx.Limits(max_keepalive_connections=10, max_connections=20))

class Utils:
    @staticmethod
    def calculate_midnight() -> int:
        """Calculate the timestamp for the current day's midnight."""
        now = datetime.now()
        midnight = datetime.combine(now.date(), datetime.min.time())
        return int(midnight.timestamp())

    @staticmethod
    async def decode_bolt11(bolt11: str) -> Optional[Dict[str, Any]]:
        """Decode bolt11 field using lnbits API."""
        url = 'https://lnb.bolverker.com/api/v1/payments/decode'
        async with httpx.AsyncClient() as client:
            try:
                response = await client.post(url, headers={"Content-Type": "application/json"}, json={"data": bolt11})
                response.raise_for_status()
                data = response.json()
                logger.info(f"Bolt11 decode: {data}")
                return data
            except httpx.RequestError as e:
                logger.error(f"Failed to decode bolt11: {e}")
                return None

class Verifier:
    @staticmethod
    async def validate_lud16(lud16: str) -> bool:
        """Validate a LUD-16 Lightning Address."""
        user, domain = lud16.split('@')
        url = f'https://{domain}/.well-known/lnurlp/{user}'

        try:
            response = await http_client.get(url)
            response.raise_for_status()
            data = response.json()
            logger.info(f"LUD-16 validation response: {data}")

            if data.get('status') == 'ERROR':
                logger.error(f"LUD-16 validation error status: {data}")
                return False
            if 'callback' in data and 'maxSendable' in data and 'minSendable' in data:
                return True

            logger.warning(f"LUD-16 validation missing parameters: {data}")
        except (httpx.RequestError, httpx.HTTPStatusError, ValueError) as e:
            logger.error(f"Failed to validate LUD-16: {e}")
        return False

    @staticmethod
    def verify_nip05(nip05: str) -> bool:
        """Verify a nip05 using nak decode."""
        decode_command = ['/usr/local/bin/nak', 'decode', nip05]
        try:
            decode_result = subprocess.run(decode_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
            decoded_data = json.loads(decode_result.stdout)
            return True if decoded_data.get('pubkey') else False
        except subprocess.CalledProcessError as e:
            logger.error(f"Error decoding nip05: {e}")
        except json.JSONDecodeError as e:
            logger.error(f"Error parsing decoded nip05: {e}")
        return False

class EventProcessor:
    def __init__(self):
        self.seen_ids = set()
        self.json_objects = []
        self.processed_pubkeys = set()  # Set to track processed pubkeys

    async def send_json_payload(self, json_objects: list, webhook_url: str) -> bool:
        """Send JSON payload to the specified webhook URL."""
        if json_objects:
            json_payload = json.dumps(json_objects)
            try:
                response = await http_client.post(webhook_url, headers={"Content-Type": "application/json"}, data=json_payload, timeout=10)
                response.raise_for_status()
                logger.info(f"Data sent successfully. Response: {response.text}")
                return True
            except httpx.RequestError as e:
                logger.error(f"Error: Failed to send JSON payload. {e}. Response: {e.response.text if e.response else 'No response'}")
        else:
            logger.warning("No JSON objects to send.")
        return False

    def lookup_metadata(self, pubkey: str) -> Optional[Dict[str, Optional[str]]]:
        """Lookup metadata for the given pubkey."""
        metadata_command = ['/usr/local/bin/nak', 'req', '-k', '0', '-a', pubkey] + relays
        try:
            metadata_result = subprocess.run(metadata_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)

            last_meta_data = None

            for meta_line in metadata_result.stdout.splitlines():
                meta_data = json.loads(meta_line)
                content = json.loads(meta_data.get('content', '{}'))
                if content.get('lud16'):
                    if (last_meta_data is None) or (meta_data['created_at'] > last_meta_data['created_at']):
                        last_meta_data = meta_data

            if last_meta_data:
                content = json.loads(last_meta_data.get('content', '{}'))
                return {
                    'nip05': content.get('nip05', None),
                    'lud16': content.get('lud16', None),
                    'display_name': content.get('display_name', content.get('name', 'Anon'))
                }

        except (subprocess.CalledProcessError, json.JSONDecodeError) as e:
            logger.error(f"Failed to get or parse metadata: {e}")

        return None

    async def handle_event(self, data: Dict[str, Any]) -> None:
        pubkey = data.get('pubkey', '')
        kind = data.get('kind', '')
        amount = data.get('amount', 0)  # Default to 0 if amount is None
        
        logger.info(f"Handling event: pubkey={pubkey}, kind={kind}, amount={amount}")

        # Skip event if pubkey is already processed
        if pubkey in self.processed_pubkeys:
            logger.info(f"Skipping event for already processed pubkey: {pubkey}")
            return

        if pubkey != HEX_KEY:
            metadata = self.lookup_metadata(pubkey)
            if metadata:
                nip05 = metadata['nip05']
                lud16 = metadata['lud16']
                display_name = metadata['display_name']

                if lud16:
                    nprofile_command = ['/usr/local/bin/nak', 'encode', 'nprofile', pubkey]
                    try:
                        nprofile_result = subprocess.run(nprofile_command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True)
                        nprofile = nprofile_result.stdout.strip()
                        logger.info(f"Metadata lookup success: {metadata}")

                        event_id = None
                        for tag in data.get('tags', []):
                            if tag[0] == 'e':
                                event_id = tag[1]
                                break

                        payouts = min(amount / 100, 1.0)
                        
                        if kind == 9734:  # received from inside the 9735 note description data.
                            kind = 9735
                        elif kind == 6:
                            payouts = 0.1  # Set a default or specific value for kind 6 if no amount is given

                        json_object = {
                            "display_name": display_name,
                            "event_id": event_id,
                            "kinds": [kind],
                            "pubkey": pubkey,
                            "nprofile": nprofile,
                            "lud16": lud16,
                            "nip05": nip05,
                            "notified": 'False',
                            "payouts": payouts
                        }

                        self.json_objects.append(json_object)
                        logger.info(f"Appending json object: {json_object}")
                        await self.send_json_payload(self.json_objects, WEBHOOK_URL)
                        
                        # Mark pubkey as processed
                        self.processed_pubkeys.add(pubkey)

                    except subprocess.CalledProcessError as e:
                        logger.error(f"Failed to encode nprofile: {e}")
                else:
                    logger.warning(f"Invalid nip05 or lud16 for pubkey. Skipping event.")
        else:
            logger.warning(f"Pubkey matches HEX_KEY, skipping event.")

class Monitor:
    def __init__(self, event_processor: EventProcessor):
        self.event_processor = event_processor
        self.subprocesses = []

    async def execute_subprocess(self, id_output: str, created_at_output: str) -> None:
        """Execute a subprocess to process events asynchronously."""
        command = f"/usr/local/bin/nak req --stream -k 6 -k 9735 -e {id_output} " + ' '.join(relays)
        proc = await asyncio.create_subprocess_shell(command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        logger.info(f"Subprocess started with PID: {proc.pid}")

        async for line in proc.stdout:
            try:
                data = json.loads(line)
                pubkey = data.get('pubkey')
                note = data.get('id')
                
                if pubkey:
                    event_id = None
                    for tag in data.get('tags', []):
                        if tag[0] == 'e':
                            event_id = tag[1]
                            break

                    if data.get('kind') == 6:
                        logger.info(f"Repost, ID: {note}")
                        await self.event_processor.handle_event(data)
                    elif data.get('kind') == 9735:
                        logger.info(f"Zap, ID: {note}")
                        bolt11 = None
                        description_data = None
                        for tag in data.get('tags', []):
                            if tag[0] == 'bolt11':
                                bolt11 = tag[1]
                            elif tag[0] == 'description':
                                description_data = json.loads(tag[1])

                        if bolt11:
                            decoded_data = await Utils.decode_bolt11(bolt11)
                            
                            if decoded_data and 'amount_msat' in decoded_data:
                                description_data['amount'] = decoded_data['amount_msat'] / 1000  # Convert msat to sat
                            
                            if description_data['amount'] >= 10:
                                await self.event_processor.handle_event(description_data)
                            else:
                                logger.info(f"Amount too small: {description_data['amount']} sats")

            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse JSON: {line}, error: {e}")

        await proc.wait()
        logger.info(f"Subprocess {proc.pid} terminated.")

    async def monitor_new_notes(self) -> None:
        """Monitor events and process them asynchronously."""
        midnight_today = Utils.calculate_midnight()  # Calculate timestamp for midnight today

        while True:
            try:
                tag_string = " ".join(f"-t t={tag}" for tag in TAGS)
                command = f"/usr/local/bin/nak req --stream -k 1 {tag_string} -a {HEX_KEY} --since {midnight_today} " + ' '.join(relays)
                proc = await asyncio.create_subprocess_shell(command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                self.subprocesses.append(proc)
                logger.info(f"Subprocess started with PID: {proc.pid}")

                async for line in proc.stdout:
                    try:
                        data = json.loads(line)
                        id_output = data.get('id')
                        created_at_output = data.get('created_at')

                        if id_output and created_at_output and id_output not in self.event_processor.seen_ids:
                            logger.info(f"New note: {id_output}")
                            self.event_processor.seen_ids.add(id_output)

                            asyncio.create_task(self.execute_subprocess(id_output, created_at_output))

                    except json.JSONDecodeError as e:
                        logger.error(f"Failed to parse JSON: {line}, error: {e}")

                await proc.wait()
                logger.info(f"Subprocess {proc.pid} terminated.")

            except Exception as e:
                logger.error(f"Error in monitor_new_notes: {e}")
                await asyncio.sleep(30)  # Retry after a delay in case of an error

async def main() -> None:
    event_processor = EventProcessor()
    monitor = Monitor(event_processor)
    notes_task = asyncio.create_task(monitor.monitor_new_notes())
    await asyncio.gather(notes_task)

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Service stopped.")
    finally:
        asyncio.run(http_client.aclose())
