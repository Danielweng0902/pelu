#!/usr/bin/env python3
"""Read Pelu's App Store Connect status; never writes to Apple's API."""
import json
import sys
from urllib.error import URLError

from appstoreconnect import APIError, Client


def main():
    client = Client()
    app = client.app()
    versions = client.get("apps/" + app["id"] + "/appStoreVersions", {"limit": 20})
    builds = client.get("builds", {"filter[app]": app["id"], "sort": "-uploadedDate", "limit": 10})
    print(json.dumps({"app": {"id": app["id"], **app["attributes"]},
                      "versions": [{"id": row["id"], **row["attributes"]} for row in versions],
                      "recent_builds": [{"id": row["id"], **row["attributes"]} for row in builds]},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except APIError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, URLError) as error:
        print(f"Connection check failed ({type(error).__name__}): {error}", file=sys.stderr)
        sys.exit(1)
