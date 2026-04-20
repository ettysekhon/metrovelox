// Official TfL line colour palette and display order. Keys match the
// `line_id` field on the `tfl.analytics.line-status-latest` topic so we can
// look up presentation metadata in a single hop. Colours taken from the
// TfL brand guidelines (hex values they publish for digital use).
//
// Keeping this next to the UI rather than the API means the dashboard can
// render a brand-correct tile even for lines that haven't emitted a status
// message yet (still inside the snapshot buffer's TTL), and the API stays a
// generic fanout.

export interface LineMeta {
  id: string;
  name: string;
  // Hex colour used for the coloured stripe on each tile.
  colour: string;
  // Foreground colour that hits WCAG AA on top of `colour`. Used for the
  // small roundel-style label so e.g. Circle (yellow) stays legible.
  ink: string;
  // Presentation order roughly matching TfL's official line list; keeps
  // the grid stable across snapshot / live ticks.
  order: number;
}

const LINES: LineMeta[] = [
  { id: "bakerloo", name: "Bakerloo", colour: "#B36305", ink: "#FFFFFF", order: 1 },
  { id: "central", name: "Central", colour: "#E32017", ink: "#FFFFFF", order: 2 },
  { id: "circle", name: "Circle", colour: "#FFD300", ink: "#111111", order: 3 },
  { id: "district", name: "District", colour: "#00782A", ink: "#FFFFFF", order: 4 },
  {
    id: "hammersmith-city",
    name: "Hammersmith & City",
    colour: "#F3A9BB",
    ink: "#111111",
    order: 5,
  },
  { id: "jubilee", name: "Jubilee", colour: "#A0A5A9", ink: "#111111", order: 6 },
  {
    id: "metropolitan",
    name: "Metropolitan",
    colour: "#9B0056",
    ink: "#FFFFFF",
    order: 7,
  },
  { id: "northern", name: "Northern", colour: "#000000", ink: "#FFFFFF", order: 8 },
  {
    id: "piccadilly",
    name: "Piccadilly",
    colour: "#003688",
    ink: "#FFFFFF",
    order: 9,
  },
  { id: "victoria", name: "Victoria", colour: "#0098D4", ink: "#FFFFFF", order: 10 },
  {
    id: "waterloo-city",
    name: "Waterloo & City",
    colour: "#95CDBA",
    ink: "#111111",
    order: 11,
  },
  {
    id: "elizabeth",
    name: "Elizabeth",
    colour: "#6950A1",
    ink: "#FFFFFF",
    order: 12,
  },
  { id: "dlr", name: "DLR", colour: "#00A4A7", ink: "#FFFFFF", order: 13 },
  {
    id: "london-overground",
    name: "London Overground",
    colour: "#EE7C0E",
    ink: "#FFFFFF",
    order: 14,
  },
  { id: "tram", name: "Tram", colour: "#84B817", ink: "#111111", order: 15 },
];

const BY_ID = new Map(LINES.map((l) => [l.id, l] as const));

export function lineMeta(lineId: string): LineMeta {
  return (
    BY_ID.get(lineId) ?? {
      id: lineId,
      name: lineId.replace(/-/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()),
      colour: "#555555",
      ink: "#FFFFFF",
      order: 99,
    }
  );
}

export function allLinesInOrder(): LineMeta[] {
  return [...LINES];
}

// Coarse bucket for the status badge. `status_severity` values come from the
// TfL API; 10 is "Good Service", 9 is "Minor Delays", lower values get
// progressively worse and higher values (19-20) represent planned closures.
export type StatusTone = "good" | "minor" | "major" | "severe" | "planned" | "unknown";

export function statusTone(severity: number | null | undefined): StatusTone {
  if (severity === null || severity === undefined) return "unknown";
  if (severity === 10) return "good";
  if (severity === 9) return "minor";
  if (severity >= 6) return "major";
  if (severity >= 19) return "planned";
  return "severe";
}

const TONE_CLASSES: Record<StatusTone, string> = {
  good: "bg-emerald-100 text-emerald-800 ring-emerald-200",
  minor: "bg-amber-100 text-amber-800 ring-amber-200",
  major: "bg-orange-100 text-orange-800 ring-orange-200",
  severe: "bg-rose-100 text-rose-800 ring-rose-200",
  planned: "bg-sky-100 text-sky-800 ring-sky-200",
  unknown: "bg-gray-100 text-gray-700 ring-gray-200",
};

export function toneClasses(tone: StatusTone): string {
  return TONE_CLASSES[tone];
}
