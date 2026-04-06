#!/usr/bin/env python3
"""Generate placeholder beep voice WAVs from .stla scenario files.

Reads a .stla file, extracts all dialogue lines, generates a WAV for each
(one beep per character, pause on punctuation), and writes the WAV to the
voice directory. Also updates the .stla file to add #voice: tags where missing.

Usage:
    python tools/generate_placeholder_voice.py examples/demo/scenarios/demo.stla \
        --voice-dir examples/demo/audio/voice
"""

import argparse
import math
import os
import re
import struct
import wave


# ── Audio parameters ──

SAMPLE_RATE = 22050
BEEP_FREQ = 440        # Hz
BEEP_DURATION = 0.05   # seconds per beep
CHAR_INTERVAL = 0.03   # seconds between characters (matches typewriter speed)
PUNCT_PAUSE = 0.20     # seconds pause on punctuation

PUNCTUATION = set("。，、！？；：\u201c\u201d\u2018\u2019（）【】…—·.,!?;: \"'()-\u3000 ")


def generate_beep_samples(freq: float, duration: float) -> list[int]:
    """Generate a short sine wave beep."""
    n = int(SAMPLE_RATE * duration)
    fade = min(n // 4, 200)
    samples = []
    for i in range(n):
        t = i / SAMPLE_RATE
        s = math.sin(2 * math.pi * freq * t)
        env = 1.0
        if i < fade:
            env = i / fade
        elif i > n - fade:
            env = (n - i) / fade
        samples.append(int(s * env * 16384))
    return samples


def generate_silence(duration: float) -> list[int]:
    """Generate silence for a given duration."""
    return [0] * int(SAMPLE_RATE * duration)


def text_to_wav(text: str, out_path: str):
    """Generate a WAV file from dialogue text: beep per char, pause on punct."""
    samples = []
    for ch in text:
        if ch in PUNCTUATION:
            samples.extend(generate_silence(PUNCT_PAUSE))
        else:
            samples.extend(generate_beep_samples(BEEP_FREQ, BEEP_DURATION))
            # Gap between beeps
            gap = CHAR_INTERVAL - BEEP_DURATION
            if gap > 0:
                samples.extend(generate_silence(gap))

    if not samples:
        samples = generate_silence(0.1)

    with wave.open(out_path, "w") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(struct.pack("<" + "h" * len(samples), *samples))


# ── .stla parsing ──

def extract_dialogues(lines: list[str]) -> list[dict]:
    """Extract dialogue lines with their line numbers and metadata."""
    dialogues = []
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("//") or stripped.startswith("@") or stripped.startswith("-"):
            continue

        # Match: character「text」 or 「text」 (narration)
        m = re.match(r'^(.*?)\u300c(.*?)\u300d(.*)$', stripped)
        if not m:
            continue

        character = m.group(1).strip()
        text = m.group(2).strip()
        after = m.group(3).strip()

        # Check existing voice tag
        voice_match = re.search(r'#voice:(\S+)', after)
        existing_voice = voice_match.group(1) if voice_match else ""

        dialogues.append({
            "line_idx": i,
            "character": character,
            "text": text,
            "existing_voice": existing_voice,
        })

    return dialogues


def assign_voice_ids(dialogues: list[dict]) -> list[dict]:
    """Assign voice IDs to dialogues that don't have one."""
    # Count existing IDs per character to continue numbering
    counters = {}
    for d in dialogues:
        char_key = d["character"] if d["character"] else "narration"
        if d["existing_voice"]:
            # Extract number from existing ID like sakura_003
            m = re.search(r'_(\d+)$', d["existing_voice"])
            if m:
                num = int(m.group(1))
                counters[char_key] = max(counters.get(char_key, 0), num)

    for d in dialogues:
        if d["existing_voice"]:
            d["voice_id"] = d["existing_voice"]
        else:
            char_key = d["character"] if d["character"] else "narration"
            counters[char_key] = counters.get(char_key, 0) + 1
            d["voice_id"] = f"{char_key}_{counters[char_key]:03d}"

    return dialogues


def update_stl_file(lines: list[str], dialogues: list[dict]) -> list[str]:
    """Update .stla lines to add #voice: tags where missing."""
    updated = lines[:]
    for d in dialogues:
        if d["existing_voice"]:
            continue
        idx = d["line_idx"]
        line = updated[idx].rstrip("\n")
        # Add voice tag after the closing bracket
        updated[idx] = f"{line} #voice:{d['voice_id']}\n"
    return updated


def main():
    parser = argparse.ArgumentParser(description="Generate placeholder voice WAVs from .stla files")
    parser.add_argument("stl_file", help="Path to .stla scenario file")
    parser.add_argument("--voice-dir", required=True, help="Output directory for WAV files")
    parser.add_argument("--dry-run", action="store_true", help="Don't write files, just show what would be done")
    parser.add_argument("--no-update-stl", action="store_true", help="Don't update the .stla file with voice tags")
    args = parser.parse_args()

    os.makedirs(args.voice_dir, exist_ok=True)

    with open(args.stl_file, "r", encoding="utf-8") as f:
        lines = f.readlines()

    dialogues = extract_dialogues(lines)
    dialogues = assign_voice_ids(dialogues)

    print(f"Found {len(dialogues)} dialogue lines")

    generated = 0
    for d in dialogues:
        wav_path = os.path.join(args.voice_dir, f"{d['voice_id']}.wav")
        if args.dry_run:
            tag = " (exists)" if d["existing_voice"] else " (new)"
            print(f"  {d['voice_id']}: {d['character'] or '(narration)'} - {d['text'][:30]}...{tag}")
        else:
            text_to_wav(d["text"], wav_path)
            generated += 1

    if args.dry_run:
        print(f"(dry run — no files written)")
    else:
        print(f"Generated {generated} WAV files in {args.voice_dir}")

    if not args.no_update_stl and not args.dry_run:
        updated = update_stl_file(lines, dialogues)
        if updated != lines:
            with open(args.stl_file, "w", encoding="utf-8") as f:
                f.writelines(updated)
            new_tags = sum(1 for d in dialogues if not d["existing_voice"])
            print(f"Updated {args.stl_file}: added {new_tags} #voice: tags")
        else:
            print(f"{args.stl_file}: all dialogues already have voice tags")


if __name__ == "__main__":
    main()
