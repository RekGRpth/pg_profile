CREATE FUNCTION cluster_stat_lock(IN sserver_id integer,
  IN start_id integer, IN end_id integer)
RETURNS TABLE(
  locktype            text,
  waits               bigint,
  wait_time           bigint,
  fastpath_exceeded   bigint
)
SET search_path=@extschema@ AS $$
  SELECT
    locktype,
    SUM(waits)::bigint AS waits,
    SUM(wait_time)::bigint AS wait_time,
    SUM(fastpath_exceeded)::bigint AS fastpath_exceeded
  FROM sample_stat_lock
  WHERE server_id = sserver_id AND sample_id BETWEEN start_id + 1 AND end_id
  GROUP BY locktype;
$$ LANGUAGE sql;

CREATE FUNCTION cluster_stat_lock_format(IN sserver_id integer,
  IN start_id integer, IN end_id integer)
RETURNS TABLE(
  locktype                text,
  waits                   bigint,
  waits_pct               numeric,
  wait_time               bigint,
  wait_time_pct           numeric,
  fastpath_exceeded       bigint,
  fastpath_exceeded_pct   numeric,
  ord_locktype            integer
) SET search_path=@extschema@ AS $$
  WITH
    tot AS (
      SELECT
        sum(waits) AS waits,
        sum(wait_time) AS wait_time,
        sum(fastpath_exceeded) AS fastpath_exceeded
      FROM cluster_stat_lock(sserver_id, start_id, end_id)
    )
  SELECT
    COALESCE(csl.locktype, 'Total') AS locktype,
    NULLIF(SUM(csl.waits), 0)::bigint AS waits,
    round(sum(csl.waits) * 100 / NULLIF(min(tot.waits), 0), 2) AS waits_pct,
    NULLIF(SUM(csl.wait_time), 0)::bigint AS wait_time,
    round(sum(csl.wait_time) * 100 / NULLIF(min(tot.wait_time), 0), 2) AS wait_time_pct,
    NULLIF(SUM(csl.fastpath_exceeded), 0)::bigint AS fastpath_exceeded,
    round(sum(csl.fastpath_exceeded) * 100 / NULLIF(min(tot.fastpath_exceeded), 0), 2) AS fastpath_exceeded_pct,
    row_number() OVER (ORDER BY NULLIF(csl.locktype, 'Total') ASC NULLS LAST) as ord_locktype
  FROM cluster_stat_lock(sserver_id, start_id, end_id) csl
    CROSS JOIN tot
  GROUP BY ROLLUP (csl.locktype);
$$ LANGUAGE sql;

CREATE FUNCTION cluster_stat_lock_format(IN sserver_id integer,
  IN start1_id integer, IN end1_id integer,
  IN start2_id integer, IN end2_id integer)
