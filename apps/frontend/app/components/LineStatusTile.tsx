"use client";

import { useMemo } from "react";
import { allLinesInOrder, statusTone, toneClasses } from "../../lib/tflLines";
import type { LineStatusPayload } from "../../lib/streamTypes";

interface Props {
  // Keyed by `line_id` so repeated messages for the same line just upsert.
  rows: Map<string, LineStatusPayload>;
  updatedAt: number | null;
}

// Render every known line even when nothing has ticked yet so the tile
// never looks empty on first paint. Lines without a live row show as
// "Awaiting data"; once the snapshot buffer replays or the first live
// message arrives the placeholder is replaced in place.
export function LineStatusTile({ rows, updatedAt }: Props) {
  const merged = useMemo(() => {
    const catalogue = allLinesInOrder();
    return catalogue
      .map((meta) => ({ meta, row: rows.get(meta.id) }))
      .sort((a, b) => a.meta.order - b.meta.order);
  }, [rows]);

  const counts = useMemo(() => {
    let good = 0,
      issues = 0,
      unknown = 0;
    for (const { row } of merged) {
      if (!row) unknown += 1;
      else if (row.status_severity === 10) good += 1;
      else issues += 1;
    }
    return { good, issues, unknown };
  }, [merged]);

  return (
    <section className="rounded-xl border border-gray-200 bg-white shadow-sm">
      <header className="flex items-center justify-between gap-4 border-b border-gray-100 px-5 py-4">
        <div>
          <h2 className="text-base font-semibold text-gray-900">Tube & Rail</h2>
          <p className="text-xs text-gray-500">
            Live line status from TfL, via the lakehouse streaming tier.
          </p>
        </div>
        <div className="flex items-center gap-2 text-xs font-medium">
          <span className="rounded-md bg-emerald-50 px-2 py-0.5 text-emerald-800 ring-1 ring-emerald-200">
            {counts.good} good
          </span>
          {counts.issues > 0 && (
            <span className="rounded-md bg-rose-50 px-2 py-0.5 text-rose-800 ring-1 ring-rose-200">
              {counts.issues} issues
            </span>
          )}
          {counts.unknown > 0 && (
            <span className="rounded-md bg-gray-50 px-2 py-0.5 text-gray-600 ring-1 ring-gray-200">
              {counts.unknown} waiting
            </span>
          )}
        </div>
      </header>

      <ul className="grid grid-cols-1 divide-y divide-gray-100 sm:grid-cols-2">
        {merged.map(({ meta, row }) => {
          const tone = statusTone(row?.status_severity);
          const label = row?.status_description ?? "Awaiting data";
          return (
            <li
              key={meta.id}
              className="flex items-center gap-3 px-5 py-3 sm:odd:border-r sm:odd:border-gray-100"
            >
              <span
                className="flex h-7 min-w-[88px] items-center justify-center rounded-md px-2 text-xs font-semibold tracking-wide"
                style={{ backgroundColor: meta.colour, color: meta.ink }}
                aria-label={`${meta.name} line`}
              >
                {meta.name}
              </span>
              <span
                className={`inline-flex shrink-0 items-center rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ${toneClasses(tone)}`}
                title={row?.reason || undefined}
              >
                {label}
              </span>
              {row?.reason ? (
                <span className="truncate text-xs text-gray-500">{row.reason}</span>
              ) : null}
            </li>
          );
        })}
      </ul>

      <footer className="flex items-center justify-between border-t border-gray-100 px-5 py-3 text-xs text-gray-500">
        <span>{merged.length} lines</span>
        <span>{updatedAt ? `updated ${formatAgo(updatedAt)}` : "waiting for feed"}</span>
      </footer>
    </section>
  );
}

function formatAgo(ts: number): string {
  const secs = Math.max(0, Math.floor((Date.now() - ts) / 1000));
  if (secs < 5) return "just now";
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  return `${Math.floor(mins / 60)}h ago`;
}
