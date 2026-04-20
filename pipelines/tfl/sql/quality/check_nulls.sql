-- Returns count of NULL bike_point_ids in curated. Should be 0.
SELECT COUNT(*) AS null_count
FROM curated.cycling.bike_occupancy
WHERE bike_point_id IS NULL
