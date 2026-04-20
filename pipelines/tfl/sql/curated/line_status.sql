INSERT INTO curated.tube.line_status
SELECT
    line_id,
    line_name,
    status,
    reason,
    CASE
        WHEN status = 'Good Service' THEN 'green'
        WHEN status IN ('Minor Delays', 'Reduced Service') THEN 'amber'
        ELSE 'red'
    END AS severity,
    event_time
FROM raw.tube.line_status
WHERE event_time >= CAST('{{ data_interval_start }}' AS TIMESTAMP)
  AND event_time <  CAST('{{ data_interval_end }}'   AS TIMESTAMP)
  AND line_id IS NOT NULL
