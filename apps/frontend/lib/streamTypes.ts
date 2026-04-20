// Payload shapes for the two streams the dashboard consumes. These match
// the columns emitted by the Flink analytics / curated jobs verbatim; keep
// them in sync with `pipelines/tfl/streaming/flink-jobs/**` when evolving
// the schemas.

export interface LineStatusPayload {
  line_id: string;
  line_name: string;
  status_severity: number;
  status_description: string;
  reason: string;
  last_updated: string;
}

export interface BikeOccupancyPayload {
  bike_point_id: string;
  common_name: string;
  nb_bikes: number;
  nb_ebikes: number;
  nb_empty_docks: number;
  occupancy_pct: number;
  is_empty: boolean;
  is_full: boolean;
  event_time: string;
}

export const TOPIC_LINE_STATUS = "tfl.analytics.line-status-latest";
export const TOPIC_BIKE_OCCUPANCY = "tfl.curated.bike-occupancy";
