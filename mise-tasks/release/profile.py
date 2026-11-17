#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.13"
# dependencies = ["httpx==0.28.1", "pyjwt[crypto]==2.10.1"]
# ///
#MISE description="Create signd's App ID and Developer ID profile and write the profile to a file"
#USAGE arg "<output>" help="Where to write the .provisionprofile"
"""Create the App ID and the Developer ID provisioning profile through the App Store Connect API.

Reads APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID and APP_STORE_CONNECT_PRIVATE_KEY
(the .p8 contents) from the environment. Reuses an existing App ID and an active profile of the
same name, so it can run again safely.
"""

import base64
import os
import sys
import time
from pathlib import Path

import httpx
import jwt

BUNDLE_ID = "com.victor-software-house.signd"
PROFILE_NAME = "signd Developer ID"
API = "https://api.appstoreconnect.apple.com/v1"


def client() -> httpx.Client:
    now = int(time.time())
    token = jwt.encode(
        {"iss": os.environ["APP_STORE_CONNECT_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
        os.environ["APP_STORE_CONNECT_PRIVATE_KEY"],
        algorithm="ES256",
        headers={"kid": os.environ["APP_STORE_CONNECT_KEY_ID"], "typ": "JWT"},
    )
    return httpx.Client(base_url=API, headers={"Authorization": f"Bearer {token}"}, timeout=30)


def check(response: httpx.Response) -> dict:
    if response.is_error:
        sys.exit(f"✘ {response.request.method} {response.request.url.path}: {response.status_code} {response.text}")
    return response.json()


def bundle_id(api: httpx.Client) -> str:
    found = check(api.get("/bundleIds", params={"filter[identifier]": BUNDLE_ID}))["data"]
    exact = [b for b in found if b["attributes"]["identifier"] == BUNDLE_ID]
    if exact:
        return exact[0]["id"]
    body = {"data": {"type": "bundleIds", "attributes": {"identifier": BUNDLE_ID, "name": "signd", "platform": "MAC_OS"}}}
    return check(api.post("/bundleIds", json=body))["data"]["id"]


def certificates(api: httpx.Client) -> list[str]:
    ids = []
    for kind in ("DEVELOPER_ID_APPLICATION_G2", "DEVELOPER_ID_APPLICATION"):
        data = check(api.get("/certificates", params={"filter[certificateType]": kind}))["data"]
        ids += [c["id"] for c in data if c["attributes"].get("activated", True)]
    if not ids:
        sys.exit("✘ no Developer ID Application certificate in the team")
    return ids


def profile(api: httpx.Client, bundle: str) -> str:
    found = check(api.get("/profiles", params={"filter[name]": PROFILE_NAME}))["data"]
    active = [p for p in found if p["attributes"]["profileState"] == "ACTIVE"]
    if active:
        return active[0]["attributes"]["profileContent"]
    body = {
        "data": {
            "type": "profiles",
            "attributes": {"name": PROFILE_NAME, "profileType": "MAC_APP_DIRECT"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle}},
                "certificates": {"data": [{"type": "certificates", "id": c} for c in certificates(api)]},
            },
        }
    }
    return check(api.post("/profiles", json=body))["data"]["attributes"]["profileContent"]


def main() -> None:
    output = Path(sys.argv[1])
    with client() as api:
        content = profile(api, bundle_id(api))
    output.write_bytes(base64.b64decode(content))
    print(f"✔ {PROFILE_NAME} written to {output}")


if __name__ == "__main__":
    main()
