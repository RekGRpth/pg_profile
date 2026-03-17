INSERT INTO import_queries_version_order VALUES
('pg_profile','4.13','pg_profile','4.11')
;

DELETE FROM report_struct;
DELETE FROM report;
DELETE FROM report_static;

DO
$$
  DECLARE
    rec RECORD;
  BEGIN
    FOR rec IN (SELECT server_id FROM servers) LOOP
      EXECUTE format(
        'CREATE UNIQUE INDEX ix_last_stat_tables_srv%1$s_toast ON last_stat_tables_srv%1$s '
        '(sample_id, datid, reltoastrelid) WHERE reltoastrelid IS NOT NULL',
        rec.server_id);
    END LOOP;
  END;
$$ LANGUAGE plpgsql;

DROP VIEW v_sample_timings;

ALTER TABLE sample_timings
    ALTER COLUMN event_ts TYPE timestamp with time zone USING event_ts::timestamp with time zone;

CREATE VIEW v_sample_timings AS
SELECT
  srv.server_name,
  smp.sample_id,
  smp.sample_time,
  tm.event as sampling_event,
  tm.exec_point,
  tm.event_ts
FROM
  sample_timings tm
  JOIN servers srv USING (server_id)
  JOIN samples smp USING (server_id, sample_id);
COMMENT ON VIEW v_sample_timings IS 'Sample taking time statistics with server names and sample times';
GRANT SELECT ON v_sample_timings TO public;