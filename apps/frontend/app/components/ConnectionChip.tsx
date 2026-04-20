"use client";

interface Props {
  status: "connecting" | "connected" | "disconnected";
}

const LABEL: Record<Props["status"], string> = {
  connected: "Live",
  connecting: "Connecting",
  disconnected: "Offline",
};

const DOT: Record<Props["status"], string> = {
  connected: "bg-emerald-500 animate-pulse",
  connecting: "bg-amber-400 animate-pulse",
  disconnected: "bg-rose-500",
};

const RING: Record<Props["status"], string> = {
  connected: "ring-emerald-200 text-emerald-800 bg-emerald-50",
  connecting: "ring-amber-200 text-amber-800 bg-amber-50",
  disconnected: "ring-rose-200 text-rose-800 bg-rose-50",
};

export function ConnectionChip({ status }: Props) {
  return (
    <span
      className={`inline-flex items-center gap-2 rounded-full px-3 py-1 text-xs font-medium ring-1 ${RING[status]}`}
    >
      <span className={`h-2 w-2 rounded-full ${DOT[status]}`} />
      {LABEL[status]}
    </span>
  );
}
