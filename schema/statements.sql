/* === Statements history tables ==== */
CREATE TABLE stmt_list(
    server_id      integer NOT NULL REFERENCES servers(server_id) ON DELETE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE,
    queryid_md5    char(32),
    query          text,
    last_sample_id integer,
    CONSTRAINT pk_stmt_list PRIMARY KEY (server_id, queryid_md5),
    CONSTRAINT fk_stmt_list_samples FOREIGN KEY (server_id, last_sample_id)
      REFERENCES samples (server_id, sample_id) ON DELETE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX ix_stmt_list_smp ON stmt_list(server_id, last_sample_id);
COMMENT ON TABLE stmt_list IS 'Statements, captured in samples';

CREATE TABLE sample_statements (
    server_id           integer,
    sample_id           integer,
    userid              oid,
    datid               oid,
    queryid             bigint,
    queryid_md5         char(32),
    plans               bigint,
    total_plan_time     double precision,
    min_plan_time       double precision,
    max_plan_time       double precision,
    mean_plan_time      double precision,
    sum_plan_time_sq    numeric, -- sum of plan times squared for stddev calculation
    calls               bigint,
    total_exec_time     double precision,
    min_exec_time       double precision,
    max_exec_time       double precision,
    mean_exec_time      double precision,
    sum_exec_time_sq    numeric, -- sum of exec times squared for stddev calculation
    rows                bigint,
    shared_blks_hit     bigint,
    shared_blks_read    bigint,
    shared_blks_dirtied bigint,
    shared_blks_written bigint,
    local_blks_hit      bigint,
    local_blks_read     bigint,
    local_blks_dirtied  bigint,
    local_blks_written  bigint,
    temp_blks_read      bigint,
    temp_blks_written   bigint,
    shared_blk_read_time  double precision,
    shared_blk_write_time double precision,
    wal_records         bigint,
    wal_fpi             bigint,
    wal_bytes           numeric,
    toplevel            boolean,
    jit_functions       bigint,
    jit_generation_time double precision,
    jit_inlining_count  bigint,
    jit_inlining_time   double precision,
    jit_optimization_count  bigint,
    jit_optimization_time   double precision,
    jit_emission_count  bigint,
    jit_emission_time   double precision,
    temp_blk_read_time  double precision,
    temp_blk_write_time double precision,
    local_blk_read_time double precision,
    local_blk_write_time  double precision,
    jit_deform_count    bigint,
    jit_deform_time     double precision,
    stats_since         timestamp with time zone,
    minmax_stats_since  timestamp with time zone,
    CONSTRAINT pk_sample_statements_n PRIMARY KEY (server_id, sample_id, datid, userid, queryid, toplevel),
    CONSTRAINT fk_stmt_list FOREIGN KEY (server_id,queryid_md5)
      REFERENCES stmt_list (server_id,queryid_md5)
      ON DELETE NO ACTION ON UPDATE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT fk_statments_dat FOREIGN KEY (server_id, sample_id, datid)
      REFERENCES sample_stat_database(server_id, sample_id, datid) ON DELETE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT fk_statements_roles FOREIGN KEY (server_id, userid)
      REFERENCES roles_list (server_id, userid)
      ON DELETE NO ACTION ON UPDATE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE
);
CREATE INDEX ix_sample_stmts_qid ON sample_statements (server_id,queryid_md5);
CREATE INDEX ix_sample_stmts_rol ON sample_statements (server_id, userid);
COMMENT ON TABLE sample_statements IS 'Sample statement statistics table (fields from pg_stat_statements)';

CREATE TABLE last_stat_statements (
    server_id           integer,
    sample_id           integer,
    userid              oid,
    username            name,
    datid               oid,
    queryid             bigint,
    queryid_md5         char(32),
    plans               bigint,
    total_plan_time     double precision,
    min_plan_time       double precision,
    max_plan_time       double precision,
    mean_plan_time      double precision,
    stddev_plan_time    double precision,
    calls               bigint,
    total_exec_time     double precision,
    min_exec_time       double precision,
    max_exec_time       double precision,
    mean_exec_time      double precision,
    stddev_exec_time    double precision,
    rows                bigint,
    shared_blks_hit     bigint,
    shared_blks_read    bigint,
    shared_blks_dirtied bigint,
    shared_blks_written bigint,
    local_blks_hit      bigint,
    local_blks_read     bigint,
    local_blks_dirtied  bigint,
    local_blks_written  bigint,
    temp_blks_read      bigint,
    temp_blks_written   bigint,
    shared_blk_read_time  double precision,
    shared_blk_write_time double precision,
    wal_records         bigint,
    wal_fpi             bigint,
    wal_bytes           numeric,
    toplevel            boolean,
    in_sample           boolean DEFAULT false,
    jit_functions       bigint,
    jit_generation_time double precision,
    jit_inlining_count  bigint,
    jit_inlining_time   double precision,
    jit_optimization_count  bigint,
    jit_optimization_time   double precision,
    jit_emission_count  bigint,
    jit_emission_time   double precision,
    temp_blk_read_time  double precision,
    temp_blk_write_time double precision,
    local_blk_read_time double precision,
    local_blk_write_time  double precision,
    jit_deform_count    bigint,
    jit_deform_time     double precision,
    stats_since         timestamp with time zone,
    minmax_stats_since  timestamp with time zone
)
PARTITION BY LIST (server_id);

CREATE TABLE sample_statements_total (
    server_id           integer,
    sample_id           integer,
    datid               oid,
    plans               bigint,
    total_plan_time     double precision,
    calls               bigint,
    total_exec_time     double precision,
    rows                bigint,
    shared_blks_hit     bigint,
    shared_blks_read    bigint,
    shared_blks_dirtied bigint,
    shared_blks_written bigint,
    local_blks_hit      bigint,
    local_blks_read     bigint,
    local_blks_dirtied  bigint,
    local_blks_written  bigint,
    temp_blks_read      bigint,
    temp_blks_written   bigint,
    shared_blk_read_time  double precision,
    shared_blk_write_time double precision,
    wal_records         bigint,
    wal_fpi             bigint,
    wal_bytes           numeric,
    statements          bigint,
    jit_functions       bigint,
    jit_generation_time double precision,
    jit_inlining_count  bigint,
    jit_inlining_time   double precision,
    jit_optimization_count  bigint,
    jit_optimization_time   double precision,
    jit_emission_count  bigint,
    jit_emission_time   double precision,
    temp_blk_read_time  double precision,
    temp_blk_write_time double precision,
    mean_max_plan_time  double precision,
    mean_max_exec_time  double precision,
    mean_min_plan_time  double precision,
    mean_min_exec_time  double precision,
    local_blk_read_time double precision,
    local_blk_write_time  double precision,
    jit_deform_count    bigint,
    jit_deform_time     double precision,
    CONSTRAINT pk_sample_statements_total PRIMARY KEY (server_id, sample_id, datid),
    CONSTRAINT fk_statments_t_dat FOREIGN KEY (server_id, sample_id, datid)
      REFERENCES sample_stat_database(server_id, sample_id, datid) ON DELETE CASCADE
      DEFERRABLE INITIALLY IMMEDIATE
);
COMMENT ON TABLE sample_statements_total IS 'Aggregated stats for sample, based on pg_stat_statements';
