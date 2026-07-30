#!/usr/bin/env python3
"""Probe a real, signed BrickLink Store API call and report the response *shape*.

BrickLink publishes no machine-readable spec, and `check-rebrickable-endpoint` only covers
Rebrickable — so the only way to know what a BrickLink endpoint actually returns is to call it.
This signs one GET per OAuth 1.0a/HMAC-SHA1 (same scheme as `BrickLinkOAuth1.swift`, stdlib only)
and prints the keys it got back, so a response shape can be pasted into an issue as evidence.

Credentials come from the environment and are never printed:

    export BL_CONSUMER_KEY=... BL_CONSUMER_SECRET=... BL_TOKEN=... BL_TOKEN_SECRET=...
    python3 probe.py --path /items/SET/10300-1/price --query guide_type=sold new_or_used=U currency_code=EUR

Add `--raw` to dump the whole payload instead of just its shape.
"""

import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE_URL = "https://api.bricklink.com/api/store/v1"
# RFC 5849 §3.6 — unreserved characters only. `urllib.parse.quote`'s default safe set leaves `/`
# unescaped, which would corrupt the signature base string.
UNRESERVED = "-._~"


def percent_encode(value):
    return urllib.parse.quote(str(value), safe=UNRESERVED)


def authorization_header(method, url, query_params, creds):
    oauth_params = {
        "oauth_consumer_key": creds["consumer_key"],
        "oauth_nonce": secrets.token_hex(16),
        "oauth_signature_method": "HMAC-SHA1",
        "oauth_timestamp": str(int(time.time())),
        "oauth_token": creds["token"],
        "oauth_version": "1.0",
    }
    all_params = {**oauth_params, **query_params}
    # RFC 5849 §3.4.1.3.2: encode first, *then* sort — sorting raw names and encoding afterwards
    # gives a different order (and so a different signature) as soon as a value needs escaping.
    encoded = sorted((percent_encode(k), percent_encode(v)) for k, v in all_params.items())
    normalized = "&".join(f"{k}={v}" for k, v in encoded)
    base_string = "&".join([method.upper(), percent_encode(url), percent_encode(normalized)])
    signing_key = f"{percent_encode(creds['consumer_secret'])}&{percent_encode(creds['token_secret'])}"
    signature = base64.b64encode(
        hmac.new(signing_key.encode(), base_string.encode(), hashlib.sha1).digest()
    ).decode()
    oauth_params["oauth_signature"] = signature
    header = ", ".join(
        f'{percent_encode(k)}="{percent_encode(v)}"' for k, v in sorted(oauth_params.items())
    )
    return f"OAuth {header}"


def load_credentials():
    names = {
        "consumer_key": "BL_CONSUMER_KEY",
        "consumer_secret": "BL_CONSUMER_SECRET",
        "token": "BL_TOKEN",
        "token_secret": "BL_TOKEN_SECRET",
    }
    creds = {field: os.environ.get(env, "") for field, env in names.items()}
    missing = [names[field] for field, value in creds.items() if not value]
    if missing:
        sys.exit(f"Missing environment variable(s): {', '.join(missing)}")
    return creds


def describe(value, indent=0, sample_entries=2):
    """Print a value's shape: keys and types, with a couple of real array entries as evidence."""
    pad = "  " * indent
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                print(f"{pad}{key}: {type(item).__name__}")
                describe(item, indent + 1, sample_entries)
            else:
                print(f"{pad}{key}: {type(item).__name__} = {item!r}")
    elif isinstance(value, list):
        print(f"{pad}({len(value)} entries)")
        for entry in value[:sample_entries]:
            describe(entry, indent + 1, sample_entries)
            print(f"{pad}  --")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--path", required=True, help="e.g. /items/SET/10300-1/price")
    parser.add_argument("--query", nargs="*", default=[], metavar="k=v", help="query parameters")
    parser.add_argument("--raw", action="store_true", help="dump the full JSON payload")
    args = parser.parse_args()

    query_params = dict(pair.split("=", 1) for pair in args.query)
    url = BASE_URL + args.path
    request = urllib.request.Request(
        url + ("?" + urllib.parse.urlencode(query_params) if query_params else ""),
        headers={"Authorization": authorization_header("GET", url, query_params, load_credentials())},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status, body = response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        status, body = error.code, error.read().decode()

    print(f"HTTP {status}  GET {args.path}  {query_params}\n")
    try:
        payload = json.loads(body)
    except json.JSONDecodeError:
        print(body[:2000])
        return

    if args.raw:
        print(json.dumps(payload, indent=2)[:20000])
        return

    # BrickLink answers HTTP 200 even for auth/quota failures — the real status is `meta.code`.
    print(json.dumps(payload.get("meta", {}), indent=2))
    if "data" not in payload:
        return
    print("\ndata:")
    describe(payload["data"], indent=1)


if __name__ == "__main__":
    main()
