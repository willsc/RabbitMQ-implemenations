#!/usr/bin/env python3
"""Apply a reviewed definitions file through verified HTTPS, including Amazon MQ."""
import argparse
import base64
import getpass
import json
from pathlib import Path
import ssl
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", required=True, help="HTTPS management base URL")
    parser.add_argument("--username", required=True)
    parser.add_argument("--definitions", required=True, type=Path)
    parser.add_argument("--ca-file", type=Path)
    args = parser.parse_args()
    endpoint = urllib.parse.urlsplit(args.endpoint)
    if endpoint.scheme != "https" or not endpoint.hostname or endpoint.username or endpoint.query or endpoint.fragment:
        parser.error("Use an HTTPS base URL without credentials, query or fragment")
    raw = args.definitions.read_bytes()
    json.loads(raw)  # Validate before requesting a password.
    password = getpass.getpass("RabbitMQ administrator password: ")
    authorization = base64.b64encode(f"{args.username}:{password}".encode()).decode()
    request = urllib.request.Request(args.endpoint.rstrip("/") + "/api/definitions", data=raw, method="POST",
                                     headers={"Content-Type": "application/json", "Authorization": "Basic " + authorization})
    context = ssl.create_default_context(cafile=str(args.ca_file) if args.ca_file else None)
    try:
        # Do not follow redirects with administrator credentials.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *_args, **_kwargs):
                return None
        opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=context), NoRedirect())
        with opener.open(request, timeout=120) as response:
            if response.status not in (200, 201, 204):
                raise RuntimeError("Unexpected definitions import status")
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Import failed with HTTP {error.code}; inspect broker logs. Import may be partial.") from None
    print("Definitions imported; verify topology, permissions and federation link status before moving clients.")


if __name__ == "__main__":
    main()
