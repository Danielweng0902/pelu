#!/usr/bin/env python3
"""Prepare an iOS App Store version and optionally submit it for review.

    python3 scripts/appstore-submit.py <version> <build> --notes-file NOTES [--submit]

Creates the App Store version if needed (release after approval), writes
"What's New" to every localization, attaches the uploaded build, and with
--submit sends it to App Review. Without --submit nothing is sent for review.
"""
import argparse
import sys
from urllib.error import URLError

from appstoreconnect import APIError, Client

EDITABLE_STATES = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                   "METADATA_REJECTED", "INVALID_BINARY"}


def find_build(client, app_id, version, build):
    builds = client.get("builds", {"filter[app]": app_id, "filter[version]": build,
                                   "filter[preReleaseVersion.version]": version,
                                   "filter[preReleaseVersion.platform]": "IOS", "limit": 2})
    if len(builds) != 1:
        raise ValueError(f"Expected one uploaded build {version} ({build}), found {len(builds)}")
    attributes = builds[0]["attributes"]
    if attributes["processingState"] != "VALID" or attributes["expired"]:
        raise ValueError(f"Build {build} is {attributes['processingState']}"
                         + (" and expired" if attributes["expired"] else ""))
    return builds[0]


def find_or_create_version(client, app, version):
    versions = client.get("apps/" + app["id"] + "/appStoreVersions",
                          {"filter[platform]": "IOS", "limit": 20})
    for row in versions:
        if row["attributes"]["versionString"] == version:
            state = row["attributes"]["appStoreState"]
            if state not in EDITABLE_STATES:
                raise ValueError(f"Version {version} is {state} and cannot be edited")
            print(f"Using existing version {version} ({state})")
            return row
    previous = next((row for row in versions if row["attributes"].get("copyright")), None)
    attributes = {"platform": "IOS", "versionString": version, "releaseType": "AFTER_APPROVAL"}
    if previous:
        attributes["copyright"] = previous["attributes"]["copyright"]
    created = client.request("POST", "appStoreVersions", body={"data": {
        "type": "appStoreVersions", "attributes": attributes,
        "relationships": {"app": {"data": {"type": "apps", "id": app["id"]}}}}})["data"]
    print(f"Created version {version}")
    return created


def write_whats_new(client, app, version_id, notes):
    localizations = client.get(f"appStoreVersions/{version_id}/appStoreVersionLocalizations")
    if not localizations:
        client.request("POST", "appStoreVersionLocalizations", body={"data": {
            "type": "appStoreVersionLocalizations",
            "attributes": {"locale": app["attributes"]["primaryLocale"], "whatsNew": notes},
            "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
        print(f"Wrote What's New ({app['attributes']['primaryLocale']})")
        return
    for row in localizations:
        client.request("PATCH", "appStoreVersionLocalizations/" + row["id"], body={"data": {
            "type": "appStoreVersionLocalizations", "id": row["id"],
            "attributes": {"whatsNew": notes}}})
        print(f"Wrote What's New ({row['attributes']['locale']})")


def submit(client, app_id, version_id):
    pending = client.get("reviewSubmissions", {"filter[app]": app_id, "filter[platform]": "IOS",
                                               "filter[state]": "READY_FOR_REVIEW", "limit": 1})
    if pending:
        submission = pending[0]
    else:
        submission = client.request("POST", "reviewSubmissions", body={"data": {
            "type": "reviewSubmissions", "attributes": {"platform": "IOS"},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
    items = client.request("GET", f"reviewSubmissions/{submission['id']}/items",
                           {"include": "appStoreVersion"})["data"]
    if not any((item["relationships"].get("appStoreVersion", {}).get("data") or {}).get("id") == version_id
               for item in items):
        client.request("POST", "reviewSubmissionItems", body={"data": {
            "type": "reviewSubmissionItems",
            "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission["id"]}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}}}}})
    result = client.request("PATCH", "reviewSubmissions/" + submission["id"], body={"data": {
        "type": "reviewSubmissions", "id": submission["id"], "attributes": {"submitted": True}}})["data"]
    print(f"Submitted for review ({result['attributes']['state']})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("build")
    parser.add_argument("--notes-file", required=True)
    parser.add_argument("--submit", action="store_true")
    args = parser.parse_args()
    with open(args.notes_file, encoding="utf-8") as handle:
        notes = handle.read().strip()
    if not notes:
        raise ValueError("Notes file is empty")

    client = Client()
    app = client.app()
    build = find_build(client, app["id"], args.version, args.build)
    version = find_or_create_version(client, app, args.version)
    write_whats_new(client, app, version["id"], notes)
    client.request("PATCH", f"appStoreVersions/{version['id']}/relationships/build",
                   body={"data": {"type": "builds", "id": build["id"]}})
    print(f"Attached build {args.build}")
    if args.submit:
        submit(client, app["id"], version["id"])
    else:
        print("Prepared only; rerun with --submit to send to App Review")


if __name__ == "__main__":
    try:
        main()
    except APIError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, URLError) as error:
        print(f"Failed ({type(error).__name__}): {error}", file=sys.stderr)
        sys.exit(1)