RETURNS TABLE(
  locktype                text,
  waits1                  bigint,
  waits_pct1              numeric,
  wait_time1              bigint,
  wait_time_pct1          numeric,
  fastpath_exceeded1      bigint,
  fastpath_exceeded_pct1  numeric,
  waits2                  bigint,
  waits_pct2              numeric,
  wait_time2              bigint,
  wait_time_pct2          numeric,
  fastpath_exceeded2      bigint,
  fastpath_exceeded_pct2  numeric,
  ord_locktype            integer
) SET search_path=@extschema@ AS $$
  WITH
    tot1 AS (
      SELECT
        sum(waits) AS waits,
        sum(wait_time) AS wait_time,
        sum(fastpath_exceeded) AS fastpath_exceeded
      FROM cluster_stat_lock(sserver_id, start1_id, end1_id)
    ),
    tot2 AS (
      SELECT
        sum(waits) AS waits,
        sum(wait_time) AS wait_time,
        sum(fastpath_exceeded) AS fastpath_exceeded
      FROM cluster_stat_lock(sserver_id, start2_id, end2_id)
    )
  SELECT
    COALESCE(locktype, 'Total') AS locktype,
    NULLIF(SUM(csl1.waits), 0)::bigint AS waits1,
    round(sum(csl1.waits) * 100 / NULLIF(min(tot1.waits),0), 2) AS waits_pct1,
    NULLIF(SUM(csl1.wait_time), 0)::bigint AS wait_time1,
    round(sum(csl1.wait_time) * 100 / NULLIF(min(tot1.wait_time),0), 2) AS wait_time_pct1,
    NULLIF(SUM(csl1.fastpath_exceeded), 0)::bigint AS fastpath_exceeded1,
    round(sum(csl1.fastpath_exceeded) * 100 / NULLIF(min(tot1.fastpath_exceeded),0), 2) AS fastpath_exceeded_pct1,
    NULLIF(SUM(csl2.waits), 0)::bigint AS waits2,
    round(sum(csl2.waits) * 100 / NULLIF(min(tot2.waits),0), 2) AS waits_pct2,
    NULLIF(SUM(csl2.wait_time), 0)::bigint AS wait_time2,
    round(sum(csl2.wait_time) * 100 / NULLIF(min(tot2.wait_time),0), 2) AS wait_time_pct2,
    NULLIF(SUM(csl2.fastpath_exceeded), 0)::bigint AS fastpath_exceeded2,
    round(sum(csl2.fastpath_exceeded) * 100 / NULLIF(min(tot2.fastpath_exceeded),0), 2) AS fastpath_exceeded_pct2,
    row_number() OVER (ORDER BY locktype ASC NULLS LAST) as ord_locktype
  FROM (cluster_stat_lock(sserver_id, start1_id, end1_id) csl1 CROSS JOIN tot1)
    FULL JOIN (cluster_stat_lock(sserver_id, start2_id, end2_id) csl2 CROSS JOIN tot2) USING (locktype)
  GROUP BY ROLLUP(locktype)
$$ LANGUAGE sql;

CREATE FUNCTION cluster_stat_lock_reset_format(IN report_context jsonb, IN sserver_id integer,
  IN start_id integer, IN end_id integer)
RETURNS TABLE(
    sample_id     integer,
    locktype      text,
    stats_reset   timestamp with time zone,
    ord_sample    integer
) SET search_path=@extschema@ AS $$
  SELECT
    min(sample_id) AS sample_id,
    locktype,
    stats_reset,
    row_number() OVER (ORDER BY min(sample_id) ASC, locktype ASC) as ord_sample
  FROM sample_stat_lock
  WHERE
    server_id = sserver_id
    AND sample_id BETWEEN start_id AND end_id
    AND stats_reset > (report_context #>> '{report_properties,report_start1}')::timestamp with time zone
  GROUP BY locktype, stats_reset;
$$ LANGUAGE sql;

CREATE FUNCTION cluster_stat_lock_reset_format(IN report_context jsonb, IN sserver_id integer,
  IN start1_id integer, IN end1_id integer, IN start2_id integer, IN end2_id integer)
RETURNS TABLE(
    sample_id     integer,
    locktype      text,
    stats_reset   timestamp with time zone,
    ord_sample    integer
) SET search_path=@extschema@ AS $$
  SELECT
    min(sample_id) AS sample_id,
    locktype,
    stats_reset,
    row_number() OVER (ORDER BY min(sample_id) ASC, locktype ASC) as ord_sample
  FROM sample_stat_lock
  WHERE
    server_id = sserver_id
    AND (sample_id BETWEEN start1_id AND end1_id
      AND stats_reset > (report_context #>> '{report_properties,report_start1}')::timestamp with time zone
      OR sample_id BETWEEN start2_id AND end2_id
      AND stats_reset > (report_context #>> '{report_properties,report_start2}')::timestamp with time zone)
  GROUP BY locktype, stats_reset;
$$ LANGUAGE sql;
