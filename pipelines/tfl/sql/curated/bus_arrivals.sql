INSERT INTO curated.bus.arrivals
SELECT
    arrival_id,
    stop_id,
    station_name,
    line_name,
    destination_name,
    time_to_station,
    CAST(expected_arrival AS TIMESTAMP) AS expected_arrival,
    CASE
        WHEN time_to_station <= 60  THEN 'due'
        WHEN time_to_station <= 300 THEN 'arriving'
        ELSE 'scheduled'
    END AS arrival_status,
    event_time
FROM raw.bus.arrivals
WHERE event_time >= CAST('{{ data_interval_start }}' AS TIMESTAMP)
  AND event_time <  CAST('{{ data_interval_end }}'   AS TIMESTAMP)
  AND arrival_id IS NOT NULL
