CREATE FUNCTION calculate_lock_stats(IN sserver_id integer, IN ssample_id integer
) RETURNS void AS $$
-- Calc SLRU stat diff
INSERT INTO sample_stat_lock(
    server_id,
    sample_id,
    locktype,
    waits,
    wait_time,
    fastpath_exceeded,
    stats_reset
)
SELECT
    cur.server_id,
    cur.sample_id,
    cur.locktype,
    cur.waits - COALESCE(lst.waits, 0),
    cur.wait_time - COALESCE(lst.wait_time, 0),
    cur.fastpath_exceeded - COALESCE(lst.fastpath_exceeded, 0),
    cur.stats_reset
FROM last_stat_lock cur
LEFT OUTER JOIN last_stat_lock lst ON
  (lst.server_id, lst.sample_id, lst.locktype) =
  (sserver_id, ssample_id - 1, cur.locktype)
  AND cur.stats_reset IS NOT DISTINCT FROM lst.stats_reset
WHERE
  (cur.server_id, cur.sample_id) = (sserver_id, ssample_id) AND
  GREATEST(
    cur.waits - COALESCE(lst.waits, 0),
    cur.wait_time - COALESCE(lst.wait_time, 0),
    cur.fastpath_exceeded - COALESCE(lst.fastpath_exceeded, 0)
  ) > 0;

DELETE FROM last_stat_lock WHERE server_id = sserver_id AND sample_id != ssample_id;
$$ LANGUAGE sql;