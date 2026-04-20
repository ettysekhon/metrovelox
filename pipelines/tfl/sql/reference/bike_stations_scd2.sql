-- SCD Type 2: expire changed rows, then insert new versions.
-- Requires staging.cycling.bike_stations_incoming to be populated first.

-- Step 1: Expire rows where tracked columns changed
UPDATE reference.cycling.bike_stations target
SET _valid_until = CURRENT_TIMESTAMP,
    _is_current = false
WHERE target._is_current = true
  AND EXISTS (
    SELECT 1 FROM staging.cycling.bike_stations_incoming src
    WHERE src.bike_point_id = target.bike_point_id
      AND (
          src.common_name != target.common_name
          OR src.total_docks != target.total_docks
          OR src.lat != target.lat
          OR src.lon != target.lon
      )
  );

-- Step 2: Insert new versions for changed rows + brand new rows
INSERT INTO reference.cycling.bike_stations
    (bike_point_id, common_name, total_docks, lat, lon, _valid_from, _valid_until, _is_current)
SELECT
    src.bike_point_id,
    src.common_name,
    src.total_docks,
    src.lat,
    src.lon,
    CURRENT_TIMESTAMP AS _valid_from,
    TIMESTAMP '9999-12-31 00:00:00' AS _valid_until,
    true AS _is_current
FROM staging.cycling.bike_stations_incoming src
WHERE NOT EXISTS (
    SELECT 1 FROM reference.cycling.bike_stations target
    WHERE target.bike_point_id = src.bike_point_id
      AND target._is_current = true
      AND target.common_name = src.common_name
      AND target.total_docks = src.total_docks
      AND target.lat = src.lat
      AND target.lon = src.lon
)
