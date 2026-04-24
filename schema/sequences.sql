/* ==== Sequences stats tables ==== */
CREATE TABLE sequences_list(
    server_id       integer NOT NULL,
    datid           oid NOT NULL,
    relid           oid NOT NULL,
    schemaname      name NOT NULL,
    relname         name NOT NULL,
    last_sample_id  integer,
    CONSTRAINT pk_sequences_list PRIMARY KEY (server_id, datid, relid),
    CONSTRAINT fk_sequences_list_samples FOREIGN KEY (server_id, last_sample_id)
      REFERENCES samples (server_id, sample_id) ON DELETE CASCADE
        DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX ix_sequences_list_smp ON indexes_list(server_id, last_sample_id);

COMMENT ON TABLE sequences_list IS 'Sequence names and schemas, captured in samples';

CREATE TABLE last_stat_sequences (
    server_id           integer,
    sample_id           integer,
    datid               oid,
    relid               oid NOT NULL,
    tablespaceid        oid NOT NULL,
    schemaname          name,
    relname             name,
    blks_read           bigint,
    blks_hit            bigint,
    stats_reset         timestamp with time zone,
    in_sample           BOOLEAN DEFAULT FALSE NOT NULL
)
PARTITION BY LIST (server_id);
COMMENT ON TABLE last_stat_sequences IS 'Last sample data for calculating diffs in next sample';

CREATE TABLE sample_stat_sequences (
    server_id           integer,
    sample_id           integer,
    datid               oid,
    relid               oid,
    tablespaceid        oid NOT NULL,
    blks_read           bigint,
    blks_hit            bigint,
    CONSTRAINT fk_stat_sequences_sequences FOREIGN KEY (server_id, datid, relid)
      REFERENCES sequences_list(server_id, datid, relid)
      ON DELETE NO ACTION ON UPDATE RESTRICT
      DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT fk_stat_sequences_dat FOREIGN KEY (server_id, sample_id, datid)
      REFERENCES sample_stat_database(server_id, sample_id, datid) ON DELETE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT fk_stat_sequences_tablespaces FOREIGN KEY (server_id, sample_id, tablespaceid)
      REFERENCES sample_stat_tablespaces(server_id, sample_id, tablespaceid)
      ON DELETE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT pk_sample_stat_sequences PRIMARY KEY (server_id, sample_id, datid, relid)
);
CREATE INDEX ix_sample_stat_sequences_sl ON sample_stat_sequences(server_id, datid, relid);
CREATE INDEX ix_sample_stat_sequences_ts ON sample_stat_sequences(server_id, sample_id, tablespaceid);

COMMENT ON TABLE sample_stat_sequences IS 'Stats increments for user sequences in all databases by samples';