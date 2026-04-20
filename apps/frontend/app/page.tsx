"use client";

import { useCallback, useState } from "react";
import { StreamMessage, useStreams } from "../lib/useStreams";
import {
  BikeOccupancyPayload,
  LineStatusPayload,
  TOPIC_BIKE_OCCUPANCY,
  TOPIC_LINE_STATUS,
} from "../lib/streamTypes";
import { ConnectionChip } from "./components/ConnectionChip";
import { LineStatusTile } from "./components/LineStatusTile";
import { BikeHireTile } from "./components/BikeHireTile";

const TOPICS = [TOPIC_LINE_STATUS, TOPIC_BIKE_OCCUPANCY];

export default function Home() {
  // Upsert-by-id Maps: every tick the same station or line overwrites its
  // prior row so the tiles always show the freshest state rather than an
  // unbounded feed. We store them in state (via new Map references) so
  // memoised derivations downstream refresh on every message.
  const [lines, setLines] = useState<Map<string, LineStatusPayload>>(new Map());
  const [stations, setStations] = useState<Map<string, BikeOccupancyPayload>>(
    new Map(),
  );
  const [linesUpdatedAt, setLinesUpdatedAt] = useState<number | null>(null);
  const [stationsUpdatedAt, setStationsUpdatedAt] = useState<number | null>(null);

  const handleMessage = useCallback((msg: StreamMessage) => {
    if (msg.topic === TOPIC_LINE_STATUS) {
      const row = msg.data as LineStatusPayload;
      setLines((prev) => {
        const next = new Map(prev);
        next.set(row.line_id, row);
        return next;
      });
      setLinesUpdatedAt(Date.now());
    } else if (msg.topic === TOPIC_BIKE_OCCUPANCY) {
      const row = msg.data as BikeOccupancyPayload;
      setStations((prev) => {
        const next = new Map(prev);
        next.set(row.bike_point_id, row);
        return next;
      });
      setStationsUpdatedAt(Date.now());
    }
  }, []);

  const { status, messageCount, snapshotCount, sessionId } = useStreams(
    TOPICS,
    handleMessage,
  );

  return (
    <div className="min-h-screen bg-gray-50 text-gray-900">
      <header className="border-b border-gray-200 bg-white">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-6 py-5">
          <div className="flex items-center gap-3">
            <LogoMark />
            <div>
              <h1 className="text-lg font-semibold tracking-tight">OpenVelox</h1>
              <p className="text-xs text-gray-500">
                London transport, live off the lakehouse.
              </p>
            </div>
          </div>
          <ConnectionChip status={status} />
        </div>
      </header>

      <main className="mx-auto grid max-w-6xl grid-cols-1 gap-6 px-6 py-8 lg:grid-cols-2">
        <LineStatusTile rows={lines} updatedAt={linesUpdatedAt} />
        <BikeHireTile stations={stations} updatedAt={stationsUpdatedAt} />
      </main>

      <footer className="mx-auto max-w-6xl px-6 pb-10">
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-gray-200 bg-white px-4 py-3 text-xs text-gray-600 shadow-sm">
          <Stat label="Session" value={sessionId ?? "—"} mono />
          <Stat label="Snapshot replay" value={snapshotCount.toLocaleString()} />
          <Stat label="Live messages" value={messageCount.toLocaleString()} />
          <Stat label="Subscriptions" value={`${TOPICS.length} topics`} />
        </div>
      </footer>
    </div>
  );
}

function Stat({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="flex items-center gap-2">
      <span className="text-gray-400">{label}</span>
      <span
        className={`${mono ? "font-mono" : "font-medium"} text-gray-800 truncate max-w-[260px]`}
      >
        {value}
      </span>
    </div>
  );
}

function LogoMark() {
  return (
    <span
      className="flex h-9 w-9 items-center justify-center rounded-full border-4 border-tfl-blue text-tfl-blue"
      aria-hidden
    >
      <span className="h-1.5 w-6 rounded-sm bg-tfl-red" />
    </span>
  );
}
