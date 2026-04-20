-- Returns count of distinct stations in the latest batch.
-- Alert if significantly below expected ~800 Santander Cycles stations.
SELECT COUNT(DISTINCT bike_point_id) AS station_count
FROM curated.cycling.bike_occupancy
WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '24' HOUR
