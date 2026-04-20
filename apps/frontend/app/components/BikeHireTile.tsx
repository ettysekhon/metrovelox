"use client";

import { useMemo } from "react";
import type { BikeOccupancyPayload } from "../../lib/streamTypes";

interface Props {
  stations: Map<string, BikeOccupancyPayload>;
  updatedAt: number | null;
}

const TOP_N = 8;

// Show the two extremes of the cycle hire network: docks that are near full
// (can't return) and docks that are near empty (can't hire). This maps
// directly to the two failure modes a user feels when they walk up to a
// station, and — unlike a uniform feed — keeps the tile useful even when
// most of the city's 800+ stations are in a healthy middle.
export function BikeHireTile({ stations, updatedAt }: Props) {
  const { total, totalBikes, totalDocks, fullest, emptiest } = useMemo(() => {
    const rows = [...stations.values()];
    let totalBikes = 0;
    let totalDocks = 0;
    for (const r of rows) {
      totalBikes += r.nb_bikes + r.nb_ebikes;
      totalDocks += r.nb_bikes + r.nb_ebikes + r.nb_empty_docks;
    }
    const fullest = [...rows]
      .sort((a, b) => b.occupancy_pct - a.occupancy_pct)
      .slice(0, TOP_N);
    const emptiest = [...rows]
      .filter((r) => r.nb_bikes + r.nb_ebikes + r.nb_empty_docks > 0)
      .sort((a, b) => a.occupancy_pct - b.occupancy_pct)
      .slice(0, TOP_N);
    return { total: rows.length, totalBikes, totalDocks, fullest, emptiest };
  }, [stations]);

  return (
    <section className="rounded-xl border border-gray-200 bg-white shadow-sm">
      <header className="flex items-center justify-between gap-4 border-b border-gray-100 px-5 py-4">
        <div>
          <h2 className="text-base font-semibold text-gray-900">Cycle Hire</h2>
          <p className="text-xs text-gray-500">
            Occupancy across tracked docking stations.
          </p>
        </div>
        <div className="flex items-center gap-2 text-xs font-medium">
          <span className="rounded-md bg-sky-50 px-2 py-0.5 text-sky-800 ring-1 ring-sky-200">
            {total.toLocaleString()} stations
          </span>
          <span className="rounded-md bg-gray-50 px-2 py-0.5 text-gray-700 ring-1 ring-gray-200">
            {totalBikes.toLocaleString()} / {totalDocks.toLocaleString()} bikes
          </span>
        </div>
      </header>

      <div className="grid grid-cols-1 divide-y divide-gray-100 lg:grid-cols-2 lg:divide-x lg:divide-y-0">
        <StationList title="Full docks" tone="full" rows={fullest} />
        <StationList title="Empty docks" tone="empty" rows={emptiest} />
      </div>

      <footer className="flex items-center justify-between border-t border-gray-100 px-5 py-3 text-xs text-gray-500">
        <span>Top {TOP_N} per side</span>
        <span>{updatedAt ? `updated ${formatAgo(updatedAt)}` : "waiting for feed"}</span>
      </footer>
    </section>
  );
}

function StationList({
  title,
  tone,
  rows,
}: {
  title: string;
  tone: "full" | "empty";
  rows: BikeOccupancyPayload[];
}) {
  return (
    <div className="px-5 py-4">
      <div className="mb-3 flex items-center justify-between">
        <h3 className="text-xs font-semibold uppercase tracking-wide text-gray-500">
          {title}
        </h3>
        <span className="text-xs text-gray-400">{rows.length}</span>
      </div>
      {rows.length === 0 ? (
        <p className="text-xs text-gray-400">Awaiting data…</p>
      ) : (
        <ul className="space-y-2">
          {rows.map((row) => (
            <StationRow key={row.bike_point_id} row={row} tone={tone} />
          ))}
        </ul>
      )}
    </div>
  );
}

function StationRow({
  row,
  tone,
}: {
  row: BikeOccupancyPayload;
  tone: "full" | "empty";
}) {
  const pct = Math.max(0, Math.min(100, row.occupancy_pct));
  const barColour = tone === "full" ? "bg-emerald-500" : "bg-rose-500";
  const subtitle =
    tone === "full"
      ? `${row.nb_bikes + row.nb_ebikes} bikes · ${row.nb_empty_docks} docks free`
      : `${row.nb_empty_docks} docks free · ${row.nb_bikes + row.nb_ebikes} bikes left`;

  return (
    <li className="space-y-1">
      <div className="flex items-baseline justify-between gap-2">
        <span className="truncate text-sm font-medium text-gray-800">
          {row.common_name}
        </span>
        <span className="shrink-0 text-xs font-semibold text-gray-700">
          {Math.round(pct)}%
        </span>
      </div>
      <div className="h-1.5 w-full overflow-hidden rounded-full bg-gray-100">
        <div className={`h-full ${barColour}`} style={{ width: `${pct}%` }} />
      </div>
      <p className="text-xs text-gray-500">{subtitle}</p>
    </li>
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
