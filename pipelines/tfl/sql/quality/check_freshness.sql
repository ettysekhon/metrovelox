-- Returns count of recent curated rows. If 0, data is stale.
SELECT COUNT(*) AS fresh_rows
FROM curated.cycling.bike_occupancy
WHERE event_time > CURRENT_TIMESTAMP - INTERVAL '2' HOUR
