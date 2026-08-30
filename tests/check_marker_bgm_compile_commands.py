#!/usr/bin/env python3
"""Audit that warning exemptions cannot leak from vendor code into Stella TUs."""

from __future__ import annotations

import json
from pathlib import Path
import shlex
import sys


FIRST_PARTY = {"register_types.cpp", "stella_marker_bgm.cpp"}
VENDOR = "stb_vorbis_impl.cpp"
REQUIRED_WARNINGS = {"-Wall", "-Wextra", "-Werror"}
VENDOR_EXEMPTIONS = {"-Wno-unused-function", "-Wno-unused-parameter"}
GNU_VENDOR_EXEMPTIONS = {"-Wno-maybe-uninitialized"}


def fail(message: str) -> None:
	print(f"marker BGM compile-command gate: {message}", file=sys.stderr)
	raise SystemExit(1)


def command_tokens(entry: dict[str, object]) -> list[str]:
	arguments = entry.get("arguments")
	if isinstance(arguments, list) and all(isinstance(value, str) for value in arguments):
		return list(arguments)
	command = entry.get("command")
	if not isinstance(command, str):
		fail("entry has neither String command nor String arguments")
	return shlex.split(command)


def main() -> None:
	if len(sys.argv) != 3:
		fail("expected <compile_commands.json> <compiler-id>")
	commands_path = Path(sys.argv[1])
	compiler_id = sys.argv[2]
	if compiler_id == "MSVC" and not commands_path.is_file():
		print("marker BGM compile-command gate: MSVC has no compile_commands.json; "
			"CMake target separation remains authoritative")
		return
	if not commands_path.is_file():
		fail(f"missing {commands_path}")
	try:
		entries = json.loads(commands_path.read_text(encoding="utf-8"))
	except (OSError, UnicodeError, json.JSONDecodeError) as error:
		fail(f"could not read compile commands: {error}")
	if not isinstance(entries, list):
		fail("compile command root is not an Array")

	seen_first_party: set[str] = set()
	seen_vendor = False
	for raw_entry in entries:
		if not isinstance(raw_entry, dict) or not isinstance(raw_entry.get("file"), str):
			continue
		filename = Path(raw_entry["file"]).name
		if filename not in FIRST_PARTY and filename != VENDOR:
			continue
		tokens = command_tokens(raw_entry)
		token_set = set(tokens)
		if compiler_id in {"GNU", "Clang", "AppleClang"}:
			missing = REQUIRED_WARNINGS - token_set
			if missing:
				fail(f"{filename} is missing {sorted(missing)}")
		if filename in FIRST_PARTY:
			seen_first_party.add(filename)
			for token in tokens:
				if token.startswith("-Wno-"):
					fail(f"first-party {filename} contains forbidden {token}")
			if compiler_id in {"GNU", "Clang", "AppleClang"}:
				joined = " ".join(tokens)
				if "-isystem" not in token_set or "godot_cpp" not in joined:
					fail(f"{filename} does not consume godot-cpp as a SYSTEM include")
		else:
			seen_vendor = True
			if compiler_id in {"GNU", "Clang", "AppleClang"}:
				expected_exemptions = set(VENDOR_EXEMPTIONS)
				if compiler_id == "GNU":
					expected_exemptions |= GNU_VENDOR_EXEMPTIONS
				actual_exemptions = {token for token in tokens if token.startswith("-Wno-")}
				if actual_exemptions != expected_exemptions:
					fail(
						f"vendor {filename} exemptions are {sorted(actual_exemptions)}, "
						f"expected exactly {sorted(expected_exemptions)}"
					)

	if seen_first_party != FIRST_PARTY:
		fail(f"missing first-party compile entries: {sorted(FIRST_PARTY - seen_first_party)}")
	if not seen_vendor:
		fail("missing isolated stb vendor compile entry")
	print("marker BGM compile-command gate: PASS")


if __name__ == "__main__":
	main()
