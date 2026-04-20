INSERT INTO analytics.cycling.bike_station_hourly
SELECT
    bike_point_id,
    common_name,
    date_trunc('hour', event_time)                          AS hour_start,
    AVG(occupancy_pct)                                      AS avg_occupancy_pct,
    MIN(available_bikes)                                    AS min_available_bikes,
    MAX(available_bikes)                                    AS max_available_bikes,
    AVG(CAST(available_bikes AS DOUBLE))                    AS avg_available_bikes,
    MAX(total_docks)                                        AS total_docks,
    SUM(CASE WHEN is_empty THEN 1 ELSE 0 END)              AS empty_count,
    SUM(CASE WHEN is_full  THEN 1 ELSE 0 END)              AS full_count,
    COUNT(*)                                                AS observation_count,
    lat,
    lon
FROM curated.cycling.bike_occupancy
WHERE event_time >= CAST('{{ data_interval_start }}' AS TIMESTAMP)
  AND event_time <  CAST('{{ data_interval_end }}'   AS TIMESTAMP)
GROUP BY bike_point_id, common_name, date_trunc('hour', event_time), lat, lon
