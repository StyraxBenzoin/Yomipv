#!/usr/bin/env python3
"""
build_anki_db.py
Fetches all cards from AnkiConnect and writes a word→interval JSON

Usage:
    python build_anki_db.py
    python build_anki_db.py --url http://127.0.0.1:8765 --field word Word --output anki_words.json
"""

import argparse
import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime
from typing import Any


DEFAULT_URL   = "http://127.0.0.1:8765"
DEFAULT_FIELDS = ["word", "Word"]
DEFAULT_OUT   = "anki_words.json"


def anki_request(url, action, **params):
    payload = json.dumps({"action": action, "version": 6, "params": params}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read())
    except urllib.error.URLError as e:
        sys.exit(f"[error] Cannot reach AnkiConnect at {url}: {e}\n"
                 "Make sure Anki is open with the AnkiConnect add-on installed.")

    if body.get("error"):
        sys.exit(f"[error] AnkiConnect: {body['error']}")
    return body["result"]


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Anki word database for subtitle_colorizer")
    parser.add_argument("--url",    default=DEFAULT_URL,    help="AnkiConnect URL")
    parser.add_argument("--field",  default=DEFAULT_FIELDS, nargs="+",
                        help="Note field(s) containing the Japanese word (default: word Word)")
    parser.add_argument("--output", default=DEFAULT_OUT,    help="Output JSON file path")
    parser.add_argument("--progress-file",                help="Path to a file where progress will be written")
    args = parser.parse_args()

    def report_progress(current, total):
        if not args.progress_file:
            return
        try:
            with open(args.progress_file, "w") as pf:
                pf.write(f"{current}/{total}")
        except:
            pass

    fields = args.field
    print(f"Connecting to AnkiConnect at {args.url}...")
    print(f"Searching fields: {', '.join(fields)}")

    # Build an OR query across all requested fields
    query = " OR ".join(f"{f}:*" for f in fields)
    card_ids = anki_request(args.url, "findCards", query=query)
    if not card_ids:
        sys.exit(f"[error] No cards found for fields: {', '.join(fields)}. "
                 "Check --field matches your note type(s).")
    print(f"Found {len(card_ids)} cards — fetching info in batches...")

    total_cards = len(card_ids)
    total_steps = total_cards * 2
    processed_count: int = 0

    BATCH = 500
    # note_id -> (best interval, best state)
    note_data: dict[int, tuple[int, str]] = {}

    batch: list[int] = []
    for cid in card_ids:
        batch.append(cid)
        if len(batch) >= BATCH:
            cards_info = anki_request(args.url, "cardsInfo", cards=batch)
            for card in cards_info:
                nid      = card.get("note")
                interval = card.get("interval", 0)
                queue    = card.get("queue", 0)
                
                # State classification
                if queue == -1:
                    state = "Suspended"
                elif queue == 0:
                    state = "New"
                elif queue in (1, 3):
                    state = "Learning"
                elif queue == 2:
                    state = "Review"
                else:
                    state = "New"

                # Priority: Review > Learning > New > Suspended
                state_priority = {"Review": 3, "Learning": 2, "New": 1, "Suspended": 0}
                
                if nid not in note_data:
                    note_data[nid] = (interval, state)
                else:
                    old_val = note_data.get(nid)
                    if old_val is not None:
                        old_interval, old_state = old_val
                        new_interval = max(old_interval, interval)
                        if state_priority.get(state, 0) > state_priority.get(old_state, 0):
                            new_state = state
                        else:
                            new_state = old_state
                        note_data[nid] = (new_interval, new_state)

            print(f"  processed batch of {len(batch)} cards")
            processed_count += len(batch) # pyre-ignore
            report_progress(processed_count, total_steps)
            batch = []

    if batch:
        cards_info = anki_request(args.url, "cardsInfo", cards=batch)
        for card in cards_info:
            nid      = card.get("note")
            interval = card.get("interval", 0)
            queue    = card.get("queue", 0)
            
            if queue == -1:
                state = "Suspended"
            elif queue == 0:
                state = "New"
            elif queue in (1, 3):
                state = "Learning"
            elif queue == 2:
                state = "Review"
            else:
                state = "New"

            state_priority = {"Review": 3, "Learning": 2, "New": 1, "Suspended": 0}
            
            if nid not in note_data:
                note_data[nid] = (interval, state)
            else:
                old_val = note_data.get(nid)
                if old_val is not None:
                    old_interval, old_state = old_val
                    new_interval = max(old_interval, interval)
                    if state_priority.get(state, 0) > state_priority.get(old_state, 0):
                        new_state = state
                    else:
                        new_state = old_state
                    note_data[nid] = (new_interval, new_state)
        print(f"  processed final batch of {len(batch)} cards")
        processed_count += len(batch) # pyre-ignore
        report_progress(processed_count, total_steps)

    # Fetch note info in batches to get the word field value
    note_ids = list(note_data.keys())
    print(f"Fetching {len(note_ids)} notes...")

    # word -> {"interval": X, "state": Y}
    word_data: dict[str, dict[str, Any]] = {}

    batch: list[int] = []
    for nid in note_ids:
        batch.append(nid)
        if len(batch) >= BATCH:
            notes_info = anki_request(args.url, "notesInfo", notes=batch)
            for note in notes_info:
                note_id     = int(note.get("noteId", 0))
                note_fields = note.get("fields", {})
                word = ""
                for f in fields:
                    raw_f = note_fields.get(f)
                    if raw_f and raw_f.get("value", "").strip():
                        word = raw_f.get("value", "").strip()
                        break
                if not word:
                    continue
                
                res = note_data.get(note_id, (0, "New"))
                cur_interval, cur_state = res
                word_str = str(word)
                
                existing = word_data.get(word_str)
                if existing is not None:
                    if cur_interval > int(existing.get("interval", 0)):
                        word_data[word_str] = {"interval": cur_interval, "state": cur_state}
                else:
                    word_data[word_str] = {"interval": cur_interval, "state": cur_state}
            print(f"  processed batch of {len(batch)} notes")
            processed_count += len(batch) # pyre-ignore
            report_progress(processed_count, total_steps)
            batch = []

    if batch:
        notes_info = anki_request(args.url, "notesInfo", notes=batch)
        for note in notes_info:
            note_id     = int(note.get("noteId", 0))
            note_fields = note.get("fields", {})
            word = ""
            for f in fields:
                raw_f = note_fields.get(f)
                if raw_f and raw_f.get("value", "").strip():
                    word = raw_f.get("value", "").strip()
                    break
            if word:
                res = note_data.get(note_id, (0, "New"))
                cur_interval, cur_state = res
                word_str = str(word)
                existing = word_data.get(word_str)
                if existing is not None:
                    if cur_interval > int(existing.get("interval", 0)):
                        word_data[word_str] = {"interval": cur_interval, "state": cur_state}
                else:
                    word_data[word_str] = {"interval": cur_interval, "state": cur_state}

        print(f"  processed final batch of {len(batch)} notes")
        processed_count += len(batch) # pyre-ignore
        report_progress(processed_count, total_steps)

    db = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "fields": fields,
        "words": word_data,
    }

    output_dir = os.path.dirname(os.path.abspath(args.output))
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(db, f, ensure_ascii=False, indent=2)

    print(f"\nDone. {len(word_data)} unique words saved to: {args.output}")
    print("Run this script again whenever your Anki collection changes.")


if __name__ == "__main__":
    main()
