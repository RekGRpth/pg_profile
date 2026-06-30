/* ===== Sequences stats functions ===== */

CREATE FUNCTION top_sequences(IN sserver_id integer, IN start_id integer, IN end_id integer)
RETURNS TABLE(
  datid               oid,
  relid               oid,
  dbname              name,
  tablespacename      name,
  schemaname          name,
  relname             name,
  blks_fetch          bigint,
  blks_fetch_pct      numeric,
  blks_read           bigint,
  blks_read_pct       numeric,
  hit_pct             numeric
)
SET search_path=@extschema@ AS $$
  WITH
    total AS (
      SELECT
        COALESCE(sum(blks_read), 0)AS blks_read,
        COALESCE(sum(blks_hit), 0) + COALESCE(sum(blks_read), 0) AS blks_fetch
      FROM sample_stat_sequences
      WHERE server_id = sserver_id AND sample_id BETWEEN start_id + 1 AND end_id
    )
  SELECT
    sss.datid,
    sss.relid,
    ssd.datname AS dbname,
    tl.tablespacename,
    sl.schemaname,
    sl.relname,
    COALESCE(sum(sss.blks_hit), 0)::bigint + COALESCE(sum(sss.blks_read), 0)::bigint AS blks_fetch,
    (COALESCE(sum(sss.blks_hit), 0) + COALESCE(sum(sss.blks_read), 0)) * 100 /
      NULLIF(min(total.blks_fetch), 0) AS blks_fetch_pct,
    COALESCE(sum(sss.blks_read), 0)::bigint AS blks_read,
    COALESCE(sum(sss.blks_read), 0) * 100 / NULLIF(min(total.blks_read), 0) AS blks_read_pct,
    COALESCE(sum(sss.blks_hit), 0) * 100 / NULLIF(COALESCE(sum(sss.blks_hit), 0) + COALESCE(sum(sss.blks_read), 0), 0) AS hit_pct
  FROM sample_stat_sequences sss
    JOIN sample_stat_database ssd USING (server_id, sample_id, datid)
    JOIN tablespaces_list tl ON (tl.server_id, tl.tablespaceid) = (sss.server_id, sss.tablespaceid)
    JOIN sequences_list sl ON (sl.server_id, sl.relid) = (sss.server_id, sss.relid)
    CROSS JOIN total
  WHERE sss.server_id=sserver_id AND sss.sample_id BETWEEN start_id + 1 AND end_id
  GROUP BY sss.datid, sss.relid, ssd.datname, tl.tablespacename, sl.schemaname, sl.relname;
$$ LANGUAGE sql;

CREATE FUNCTION top_sequences_format(IN sserver_id integer, IN start_id integer, IN end_id integer)
RETURNS TABLE(
  datid               oid,
  relid               oid,
  dbname              name,
  tablespacename      name,
  schemaname          name,
  relname             name,
  blks_fetch          bigint,
  blks_fetch_pct      numeric,
  blks_read           bigint,
  blks_read_pct       numeric,
  hit_pct             numeric,
  ord_fetch           integer,
  ord_read            integer
  )
SET search_path=@extschema@ AS $$
  SELECT
    ts.datid,
    ts.relid,
    ts.dbname,
    ts.tablespacename,
    ts.schemaname,
    ts.relname,
    NULLIF(ts.blks_fetch, 0) as blks_fetch,
    round(NULLIF(ts.blks_fetch_pct, 0.0), 2) as blks_fetch_pct,
    NULLIF(ts.blks_read, 0) as blks_read,
    round(NULLIF(ts.blks_read_pct, 0.0), 2) as blks_read_pct,
    round(NULLIF(ts.hit_pct, 0.0), 2) as hit_pct,
    row_number() OVER (ORDER BY ts.blks_fetch DESC NULLS LAST, ts.datid, ts.relid)::integer AS ord_fetch,
    row_number() OVER (ORDER BY ts.blks_read DESC NULLS LAST, ts.datid, ts.relid)::integer AS blks_read
  FROM top_sequences(sserver_id, start_id, end_id) ts;
$$ LANGUAGE sql;

CREATE FUNCTION top_sequences_format(IN sserver_id integer,
  IN start1_id integer, IN end1_id integer,
  IN start2_id integer, IN end2_id integer)
RETURNS TABLE(
  datid               oid,
  relid               oid,
  dbname              name,
  tablespacename      name,
  schemaname          name,
  relname             name,
  blks_fetch1         bigint,
  blks_fetch_pct1     numeric,
  blks_read1          bigint,
  blks_read_pct1      numeric,
  hit_pct1            numeric,
  blks_fetch2         bigint,
  blks_fetch_pct2     numeric,
  blks_read2          bigint,
  blks_read_pct2      numeric,
  hit_pct2            numeric,
  ord_fetch           integer,
  ord_read            integer
  )
SET search_path=@extschema@ AS $$
  SELECT
    COALESCE(ts1.datid, ts2.datid) AS datid,
    COALESCE(ts1.relid, ts2.relid) AS relid,
    COALESCE(ts1.dbname, ts2.dbname) AS dbname,
    COALESCE(ts1.tablespacename, ts2.tablespacename) AS tablespacename,
    COALESCE(ts1.schemaname, ts2.schemaname) AS schemaname,
    COALESCE(ts1.relname, ts2.relname) AS relname,
    NULLIF(ts1.blks_fetch, 0) as blks_fetch1,
    round(NULLIF(ts1.blks_fetch_pct, 0.0), 2) as blks_fetch_pct1,
    NULLIF(ts1.blks_read, 0) as blks_read1,
    round(NULLIF(ts1.blks_read_pct, 0.0), 2) as blks_read_pct1,
    round(NULLIF(ts1.hit_pct, 0.0), 2) as hit_pct1,
    NULLIF(ts2.blks_fetch, 0) as blks_fetch2,
    round(NULLIF(ts2.blks_fetch_pct, 0.0), 2) as blks_fetch_pct2,
    NULLIF(ts2.blks_read, 0) as blks_read2,
    round(NULLIF(ts2.blks_read_pct, 0.0), 2) as blks_read_pct2,
    round(NULLIF(ts2.hit_pct, 0.0), 2) as hit_pct2,
    row_number() OVER (ORDER BY COALESCE(ts1.blks_fetch, 0) + COALESCE(ts2.blks_fetch, 0) DESC NULLS LAST,
      COALESCE(ts1.datid, ts2.datid), COALESCE(ts1.relid, ts2.relid))::integer AS ord_fetch,
    row_number() OVER (ORDER BY COALESCE(ts1.blks_read, 0) + COALESCE(ts2.blks_read, 0) DESC NULLS LAST,
      COALESCE(ts1.datid, ts2.datid), COALESCE(ts1.relid, ts2.relid))::integer AS blks_read
  FROM top_sequences(sserver_id, start1_id, end1_id) ts1
    FULL OUTER JOIN top_sequences(sserver_id, start2_id, end2_id) ts2 USING (datid, relid);
$$ LANGUAGE sql;
