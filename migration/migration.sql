INSERT INTO import_queries_version_order VALUES
('pg_profile','4.15','pg_profile','4.14')
;

DELETE FROM report_struct;
DELETE FROM report;
DELETE FROM report_static;

DELETE FROM sample_stat_activity_cnt ss
WHERE (ss.server_id, ss.sample_id) NOT IN (
  SELECT server_id, sample_id FROM samples
);

ALTER TABLE sample_stat_activity_cnt
  ADD CONSTRAINT subsample_sa_cnt_servers FOREIGN KEY (server_id, sample_id)
    REFERENCES samples (server_id, sample_id) ON DELETE CASCADE
    DEFERRABLE INITIALLY IMMEDIATE;
