INSERT INTO import_queries_version_order VALUES
('pg_profile','4.14','pg_profile','4.11')
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

ALTER TABLE last_stat_statements
  ADD COLUMN generic_plan_calls  bigint,
  ADD COLUMN custom_plan_calls   bigint;

ALTER TABLE sample_statements
  ADD COLUMN generic_plan_calls  bigint,
  ADD COLUMN custom_plan_calls   bigint;

ALTER TABLE last_stat_wal
  ADD COLUMN wal_fpi_bytes numeric;

ALTER TABLE sample_stat_wal
  ADD COLUMN wal_fpi_bytes numeric;

ALTER TABLE last_stat_tables
  ADD COLUMN stats_reset timestamp with time zone;

ALTER TABLE last_stat_indexes
  ADD COLUMN stats_reset timestamp with time zone;

ALTER TABLE last_stat_user_functions
  ADD COLUMN stats_reset timestamp with time zone;

ALTER TABLE sample_stat_activity_cnt
    RENAME COLUMN bufferpin to buffer;

ALTER TABLE last_stat_activity_count
    RENAME COLUMN bufferpin to buffer;

CREATE TABLE sample_stat_lock
(
    server_id                 integer,
    sample_id                 integer,
    locktype                  text,
    waits                     bigint,
    wait_time                 bigint,
    fastpath_exceeded         bigint,
    stats_reset               timestamp with time zone,
    CONSTRAINT fk_sample_stat_lock_samples FOREIGN KEY (server_id, sample_id)
      REFERENCES samples (server_id, sample_id) ON DELETE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT pk_sample_stat_lock PRIMARY KEY (server_id, sample_id, locktype)
);
COMMENT ON TABLE sample_stat_lock IS 'Sample locks statistics table (fields from pg_stat_lock)';

CREATE TABLE last_stat_lock(LIKE sample_stat_lock);
ALTER TABLE last_stat_lock ADD CONSTRAINT pk_last_stat_lock
  PRIMARY KEY (server_id, sample_id, locktype);
ALTER TABLE last_stat_lock ADD CONSTRAINT fk_last_stat_lock_samples
  FOREIGN KEY (server_id, sample_id) REFERENCES samples(server_id, sample_id) ON DELETE RESTRICT
    DEFERRABLE INITIALLY IMMEDIATE;
COMMENT ON TABLE last_stat_lock IS 'Last sample data for calculating diffs in next sample';

GRANT SELECT ON sequences_list TO public;
GRANT SELECT ON sample_stat_sequences TO public;
GRANT SELECT ON sample_stat_lock TO public;

DO
$$
  DECLARE
    rec RECORD;
  BEGIN
    FOR rec IN (SELECT server_id FROM servers) LOOP
      EXECUTE format(
        'CREATE TABLE last_stat_sequences_srv%1$s PARTITION OF last_stat_sequences '
        'FOR VALUES IN (%1$s)',
        rec.server_id);
      EXECUTE format(
        'ALTER TABLE last_stat_sequences_srv%1$s '
        'ADD CONSTRAINT pk_last_stat_sequences_srv%1$s '
          'PRIMARY KEY (server_id, sample_id, datid, relid), '
        'ADD CONSTRAINT fk_last_stat_sequences_dat_srv%1$s '
          'FOREIGN KEY (server_id, sample_id, datid) '
          'REFERENCES sample_stat_database(server_id, sample_id, datid) ON DELETE RESTRICT',
        rec.server_id);
    END LOOP;
  END;
$$ LANGUAGE plpgsql;
