#!/usr/bin/env python3
"""Generate synthetic TfL line status Parquet for smoke testing."""

import datetime
import json
import random
import struct
import sys

LINES = [
    ("bakerloo", "Bakerloo", "tube"),
    ("central", "Central", "tube"),
    ("circle", "Circle", "tube"),
    ("district", "District", "tube"),
    ("hammersmith-city", "Hammersmith & City", "tube"),
    ("jubilee", "Jubilee", "tube"),
    ("metropolitan", "Metropolitan", "tube"),
    ("northern", "Northern", "tube"),
    ("piccadilly", "Piccadilly", "tube"),
    ("victoria", "Victoria", "tube"),
    ("waterloo-city", "Waterloo & City", "tube"),
    ("elizabeth", "Elizabeth line", "elizabeth-line"),
    ("dlr", "DLR", "dlr"),
    ("london-overground", "London Overground", "overground"),
]

SEVERITY = [
    (0, "Special Service"),
    (1, "Closed"),
    (2, "Suspended"),
    (5, "Part Closure"),
    (6, "Severe Delays"),
    (7, "Reduced Service"),
    (9, "Minor Delays"),
    (10, "Good Service"),
    (10, "Good Service"),
    (10, "Good Service"),
    (10, "Good Service"),
    (10, "Good Service"),
]


def main():
    rows = []
    now = datetime.datetime.now(datetime.timezone.utc)

    for i in range(100):
        line_id, line_name, mode_name = random.choice(LINES)
        sev_code, sev_desc = random.choice(SEVERITY)
        event_time = now - datetime.timedelta(hours=random.randint(0, 72))
        reason = None if sev_code == 10 else f"Test disruption reason for {line_name}"

        rows.append({
            "line_id": line_id,
            "line_name": line_name,
            "mode_name": mode_name,
            "status_severity": sev_code,
            "status_severity_description": sev_desc,
            "reason": reason,
            "valid_from": (event_time - datetime.timedelta(hours=1)).isoformat(),
            "valid_to": event_time.isoformat(),
            "ingested_at": event_time.isoformat(),
        })

    try:
        import pyarrow as pa
        import pyarrow.parquet as pq

        schema = pa.schema([
            ("line_id", pa.string()),
            ("line_name", pa.string()),
            ("mode_name", pa.string()),
            ("status_severity", pa.int32()),
            ("status_severity_description", pa.string()),
            ("reason", pa.string()),
            ("valid_from", pa.string()),
            ("valid_to", pa.string()),
            ("ingested_at", pa.string()),
        ])

        table = pa.table({
            col.name: [r[col.name] for r in rows] for col in schema
        }, schema=schema)

        pq.write_table(table, "/tmp/line_status_test.parquet")
        print(f"Wrote {len(rows)} rows to /tmp/line_status_test.parquet")
        print("Upload with: gsutil cp /tmp/line_status_test.parquet gs://$GCS_BUCKET/raw/tube/line_status_event_stream/data.parquet")

    except ImportError:
        out = "/tmp/line_status_test.jsonl"
        with open(out, "w") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
        print(f"pyarrow not installed. Wrote {len(rows)} rows as JSONL to {out}")
        print("Install pyarrow (pip install pyarrow) and re-run for Parquet output.")
        sys.exit(1)


if __name__ == "__main__":
    main()
