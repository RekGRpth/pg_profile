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