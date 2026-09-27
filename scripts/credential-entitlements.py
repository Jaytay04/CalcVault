#!/usr/bin/env python3
"""Validate CalcVault's explicit SideStore host entitlement template."""

import plistlib
import sys
from pathlib import Path
from xml.parsers.expat import ExpatError


APPLICATION_IDENTIFIER = "FAKETEAMID.com.jaylintaylor.calcvault"
KEYCHAIN_ACCESS_GROUPS = [
    "FAKETEAMID.com.jaylintaylor.calcvault",
    "FAKETEAMID.com.jaylintaylor.calcvault.hostonly",
]
EXPECTED_KEYS = {"application-identifier", "keychain-access-groups"}


def validate(path: Path) -> None:
    try:
        with path.open("rb") as plist_file:
            entitlements = plistlib.load(plist_file)
    except (OSError, plistlib.InvalidFileException, ValueError, ExpatError) as error:
        raise ValueError(f"cannot read entitlement plist: {error}") from error

    if not isinstance(entitlements, dict):
        raise ValueError("entitlement plist root must be a dictionary")
    if set(entitlements) != EXPECTED_KEYS:
        raise ValueError("entitlement plist must contain only application-identifier and keychain-access-groups")
    if entitlements["application-identifier"] != APPLICATION_IDENTIFIER:
        raise ValueError("application-identifier does not match the SideStore placeholder")
    if entitlements["keychain-access-groups"] != KEYCHAIN_ACCESS_GROUPS:
        raise ValueError("keychain-access-groups do not match the required ordered groups")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} entitlement-plist", file=sys.stderr)
        return 2
    try:
        validate(Path(sys.argv[1]))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print("entitlement_verification=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
