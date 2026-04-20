INSERT INTO curated.cycling.bike_occupancy
SELECT
    bike_point_id,
    common_name,
    total_docks,
    available_bikes,
    available_ebikes,
    CAST(available_bikes AS DOUBLE) / NULLIF(total_docks, 0) * 100 AS occupancy_pct,
    (available_bikes = 0) AS is_empty,
    (available_bikes = total_docks) AS is_full,
    CASE
        WHEN CAST(available_bikes AS DOUBLE) / NULLIF(total_docks, 0) < 0.1 THEN 'critical'
        WHEN CAST(available_bikes AS DOUBLE) / NULLIF(total_docks, 0) < 0.3 THEN 'low'
        WHEN CAST(available_bikes AS DOUBLE) / NULLIF(total_docks, 0) > 0.9 THEN 'full'
        ELSE 'normal'
    END AS availability_status,
    lat,
    lon,
    event_time
FROM raw.cycling.bike_occupancy
WHERE event_time >= CAST('{{ data_interval_start }}' AS TIMESTAMP)
  AND event_time <  CAST('{{ data_interval_end }}'   AS TIMESTAMP)
  AND total_docks > 0
  AND available_bikes >= 0
  AND available_bikes <= total_docks
