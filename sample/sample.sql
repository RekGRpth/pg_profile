/* ========= Sample functions ========= */

CREATE FUNCTION take_sample(IN sserver_id integer, IN skip_sizes boolean
) RETURNS integer SET search_path=@extschema@ AS $$
DECLARE
    s_id              integer;
    topn              integer;
    ret               integer;
    server_properties jsonb = '{"extensions":[],"settings":[],"timings":{}}'; -- version, extensions, etc.
    qres              record;
    server_connstr    text;
    settings_refresh  boolean = true;
    collect_timings   boolean = false;

    server_query      text;
    server_host       text = NULL;
BEGIN
    -- Get server connstr
    server_connstr := get_connstr(sserver_id);
    /*
     When host= parameter is not specified, connection to unix socket is assumed.
     Unix socket can be in non-default location, so we need to specify it
    */
    IF (SELECT count(*) = 0 FROM regexp_matches(server_connstr,$o$((\s|^)host\s*=)$o$)) AND
      (SELECT count(*) != 0 FROM pg_catalog.pg_settings
      WHERE name = 'unix_socket_directories' AND boot_val != reset_val)
    THEN
      -- Get suitable socket name from available list
      server_host := (SELECT COALESCE(t[1],t[4])
        FROM pg_catalog.pg_settings,
          regexp_matches(reset_val,'("(("")|[^"])+")|([^,]+)','g') AS t
        WHERE name = 'unix_socket_directories' AND boot_val != reset_val
          -- libpq can't handle sockets with comma in their names
          AND position(',' IN COALESCE(t[1],t[4])) = 0
        LIMIT 1
      );
      -- quoted string processing
      IF starts_with(server_host,'"') AND
         starts_with(reverse(server_host),'"') AND
         (length(server_host) > 1)
      THEN
        server_host := replace(substring(server_host,2,length(server_host)-2),'""','"');
      END IF;
      -- append host parameter to the connection string
      IF server_host IS NOT NULL AND server_host != '' THEN
        server_connstr := concat_ws(server_connstr, format('host=%L',server_host), ' ');
      ELSE
        server_connstr := concat_ws(server_connstr, format('host=%L','localhost'), ' ');
      END IF;
    END IF;

    -- Getting timing collection setting
    BEGIN
        collect_timings := current_setting('{pg_profile}.track_sample_timings')::boolean;
    EXCEPTION
        WHEN OTHERS THEN collect_timings := false;
    END;

    server_properties := jsonb_set(server_properties,'{collect_timings}',to_jsonb(collect_timings));

    -- Getting TopN setting
    BEGIN
        topn := current_setting('{pg_profile}.topn')::integer;
    EXCEPTION
        WHEN OTHERS THEN topn := 20;
    END;


    -- Adding dblink extension schema to search_path if it does not already there
    IF (SELECT count(*) = 0 FROM pg_catalog.pg_extension WHERE extname = 'dblink') THEN
      RAISE 'dblink extension must be installed';
    END IF;
    SELECT extnamespace::regnamespace AS dblink_schema INTO STRICT qres FROM pg_catalog.pg_extension WHERE extname = 'dblink';
    IF NOT string_to_array(current_setting('search_path'),',') @> ARRAY[qres.dblink_schema::text] THEN
      EXECUTE 'SET LOCAL search_path TO ' || current_setting('search_path')||','|| qres.dblink_schema;
    END IF;

    IF dblink_get_connections() @> ARRAY['server_connection'] THEN
        PERFORM dblink_disconnect('server_connection');
    END IF;

    -- Creating a new sample record
    UPDATE servers SET last_sample_id = last_sample_id + 1 WHERE server_id = sserver_id
      RETURNING last_sample_id INTO s_id;
    INSERT INTO samples(sample_time,server_id,sample_id)
      VALUES (now(),sserver_id,s_id);

    -- Only one running take_sample() function allowed per server!
    -- Explicitly lock server in servers table
    BEGIN
        SELECT * INTO qres FROM servers WHERE server_id = sserver_id FOR UPDATE NOWAIT;
    EXCEPTION
        WHEN OTHERS THEN RAISE 'Can''t get lock on server. Is there another take_sample() function running on this server?';
    END;
    -- Getting max_sample_age setting
    BEGIN
        ret := COALESCE(current_setting('{pg_profile}.max_sample_age')::integer);
    EXCEPTION
        WHEN OTHERS THEN ret := 7;
    END;
    -- Applying skip sizes policy
    IF skip_sizes IS NULL THEN
      IF num_nulls(qres.size_smp_wnd_start, qres.size_smp_wnd_dur, qres.size_smp_interval) > 0 THEN
        skip_sizes = false;
      ELSE
        /*
        Skip sizes collection if there was a sample with sizes recently
        or if we are not in size collection time window
        */
        SELECT
          count(*) > 0 OR
          NOT
          CASE WHEN timezone('UTC',current_time) > timezone('UTC',qres.size_smp_wnd_start) THEN
            timezone('UTC',now()) <=
            timezone('UTC',now())::date +
            timezone('UTC',qres.size_smp_wnd_start) +
            qres.size_smp_wnd_dur
          ELSE
            timezone('UTC',now()) <=
            timezone('UTC',now() - interval '1 day')::date +
            timezone('UTC',qres.size_smp_wnd_start) +
            qres.size_smp_wnd_dur
          END
            INTO STRICT skip_sizes
        FROM
          sample_stat_tables_total st
          JOIN samples s USING (server_id, sample_id)
        WHERE
          server_id = sserver_id
          AND st.relsize_diff IS NOT NULL
          AND sample_time > now() - qres.size_smp_interval;
      END IF;
    END IF;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,connect}',jsonb_build_object('start',clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,total}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Server connection
    PERFORM dblink_connect('server_connection',server_connstr);
    -- Setting application name
    PERFORM dblink('server_connection','SET application_name=''{pg_profile}''');
    -- Setting lock_timout prevents hanging of take_sample() call due to DDL in long transaction
    PERFORM dblink('server_connection','SET lock_timeout=3000');
    -- Reset search_path for security reasons
    PERFORM dblink('server_connection','SET search_path=''''');

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,connect,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,get server environment}',jsonb_build_object('start',clock_timestamp()));
    END IF;
    -- Get settings values for the server
    FOR qres IN
      SELECT * FROM dblink('server_connection',
          'SELECT name, '
          'reset_val, '
          'unit, '
          'pending_restart '
          'FROM pg_catalog.pg_settings '
          'WHERE name IN ('
            '''server_version_num'''
          ')')
        AS dbl(name text, reset_val text, unit text, pending_restart boolean)
    LOOP
      server_properties := jsonb_insert(server_properties,'{"settings",0}',to_jsonb(qres));
    END LOOP;

    -- Get extensions, that we need to perform statements stats collection
    FOR qres IN
      SELECT * FROM dblink('server_connection',
          'SELECT extname, '
          'extnamespace::regnamespace::name AS extnamespace, '
          'extversion '
          'FROM pg_catalog.pg_extension '
          'WHERE extname IN ('
            '''pg_stat_statements'','
            '''pg_stat_kcache'''
          ')')
        AS dbl(extname name, extnamespace name, extversion text)
    LOOP
      server_properties := jsonb_insert(server_properties,'{"extensions",0}',to_jsonb(qres));
    END LOOP;

    -- Collecting postgres parameters
    /* We might refresh all parameters if version() was changed
    * This is needed for deleting obsolete parameters, not appearing in new
    * Postgres version.
    */
    SELECT ss.setting != dblver.version INTO settings_refresh
    FROM v_sample_settings ss, dblink('server_connection','SELECT version() as version') AS dblver (version text)
    WHERE ss.server_id = sserver_id AND ss.sample_id = s_id AND ss.name='version' AND ss.setting_scope = 2;
    settings_refresh := COALESCE(settings_refresh,true);

    -- Constructing server sql query for settings
    server_query := 'SELECT 1 as setting_scope,name,setting,reset_val,boot_val,unit,sourcefile,sourceline,pending_restart '
      'FROM pg_catalog.pg_settings '
      'UNION ALL SELECT 2 as setting_scope,''version'',version(),version(),NULL,NULL,NULL,NULL,False '
      'UNION ALL SELECT 2 as setting_scope,''pg_postmaster_start_time'','
      'pg_catalog.pg_postmaster_start_time()::text,'
      'pg_catalog.pg_postmaster_start_time()::text,NULL,NULL,NULL,NULL,False '
      'UNION ALL SELECT 2 as setting_scope,''pg_conf_load_time'','
      'pg_catalog.pg_conf_load_time()::text,pg_catalog.pg_conf_load_time()::text,NULL,NULL,NULL,NULL,False '
      'UNION ALL SELECT 2 as setting_scope,''system_identifier'','
      'system_identifier::text,system_identifier::text,system_identifier::text,'
      'NULL,NULL,NULL,False FROM pg_catalog.pg_control_system()';

    INSERT INTO sample_settings(
      server_id,
      first_seen,
      setting_scope,
      name,
      setting,
      reset_val,
      boot_val,
      unit,
      sourcefile,
      sourceline,
      pending_restart
    )
    SELECT
      s.server_id as server_id,
      s.sample_time as first_seen,
      cur.setting_scope,
      cur.name,
      cur.setting,
      cur.reset_val,
      cur.boot_val,
      cur.unit,
      cur.sourcefile,
      cur.sourceline,
      cur.pending_restart
    FROM
      sample_settings lst JOIN (
        -- Getting last versions of settings
        SELECT server_id, name, max(first_seen) as first_seen
        FROM sample_settings
        WHERE server_id = sserver_id AND (
          NOT settings_refresh
          -- system identifier shouldn't have a duplicate in case of version change
          -- this breaks export/import procedures, as those are related to this ID
          OR name = 'system_identifier'
        )
        GROUP BY server_id, name
      ) lst_times
      USING (server_id, name, first_seen)
      -- Getting current settings values
      RIGHT OUTER JOIN dblink('server_connection',server_query
          ) AS cur (
            setting_scope smallint,
            name text,
            setting text,
            reset_val text,
            boot_val text,
            unit text,
            sourcefile text,
            sourceline integer,
            pending_restart boolean
          )
        USING (setting_scope, name)
      JOIN samples s ON (s.server_id = sserver_id AND s.sample_id = s_id)
    WHERE
      cur.reset_val IS NOT NULL AND (
        lst.name IS NULL
        OR cur.reset_val != lst.reset_val
        OR cur.pending_restart != lst.pending_restart
        OR lst.sourcefile != cur.sourcefile
        OR lst.sourceline != cur.sourceline
        OR lst.unit != cur.unit
      );

    -- Check system identifier change
    SELECT min(reset_val::bigint) != max(reset_val::bigint) AS sysid_changed INTO STRICT qres
    FROM sample_settings
    WHERE server_id = sserver_id AND name = 'system_identifier';
    IF qres.sysid_changed THEN
      RAISE 'Server system_identifier has changed! Ensure server connection string is correct. Consider creating a new server for this cluster.';
    END IF;

    -- for server named 'local' check system identifier match
    IF (SELECT
      count(*) > 0
    FROM servers srv
      JOIN sample_settings ss USING (server_id)
      CROSS JOIN pg_catalog.pg_control_system() cs
    WHERE server_id = sserver_id AND ss.name = 'system_identifier'
      AND srv.server_name = 'local' AND reset_val::bigint != system_identifier)
    THEN
      RAISE 'Local system_identifier does not match with server specified by connection string of "local" server';
    END IF;

    INSERT INTO sample_settings(
      server_id,
      first_seen,
      setting_scope,
      name,
      setting,
      reset_val,
      boot_val,
      unit,
      sourcefile,
      sourceline,
      pending_restart
    )
    SELECT
      s.server_id,
      s.sample_time,
      1 as setting_scope,
      '{pg_profile}.topn',
      topn,
      topn,
      topn,
      null,
      null,
      null,
      false
    FROM samples s LEFT OUTER JOIN  v_sample_settings prm ON
      (s.server_id = prm.server_id AND s.sample_id = prm.sample_id AND prm.name = '{pg_profile}.topn' AND prm.setting_scope = 1)
    WHERE s.server_id = sserver_id AND s.sample_id = s_id AND (prm.setting IS NULL OR prm.setting::integer != topn);

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,get server environment,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,collect database stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Construct pg_stat_database query
    CASE
      WHEN (
        SELECT count(*) = 1 FROM jsonb_to_recordset(server_properties #> '{settings}')
          AS x(name text, reset_val text)
        WHERE name = 'server_version_num'
          AND reset_val::integer < 140000
      )
      THEN
        server_query := 'SELECT '
            'dbs.datid, '
            'dbs.datname, '
            'dbs.xact_commit, '
            'dbs.xact_rollback, '
            'dbs.blks_read, '
            'dbs.blks_hit, '
            'dbs.tup_returned, '
            'dbs.tup_fetched, '
            'dbs.tup_inserted, '
            'dbs.tup_updated, '
            'dbs.tup_deleted, '
            'dbs.conflicts, '
            'dbs.temp_files, '
            'dbs.temp_bytes, '
            'dbs.deadlocks, '
            'dbs.blk_read_time, '
            'dbs.blk_write_time, '
            'NULL as session_time, '
            'NULL as active_time, '
            'NULL as idle_in_transaction_time, '
            'NULL as sessions, '
            'NULL as sessions_abandoned, '
            'NULL as sessions_fatal, '
            'NULL as sessions_killed, '
            'dbs.stats_reset, '
            'pg_database_size(dbs.datid) as datsize, '
            '0 as datsize_delta, '
            'db.datistemplate '
          'FROM pg_catalog.pg_stat_database dbs '
          'JOIN pg_catalog.pg_database db ON (dbs.datid = db.oid) '
          'WHERE dbs.datname IS NOT NULL';
      WHEN (
        SELECT count(*) = 1 FROM jsonb_to_recordset(server_properties #> '{settings}')
          AS x(name text, reset_val text)
        WHERE name = 'server_version_num'
          AND reset_val::integer >= 140000
      )
      THEN
        server_query := 'SELECT '
            'dbs.datid, '
            'dbs.datname, '
            'dbs.xact_commit, '
            'dbs.xact_rollback, '
            'dbs.blks_read, '
            'dbs.blks_hit, '
            'dbs.tup_returned, '
            'dbs.tup_fetched, '
            'dbs.tup_inserted, '
            'dbs.tup_updated, '
            'dbs.tup_deleted, '
            'dbs.conflicts, '
            'dbs.temp_files, '
            'dbs.temp_bytes, '
            'dbs.deadlocks, '
            'dbs.blk_read_time, '
            'dbs.blk_write_time, '
            'dbs.session_time, '
            'dbs.active_time, '
            'dbs.idle_in_transaction_time, '
            'dbs.sessions, '
            'dbs.sessions_abandoned, '
            'dbs.sessions_fatal, '
            'dbs.sessions_killed, '
            'dbs.stats_reset, '
            'pg_database_size(dbs.datid) as datsize, '
            '0 as datsize_delta, '
            'db.datistemplate '
          'FROM pg_catalog.pg_stat_database dbs '
          'JOIN pg_catalog.pg_database db ON (dbs.datid = db.oid) '
          'WHERE dbs.datname IS NOT NULL';
    END CASE;

    -- pg_stat_database data
    INSERT INTO last_stat_database (
        server_id,
        sample_id,
        datid,
        datname,
        xact_commit,
        xact_rollback,
        blks_read,
        blks_hit,
        tup_returned,
        tup_fetched,
        tup_inserted,
        tup_updated,
        tup_deleted,
        conflicts,
        temp_files,
        temp_bytes,
        deadlocks,
        blk_read_time,
        blk_write_time,
        session_time,
        active_time,
        idle_in_transaction_time,
        sessions,
        sessions_abandoned,
        sessions_fatal,
        sessions_killed,
        stats_reset,
        datsize,
        datsize_delta,
        datistemplate)
    SELECT
        sserver_id,
        s_id,
        datid,
        datname,
        xact_commit AS xact_commit,
        xact_rollback AS xact_rollback,
        blks_read AS blks_read,
        blks_hit AS blks_hit,
        tup_returned AS tup_returned,
        tup_fetched AS tup_fetched,
        tup_inserted AS tup_inserted,
        tup_updated AS tup_updated,
        tup_deleted AS tup_deleted,
        conflicts AS conflicts,
        temp_files AS temp_files,
        temp_bytes AS temp_bytes,
        deadlocks AS deadlocks,
        blk_read_time AS blk_read_time,
        blk_write_time AS blk_write_time,
        session_time AS session_time,
        active_time AS active_time,
        idle_in_transaction_time AS idle_in_transaction_time,
        sessions AS sessions,
        sessions_abandoned AS sessions_abandoned,
        sessions_fatal AS sessions_fatal,
        sessions_killed AS sessions_killed,
        stats_reset,
        datsize AS datsize,
        datsize_delta AS datsize_delta,
        datistemplate AS datistemplate
    FROM dblink('server_connection',server_query) AS rs (
        datid oid,
        datname name,
        xact_commit bigint,
        xact_rollback bigint,
        blks_read bigint,
        blks_hit bigint,
        tup_returned bigint,
        tup_fetched bigint,
        tup_inserted bigint,
        tup_updated bigint,
        tup_deleted bigint,
        conflicts bigint,
        temp_files bigint,
        temp_bytes bigint,
        deadlocks bigint,
        blk_read_time double precision,
        blk_write_time double precision,
        session_time double precision,
        active_time double precision,
        idle_in_transaction_time double precision,
        sessions bigint,
        sessions_abandoned bigint,
        sessions_fatal bigint,
        sessions_killed bigint,
        stats_reset timestamp with time zone,
        datsize bigint,
        datsize_delta bigint,
        datistemplate boolean
        );

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,collect database stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,calculate database stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;
    -- Calc stat_database diff
    INSERT INTO sample_stat_database(
      server_id,
      sample_id,
      datid,
      datname,
      xact_commit,
      xact_rollback,
      blks_read,
      blks_hit,
      tup_returned,
      tup_fetched,
      tup_inserted,
      tup_updated,
      tup_deleted,
      conflicts,
      temp_files,
      temp_bytes,
      deadlocks,
      blk_read_time,
      blk_write_time,
      session_time,
      active_time,
      idle_in_transaction_time,
      sessions,
      sessions_abandoned,
      sessions_fatal,
      sessions_killed,
      stats_reset,
      datsize,
      datsize_delta,
      datistemplate
    )
    SELECT
        cur.server_id,
        cur.sample_id,
        cur.datid,
        cur.datname,
        cur.xact_commit - COALESCE(lst.xact_commit,0),
        cur.xact_rollback - COALESCE(lst.xact_rollback,0),
        cur.blks_read - COALESCE(lst.blks_read,0),
        cur.blks_hit - COALESCE(lst.blks_hit,0),
        cur.tup_returned - COALESCE(lst.tup_returned,0),
        cur.tup_fetched - COALESCE(lst.tup_fetched,0),
        cur.tup_inserted - COALESCE(lst.tup_inserted,0),
        cur.tup_updated - COALESCE(lst.tup_updated,0),
        cur.tup_deleted - COALESCE(lst.tup_deleted,0),
        cur.conflicts - COALESCE(lst.conflicts,0),
        cur.temp_files - COALESCE(lst.temp_files,0),
        cur.temp_bytes - COALESCE(lst.temp_bytes,0),
        cur.deadlocks - COALESCE(lst.deadlocks,0),
        cur.blk_read_time - COALESCE(lst.blk_read_time,0),
        cur.blk_write_time - COALESCE(lst.blk_write_time,0),
        cur.session_time - COALESCE(lst.session_time,0),
        cur.active_time - COALESCE(lst.active_time,0),
        cur.idle_in_transaction_time - COALESCE(lst.idle_in_transaction_time,0),
        cur.sessions - COALESCE(lst.sessions,0),
        cur.sessions_abandoned - COALESCE(lst.sessions_abandoned,0),
        cur.sessions_fatal - COALESCE(lst.sessions_fatal,0),
        cur.sessions_killed - COALESCE(lst.sessions_killed,0),
        cur.stats_reset,
        cur.datsize as datsize,
        cur.datsize - COALESCE(lst.datsize,0) as datsize_delta,
        cur.datistemplate
    FROM last_stat_database cur
      LEFT OUTER JOIN last_stat_database lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.datname, lst.stats_reset) =
        (cur.server_id, cur.sample_id - 1, cur.datid, cur.datname, cur.stats_reset)
    WHERE cur.sample_id = s_id AND cur.server_id = sserver_id;

    /*
    * In case of statistics reset full database size is incorrectly
    * considered as increment by previous query. So, we need to update it
    * with correct value
    */
    UPDATE sample_stat_database sdb
    SET datsize_delta = cur.datsize - lst.datsize
    FROM
      last_stat_database cur
      JOIN last_stat_database lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.datname) =
        (cur.server_id, cur.sample_id - 1, cur.datid, cur.datname)
    WHERE cur.stats_reset != lst.stats_reset AND
      cur.sample_id = s_id AND cur.server_id = sserver_id AND
      (sdb.server_id, sdb.sample_id, sdb.datid, sdb.datname) =
      (cur.server_id, cur.sample_id, cur.datid, cur.datname);

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,calculate database stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,collect tablespace stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Construct tablespace stats query
    server_query := 'SELECT '
        'oid as tablespaceid,'
        'spcname as tablespacename,'
        'pg_catalog.pg_tablespace_location(oid) as tablespacepath,'
        'pg_catalog.pg_tablespace_size(oid) as size,'
        '0 as size_delta '
        'FROM pg_catalog.pg_tablespace ';

    -- Get tablespace stats
    INSERT INTO last_stat_tablespaces(
      server_id,
      sample_id,
      tablespaceid,
      tablespacename,
      tablespacepath,
      size,
      size_delta
    )
    SELECT
      sserver_id,
      s_id,
      dbl.tablespaceid,
      dbl.tablespacename,
      dbl.tablespacepath,
      dbl.size AS size,
      dbl.size_delta AS size_delta
    FROM dblink('server_connection', server_query)
    AS dbl (
        tablespaceid            oid,
        tablespacename          name,
        tablespacepath          text,
        size                    bigint,
        size_delta              bigint
    );

    ANALYZE last_stat_tablespaces;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,collect tablespace stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,collect statement stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Search for statements statistics extension
    CASE
      -- pg_stat_statements statistics collection
      WHEN (
        SELECT count(*) = 1
        FROM jsonb_to_recordset(server_properties #> '{extensions}') AS ext(extname text)
        WHERE extname = 'pg_stat_statements'
      ) THEN
        PERFORM collect_pg_stat_statements_stats(server_properties, sserver_id, s_id, topn);
      ELSE
        NULL;
    END CASE;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,collect statement stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,query pg_stat_bgwriter}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- pg_stat_bgwriter data
    CASE
      WHEN (
        SELECT count(*) = 1 FROM jsonb_to_recordset(server_properties #> '{settings}')
          AS x(name text, reset_val text)
        WHERE name = 'server_version_num'
          AND reset_val::integer < 100000
      )
      THEN
        server_query := 'SELECT '
          'checkpoints_timed,'
          'checkpoints_req,'
          'checkpoint_write_time,'
          'checkpoint_sync_time,'
          'buffers_checkpoint,'
          'buffers_clean,'
          'maxwritten_clean,'
          'buffers_backend,'
          'buffers_backend_fsync,'
          'buffers_alloc,'
          'stats_reset,'
          'CASE WHEN pg_catalog.pg_is_in_recovery() THEN 0 '
            'ELSE pg_catalog.pg_xlog_location_diff(pg_catalog.pg_current_xlog_location(),''0/00000000'') '
          'END AS wal_size '
          'FROM pg_catalog.pg_stat_bgwriter';
      WHEN (
        SELECT count(*) = 1 FROM jsonb_to_recordset(server_properties #> '{settings}')
          AS x(name text, reset_val text)
        WHERE name = 'server_version_num'
          AND reset_val::integer >= 100000
      )
      THEN
        server_query := 'SELECT '
          'checkpoints_timed,'
          'checkpoints_req,'
          'checkpoint_write_time,'
          'checkpoint_sync_time,'
          'buffers_checkpoint,'
          'buffers_clean,'
          'maxwritten_clean,'
          'buffers_backend,'
          'buffers_backend_fsync,'
          'buffers_alloc,'
          'stats_reset,'
          'CASE WHEN pg_catalog.pg_is_in_recovery() THEN 0 '
              'ELSE pg_catalog.pg_wal_lsn_diff(pg_catalog.pg_current_wal_lsn(),''0/00000000'') '
          'END AS wal_size '
        'FROM pg_catalog.pg_stat_bgwriter';
    END CASE;

    IF server_query IS NOT NULL THEN
      INSERT INTO last_stat_cluster (
        server_id,
        sample_id,
        checkpoints_timed,
        checkpoints_req,
        checkpoint_write_time,
        checkpoint_sync_time,
        buffers_checkpoint,
        buffers_clean,
        maxwritten_clean,
        buffers_backend,
        buffers_backend_fsync,
        buffers_alloc,
        stats_reset,
        wal_size)
      SELECT
        sserver_id,
        s_id,
        checkpoints_timed AS checkpoints_timed,
        checkpoints_req AS checkpoints_req,
        checkpoint_write_time AS checkpoint_write_time,
        checkpoint_sync_time AS checkpoint_sync_time,
        buffers_checkpoint AS buffers_checkpoint,
        buffers_clean AS buffers_clean,
        maxwritten_clean AS maxwritten_clean,
        buffers_backend AS buffers_backend,
        buffers_backend_fsync AS buffers_backend_fsync,
        buffers_alloc AS buffers_alloc,
        stats_reset,
        wal_size AS wal_size
      FROM dblink('server_connection',server_query) AS rs (
        checkpoints_timed bigint,
        checkpoints_req bigint,
        checkpoint_write_time double precision,
        checkpoint_sync_time double precision,
        buffers_checkpoint bigint,
        buffers_clean bigint,
        maxwritten_clean bigint,
        buffers_backend bigint,
        buffers_backend_fsync bigint,
        buffers_alloc bigint,
        stats_reset timestamp with time zone,
        wal_size bigint);
    END IF;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,query pg_stat_bgwriter,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,query pg_stat_wal}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- pg_stat_wal data
    CASE
      WHEN (
        SELECT count(*) = 1 FROM jsonb_to_recordset(server_properties #> '{settings}')
          AS x(name text, reset_val text)
        WHERE name = 'server_version_num'
          AND reset_val::integer >= 140000
      )
      THEN
        server_query := 'SELECT '
          'wal_records,'
          'wal_fpi,'
          'wal_bytes,'
          'wal_buffers_full,'
          'wal_write,'
          'wal_sync,'
          'wal_write_time,'
          'wal_sync_time,'
          'stats_reset '
          'FROM pg_catalog.pg_stat_wal';
      ELSE
        server_query := NULL;
    END CASE;

    IF server_query IS NOT NULL THEN
      INSERT INTO last_stat_wal (
        server_id,
        sample_id,
        wal_records,
        wal_fpi,
        wal_bytes,
        wal_buffers_full,
        wal_write,
        wal_sync,
        wal_write_time,
        wal_sync_time,
        stats_reset
      )
      SELECT
        sserver_id,
        s_id,
        wal_records,
        wal_fpi,
        wal_bytes,
        wal_buffers_full,
        wal_write,
        wal_sync,
        wal_write_time,
        wal_sync_time,
        stats_reset
      FROM dblink('server_connection',server_query) AS rs (
        wal_records         bigint,
        wal_fpi             bigint,
        wal_bytes           numeric,
        wal_buffers_full    bigint,
        wal_write           bigint,
        wal_sync            bigint,
        wal_write_time      double precision,
        wal_sync_time       double precision,
        stats_reset         timestamp with time zone);
    END IF;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,query pg_stat_wal,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,query pg_stat_archiver}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- pg_stat_archiver data
    CASE
      WHEN (
        SELECT count(*) = 1 FROM jsonb_to_recordset(server_properties #> '{settings}')
          AS x(name text, reset_val text)
        WHERE name = 'server_version_num'
          AND reset_val::integer > 90500
      )
      THEN
        server_query := 'SELECT '
          'archived_count,'
          'last_archived_wal,'
          'last_archived_time,'
          'failed_count,'
          'last_failed_wal,'
          'last_failed_time,'
          'stats_reset '
          'FROM pg_catalog.pg_stat_archiver';
    END CASE;

    IF server_query IS NOT NULL THEN
      INSERT INTO last_stat_archiver (
        server_id,
        sample_id,
        archived_count,
        last_archived_wal,
        last_archived_time,
        failed_count,
        last_failed_wal,
        last_failed_time,
        stats_reset)
      SELECT
        sserver_id,
        s_id,
        archived_count as archived_count,
        last_archived_wal as last_archived_wal,
        last_archived_time as last_archived_time,
        failed_count as failed_count,
        last_failed_wal as last_failed_wal,
        last_failed_time as last_failed_time,
        stats_reset as stats_reset
      FROM dblink('server_connection',server_query) AS rs (
        archived_count              bigint,
        last_archived_wal           text,
        last_archived_time          timestamp with time zone,
        failed_count                bigint,
        last_failed_wal             text,
        last_failed_time            timestamp with time zone,
        stats_reset                 timestamp with time zone
      );
    END IF;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,query pg_stat_archiver,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,collect object stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Collecting stat info for objects of all databases
    server_properties := collect_obj_stats(server_properties, sserver_id, s_id, server_connstr, skip_sizes);
    ASSERT server_properties IS NOT NULL, 'lost properties';

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,collect object stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,disconnect}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    PERFORM dblink_disconnect('server_connection');

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,disconnect,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,maintain repository}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Updating dictionary table in case of object renaming:
    -- Databases
    UPDATE sample_stat_database AS db
    SET datname = lst.datname
    FROM last_stat_database AS lst
    WHERE db.server_id = lst.server_id AND db.datid = lst.datid
      AND db.datname != lst.datname
      AND lst.sample_id = s_id;
    -- Tables
    UPDATE tables_list AS tl
    SET schemaname = lst.schemaname, relname = lst.relname
    FROM last_stat_tables AS lst
    WHERE tl.server_id = lst.server_id AND tl.datid = lst.datid AND tl.relid = lst.relid AND tl.relkind = lst.relkind
      AND (tl.schemaname != lst.schemaname OR tl.relname != lst.relname)
      AND lst.sample_id = s_id;
    -- Indexes
    UPDATE indexes_list AS il
    SET schemaname = lst.schemaname, indexrelname = lst.indexrelname
    FROM last_stat_indexes AS lst
    WHERE il.server_id = lst.server_id AND il.datid = lst.datid AND il.indexrelid = lst.indexrelid
      AND il.relid = lst.relid
      AND (il.schemaname != lst.schemaname OR il.indexrelname != lst.indexrelname)
      AND lst.sample_id = s_id;
    -- Functions
    UPDATE funcs_list AS fl
    SET schemaname = lst.schemaname, funcname = lst.funcname, funcargs = lst.funcargs
    FROM last_stat_user_functions AS lst
    WHERE fl.server_id = lst.server_id AND fl.datid = lst.datid AND fl.funcid = lst.funcid
      AND (fl.schemaname != lst.schemaname OR fl.funcname != lst.funcname OR fl.funcargs != lst.funcargs)
      AND lst.sample_id = s_id;
    -- Tablespaces
    UPDATE tablespaces_list AS tl
    SET tablespacename = lst.tablespacename, tablespacepath = lst.tablespacepath
    FROM last_stat_tablespaces AS lst
    WHERE tl.server_id = lst.server_id AND tl.tablespaceid = lst.tablespaceid
      AND (tl.tablespacename != lst.tablespacename OR tl.tablespacepath != lst.tablespacepath)
      AND lst.sample_id = s_id;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,maintain repository,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,calculate tablespace stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    INSERT INTO tablespaces_list (
        server_id,
        tablespaceid,
        tablespacename,
        tablespacepath
      )
    SELECT
      lst.server_id,
      lst.tablespaceid,
      lst.tablespacename,
      lst.tablespacepath
    FROM
      last_stat_tablespaces lst
      LEFT JOIN tablespaces_list tl USING (server_id, tablespaceid)
    WHERE
      lst.server_id = sserver_id
      AND tl.tablespaceid IS NULL;

    -- Calculate diffs for tablespaces
    INSERT INTO sample_stat_tablespaces(
      server_id,
      sample_id,
      tablespaceid,
      size,
      size_delta
    )
    SELECT
      cur.server_id as server_id,
      cur.sample_id as sample_id,
      cur.tablespaceid as tablespaceid,
      cur.size as size,
      cur.size - COALESCE(lst.size, 0) AS size_delta
    FROM last_stat_tablespaces cur
      LEFT OUTER JOIN last_stat_tablespaces lst ON
        (cur.server_id, cur.sample_id - 1, cur.tablespaceid) =
        (lst.server_id, lst.sample_id, lst.tablespaceid)
    WHERE (cur.sample_id, cur.server_id) = (s_id, sserver_id);

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,calculate tablespace stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,calculate object stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- collect databases objects stats
    server_properties := sample_dbobj_delta(server_properties,sserver_id,s_id,topn,skip_sizes);
    ASSERT server_properties IS NOT NULL, 'lost properties';

    DELETE FROM last_stat_tablespaces WHERE server_id = sserver_id AND sample_id != s_id;

    DELETE FROM last_stat_database WHERE server_id = sserver_id AND sample_id != s_id;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,calculate object stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,calculate cluster stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Calc stat cluster diff
    INSERT INTO sample_stat_cluster(
      server_id,
      sample_id,
      checkpoints_timed,
      checkpoints_req,
      checkpoint_write_time,
      checkpoint_sync_time,
      buffers_checkpoint,
      buffers_clean,
      maxwritten_clean,
      buffers_backend,
      buffers_backend_fsync,
      buffers_alloc,
      stats_reset,
      wal_size
    )
    SELECT
        cur.server_id,
        cur.sample_id,
        cur.checkpoints_timed - COALESCE(lst.checkpoints_timed,0),
        cur.checkpoints_req - COALESCE(lst.checkpoints_req,0),
        cur.checkpoint_write_time - COALESCE(lst.checkpoint_write_time,0),
        cur.checkpoint_sync_time - COALESCE(lst.checkpoint_sync_time,0),
        cur.buffers_checkpoint - COALESCE(lst.buffers_checkpoint,0),
        cur.buffers_clean - COALESCE(lst.buffers_clean,0),
        cur.maxwritten_clean - COALESCE(lst.maxwritten_clean,0),
        cur.buffers_backend - COALESCE(lst.buffers_backend,0),
        cur.buffers_backend_fsync - COALESCE(lst.buffers_backend_fsync,0),
        cur.buffers_alloc - COALESCE(lst.buffers_alloc,0),
        cur.stats_reset,
        cur.wal_size - COALESCE(lst.wal_size,0)
        /* We will overwrite this value in case of stats reset
         * (see below)
         */
    FROM last_stat_cluster cur
      LEFT OUTER JOIN last_stat_cluster lst ON
        (cur.stats_reset, cur.server_id, cur.sample_id) =
        (lst.stats_reset, lst.server_id, lst.sample_id + 1)
    WHERE cur.sample_id = s_id AND cur.server_id = sserver_id;

    /* wal_size is calculated since 0 to current value when stats reset happened
     * so, we need to update it
     */
    UPDATE sample_stat_cluster ssc
    SET wal_size = cur.wal_size - lst.wal_size
    FROM last_stat_cluster cur
      JOIN last_stat_cluster lst ON
        (cur.server_id, cur.sample_id) =
        (lst.server_id, lst.sample_id + 1)
    WHERE
      (ssc.server_id, ssc.sample_id) =
      (cur.server_id, cur.sample_id) AND
      cur.sample_id = s_id AND
      cur.server_id = sserver_id AND
      cur.stats_reset != lst.stats_reset;

    DELETE FROM last_stat_cluster WHERE server_id = sserver_id AND sample_id != s_id;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,calculate cluster stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,calculate WAL stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Calc WAL stat diff
    INSERT INTO sample_stat_wal(
      server_id,
      sample_id,
      wal_records,
      wal_fpi,
      wal_bytes,
      wal_buffers_full,
      wal_write,
      wal_sync,
      wal_write_time,
      wal_sync_time,
      stats_reset
    )
    SELECT
        cur.server_id,
        cur.sample_id,
        cur.wal_records - COALESCE(lst.wal_records,0),
        cur.wal_fpi - COALESCE(lst.wal_fpi,0),
        cur.wal_bytes - COALESCE(lst.wal_bytes,0),
        cur.wal_buffers_full - COALESCE(lst.wal_buffers_full,0),
        cur.wal_write - COALESCE(lst.wal_write,0),
        cur.wal_sync - COALESCE(lst.wal_sync,0),
        cur.wal_write_time - COALESCE(lst.wal_write_time,0),
        cur.wal_sync_time - COALESCE(lst.wal_sync_time,0),
        cur.stats_reset
    FROM last_stat_wal cur
    LEFT OUTER JOIN last_stat_wal lst ON
      (cur.stats_reset = lst.stats_reset AND cur.server_id = lst.server_id AND lst.sample_id = cur.sample_id - 1)
    WHERE cur.sample_id = s_id AND cur.server_id = sserver_id;

    DELETE FROM last_stat_wal WHERE server_id = sserver_id AND sample_id != s_id;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,calculate WAL stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,calculate archiver stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Calc stat archiver diff
    INSERT INTO sample_stat_archiver(
      server_id,
      sample_id,
      archived_count,
      last_archived_wal,
      last_archived_time,
      failed_count,
      last_failed_wal,
      last_failed_time,
      stats_reset
    )
    SELECT
        cur.server_id,
        cur.sample_id,
        cur.archived_count - COALESCE(lst.archived_count,0),
        cur.last_archived_wal,
        cur.last_archived_time,
        cur.failed_count - COALESCE(lst.failed_count,0),
        cur.last_failed_wal,
        cur.last_failed_time,
        cur.stats_reset
    FROM last_stat_archiver cur
    LEFT OUTER JOIN last_stat_archiver lst ON
      (cur.stats_reset = lst.stats_reset AND cur.server_id = lst.server_id AND lst.sample_id = cur.sample_id - 1)
    WHERE cur.sample_id = s_id AND cur.server_id = sserver_id;

    DELETE FROM last_stat_archiver WHERE server_id = sserver_id AND sample_id != s_id;

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,calculate archiver stats,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,delete obsolete samples}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Deleting obsolete baselines
    DELETE FROM baselines
    WHERE keep_until < now()
      AND server_id = sserver_id;
    -- Deleting obsolete samples
    DELETE FROM samples s
      USING servers n
    WHERE n.server_id = s.server_id AND s.server_id = sserver_id
        AND s.sample_time < now() - (COALESCE(n.max_sample_age,ret) || ' days')::interval
        AND (s.server_id,s.sample_id) NOT IN (SELECT server_id,sample_id FROM bl_samples WHERE server_id = sserver_id);
    -- Deleting unused statements
    DELETE FROM stmt_list
        WHERE server_id = sserver_id AND queryid_md5 NOT IN
            (SELECT queryid_md5 FROM sample_statements
                UNION
             SELECT queryid_md5 FROM sample_kcache);

    -- Delete unused tablespaces from list
    DELETE FROM tablespaces_list
    WHERE server_id = sserver_id
      AND (server_id, tablespaceid) NOT IN (
        SELECT server_id, tablespaceid FROM sample_stat_tablespaces
        WHERE server_id = sserver_id
    );

    -- Delete unused roles from roles_list
    WITH used_roles AS (
        SELECT DISTINCT userid FROM sample_statements WHERE server_id = sserver_id
    )
    DELETE FROM roles_list
    WHERE server_id = sserver_id
      AND userid NOT IN (SELECT userid FROM used_roles)
    ;

    -- Delete unused indexes from indexes list
    DELETE FROM indexes_list
    WHERE server_id = sserver_id
      AND (datid, indexrelid) NOT IN (
        SELECT datid, indexrelid FROM sample_stat_indexes
        WHERE server_id = sserver_id
    );

    -- Delete unused tables from tables list
    WITH used_tables AS (
        SELECT server_id, datid, relid FROM sample_stat_tables WHERE server_id = sserver_id
        UNION ALL
        SELECT server_id, datid, relid FROM indexes_list WHERE server_id = sserver_id)
    DELETE FROM tables_list
    WHERE server_id = sserver_id
      AND (datid, relid) NOT IN (SELECT datid, relid FROM used_tables)
      AND (datid, reltoastrelid) NOT IN (SELECT datid, relid FROM used_tables);

    -- Delete unused functions from functions list
    DELETE FROM funcs_list
    WHERE server_id = sserver_id
      AND (server_id, funcid) NOT IN (
        SELECT server_id, funcid FROM sample_stat_user_functions WHERE server_id = sserver_id
    );

    -- Delete obsolete values of postgres parameters
    DELETE FROM sample_settings ss
    USING (
      SELECT server_id, max(first_seen) AS first_seen, setting_scope, name
      FROM sample_settings
      WHERE server_id = sserver_id AND first_seen <= (SELECT min(sample_time) FROM samples WHERE server_id = sserver_id)
      GROUP BY server_id, setting_scope, name) AS ss_ref
    WHERE ss.server_id = ss_ref.server_id AND ss.setting_scope = ss_ref.setting_scope AND ss.name = ss_ref.name
      AND ss.first_seen < ss_ref.first_seen;
    -- Delete obsolete values of postgres parameters from previous versions of postgres on server
    DELETE FROM sample_settings
    WHERE server_id = sserver_id AND first_seen <
      (SELECT min(first_seen) FROM sample_settings WHERE server_id = sserver_id AND name = 'version' AND setting_scope = 2);

    IF (server_properties #>> '{collect_timings}')::boolean THEN
      server_properties := jsonb_set(server_properties,'{timings,delete obsolete samples,end}',to_jsonb(clock_timestamp()));
      server_properties := jsonb_set(server_properties,'{timings,total,end}',to_jsonb(clock_timestamp()));
      -- Save timing statistics of sample
      INSERT INTO sample_timings
      SELECT sserver_id, s_id, key,(value::jsonb #>> '{end}')::timestamp with time zone - (value::jsonb #>> '{start}')::timestamp with time zone as time_spent
      FROM jsonb_each_text(server_properties #> '{timings}');
    END IF;
    ASSERT server_properties IS NOT NULL, 'lost properties';

    RETURN 0;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION take_sample(IN sserver_id integer, IN skip_sizes boolean) IS
  'Statistics sample creation function (by server_id)';

CREATE FUNCTION take_sample(IN server name, IN skip_sizes boolean = NULL) RETURNS integer SET search_path=@extschema@ AS $$
DECLARE
    sserver_id    integer;
BEGIN
    SELECT server_id INTO sserver_id FROM servers WHERE server_name = server;
    IF sserver_id IS NULL THEN
        RAISE 'Server not found';
    ELSE
        RETURN take_sample(sserver_id, skip_sizes);
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION take_sample(IN server name, IN skip_sizes boolean) IS
  'Statistics sample creation function (by server name)';

CREATE FUNCTION take_sample_subset(IN sets_cnt integer = 1, IN current_set integer = 0) RETURNS TABLE (
    server      name,
    result      text,
    elapsed     interval day to second (2)
)
SET search_path=@extschema@ AS $$
DECLARE
    c_servers CURSOR FOR
      SELECT server_id,server_name FROM (
        SELECT server_id,server_name, row_number() OVER () AS srv_rn
        FROM servers WHERE enabled
        ) AS t1
      WHERE srv_rn % sets_cnt = current_set;
    server_sampleres        integer;
    etext               text := '';
    edetail             text := '';
    econtext            text := '';

    qres          RECORD;
    start_clock   timestamp (2) with time zone;
BEGIN
    IF sets_cnt IS NULL OR sets_cnt < 1 THEN
      RAISE 'sets_cnt value is invalid. Must be positive';
    END IF;
    IF current_set IS NULL OR current_set < 0 OR current_set > sets_cnt - 1 THEN
      RAISE 'current_cnt value is invalid. Must be between 0 and sets_cnt - 1';
    END IF;
    FOR qres IN c_servers LOOP
        BEGIN
            start_clock := clock_timestamp()::timestamp (2) with time zone;
            server := qres.server_name;
            server_sampleres := take_sample(qres.server_id, NULL);
            elapsed := clock_timestamp()::timestamp (2) with time zone - start_clock;
            CASE server_sampleres
              WHEN 0 THEN
                result := 'OK';
              ELSE
                result := 'FAIL';
            END CASE;
            RETURN NEXT;
        EXCEPTION
            WHEN OTHERS THEN
                BEGIN
                    GET STACKED DIAGNOSTICS etext = MESSAGE_TEXT,
                        edetail = PG_EXCEPTION_DETAIL,
                        econtext = PG_EXCEPTION_CONTEXT;
                    result := format (E'%s\n%s\n%s', etext, econtext, edetail);
                    elapsed := clock_timestamp()::timestamp (2) with time zone - start_clock;
                    RETURN NEXT;
                END;
        END;
    END LOOP;
    RETURN;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION take_sample_subset(IN sets_cnt integer, IN current_set integer) IS
  'Statistics sample creation function (for subset of enabled servers). Used for simplification of parallel sample collection.';

CREATE FUNCTION take_sample() RETURNS TABLE (
    server      name,
    result      text,
    elapsed     interval day to second (2)
)
SET search_path=@extschema@ AS $$
  SELECT * FROM take_sample_subset(1,0);
$$ LANGUAGE sql;

COMMENT ON FUNCTION take_sample() IS 'Statistics sample creation function (for all enabled servers). Must be explicitly called periodically.';

CREATE FUNCTION collect_obj_stats(IN properties jsonb, IN sserver_id integer, IN s_id integer, IN connstr text,
  IN skip_sizes boolean
) RETURNS jsonb SET search_path=@extschema@ AS $$
DECLARE
    --Cursor for db stats
    c_dblist CURSOR FOR
    SELECT datid,datname,tablespaceid FROM dblink('server_connection',
    'select dbs.oid,dbs.datname,dbs.dattablespace from pg_catalog.pg_database dbs '
    'where not dbs.datistemplate and dbs.datallowconn') AS dbl (
        datid oid,
        datname name,
        tablespaceid oid
    ) JOIN servers n ON (n.server_id = sserver_id AND array_position(n.db_exclude,dbl.datname) IS NULL);

    qres        record;
    db_connstr  text;
    t_query     text;
    result      jsonb := collect_obj_stats.properties;
BEGIN
    -- Adding dblink extension schema to search_path if it does not already there
    IF (SELECT count(*) = 0 FROM pg_catalog.pg_extension WHERE extname = 'dblink') THEN
      RAISE 'dblink extension must be installed';
    END IF;
    SELECT extnamespace::regnamespace AS dblink_schema INTO STRICT qres FROM pg_catalog.pg_extension WHERE extname = 'dblink';
    IF NOT string_to_array(current_setting('search_path'),',') @> ARRAY[qres.dblink_schema::text] THEN
      EXECUTE 'SET LOCAL search_path TO ' || current_setting('search_path')||','|| qres.dblink_schema;
    END IF;

    -- Disconnecting existing connection
    IF dblink_get_connections() @> ARRAY['server_db_connection'] THEN
        PERFORM dblink_disconnect('server_db_connection');
    END IF;

    -- Load new data from statistic views of all cluster databases
    FOR qres IN c_dblist LOOP
      db_connstr := concat_ws(' ',connstr,
        format($o$dbname='%s'$o$,replace(qres.datname,$o$'$o$,$o$\'$o$))
      );
      PERFORM dblink_connect('server_db_connection',db_connstr);
      -- Setting application name
      PERFORM dblink('server_connection','SET application_name=''{pg_profile}''');
      -- Setting lock_timout prevents hanging of take_sample() call due to DDL in long transaction
      PERFORM dblink('server_db_connection','SET lock_timeout=3000');
      -- Reset search_path for security reasons
      PERFORM dblink('server_connection','SET search_path=''''');

      IF (properties #>> '{collect_timings}')::boolean THEN
        result := jsonb_set(result,ARRAY['timings',format('db:%s collect tables stats',qres.datname)],jsonb_build_object('start',clock_timestamp()));
      END IF;

      -- Generate Table stats query
      CASE
        WHEN (
          SELECT count(*) = 1 FROM jsonb_to_recordset(properties #> '{settings}')
            AS x(name text, reset_val text)
          WHERE name = 'server_version_num'
            AND reset_val::integer < 130000
        )
        THEN
          t_query := 'SELECT '
            'st.relid,'
            'st.schemaname,'
            'st.relname,'
            'st.seq_scan,'
            'st.seq_tup_read,'
            'st.idx_scan,'
            'st.idx_tup_fetch,'
            'st.n_tup_ins,'
            'st.n_tup_upd,'
            'st.n_tup_del,'
            'st.n_tup_hot_upd,'
            'st.n_live_tup,'
            'st.n_dead_tup,'
            'st.n_mod_since_analyze,'
            'NULL as n_ins_since_vacuum,'
            'st.last_vacuum,'
            'st.last_autovacuum,'
            'st.last_analyze,'
            'st.last_autoanalyze,'
            'st.vacuum_count,'
            'st.autovacuum_count,'
            'st.analyze_count,'
            'st.autoanalyze_count,'
            'stio.heap_blks_read,'
            'stio.heap_blks_hit,'
            'stio.idx_blks_read,'
            'stio.idx_blks_hit,'
            'stio.toast_blks_read,'
            'stio.toast_blks_hit,'
            'stio.tidx_blks_read,'
            'stio.tidx_blks_hit,'
            -- Size of all forks without TOAST
            '{relation_size} relsize,'
            '0 relsize_diff,'
            'class.reltablespace AS tablespaceid,'
            'class.reltoastrelid,'
            'class.relkind,'
            'class.relpages * current_setting(''block_size'')::integer AS relpages_bytes,'
            '0 AS relpages_bytes_diff '
          'FROM pg_catalog.pg_stat_all_tables st '
          'JOIN pg_catalog.pg_statio_all_tables stio USING (relid, schemaname, relname) '
          'JOIN pg_catalog.pg_class class ON (st.relid = class.oid) '
          -- is relation or its dependant is locked
          '{lock_join}'
          ;

        WHEN (
          SELECT count(*) = 1 FROM jsonb_to_recordset(properties #> '{settings}')
            AS x(name text, reset_val text)
          WHERE name = 'server_version_num'
            AND reset_val::integer >= 130000
        )
        THEN
          t_query := 'SELECT '
            'st.relid,'
            'st.schemaname,'
            'st.relname,'
            'st.seq_scan,'
            'st.seq_tup_read,'
            'st.idx_scan,'
            'st.idx_tup_fetch,'
            'st.n_tup_ins,'
            'st.n_tup_upd,'
            'st.n_tup_del,'
            'st.n_tup_hot_upd,'
            'st.n_live_tup,'
            'st.n_dead_tup,'
            'st.n_mod_since_analyze,'
            'st.n_ins_since_vacuum,'
            'st.last_vacuum,'
            'st.last_autovacuum,'
            'st.last_analyze,'
            'st.last_autoanalyze,'
            'st.vacuum_count,'
            'st.autovacuum_count,'
            'st.analyze_count,'
            'st.autoanalyze_count,'
            'stio.heap_blks_read,'
            'stio.heap_blks_hit,'
            'stio.idx_blks_read,'
            'stio.idx_blks_hit,'
            'stio.toast_blks_read,'
            'stio.toast_blks_hit,'
            'stio.tidx_blks_read,'
            'stio.tidx_blks_hit,'
            -- Size of all forks without TOAST
            '{relation_size} relsize,'
            '0 relsize_diff,'
            'class.reltablespace AS tablespaceid,'
            'class.reltoastrelid,'
            'class.relkind,'
            'class.relpages * current_setting(''block_size'')::integer AS relpages_bytes,'
            '0 AS relpages_bytes_diff '
          'FROM pg_catalog.pg_stat_all_tables st '
          'JOIN pg_catalog.pg_statio_all_tables stio USING (relid, schemaname, relname) '
          'JOIN pg_catalog.pg_class class ON (st.relid = class.oid) '
          -- is relation or its dependant is locked
          '{lock_join}'
          ;
        ELSE
          RAISE 'Unsupported server version.';
      END CASE;

      IF skip_sizes THEN
        t_query := replace(t_query,'{relation_size}','NULL');
        t_query := replace(t_query,'{lock_join}','');
      ELSE
        t_query := replace(t_query,'{relation_size}','CASE locked.objid WHEN st.relid THEN NULL ELSE '
          'pg_catalog.pg_table_size(st.relid) - '
          'coalesce(pg_catalog.pg_relation_size(class.reltoastrelid),0) END');
        t_query := replace(t_query,'{lock_join}',
          'LEFT OUTER JOIN LATERAL '
            '(WITH RECURSIVE deps (objid) AS ('
              'SELECT relation FROM pg_catalog.pg_locks WHERE granted AND locktype = ''relation'' AND mode=''AccessExclusiveLock'' '
              'UNION '
              'SELECT refobjid FROM pg_catalog.pg_depend d JOIN deps dd ON (d.objid = dd.objid)'
            ') '
            'SELECT objid FROM deps) AS locked ON (st.relid = locked.objid)');
      END IF;

      INSERT INTO last_stat_tables(
        server_id,
        sample_id,
        datid,
        relid,
        schemaname,
        relname,
        seq_scan,
        seq_tup_read,
        idx_scan,
        idx_tup_fetch,
        n_tup_ins,
        n_tup_upd,
        n_tup_del,
        n_tup_hot_upd,
        n_live_tup,
        n_dead_tup,
        n_mod_since_analyze,
        n_ins_since_vacuum,
        last_vacuum,
        last_autovacuum,
        last_analyze,
        last_autoanalyze,
        vacuum_count,
        autovacuum_count,
        analyze_count,
        autoanalyze_count,
        heap_blks_read,
        heap_blks_hit,
        idx_blks_read,
        idx_blks_hit,
        toast_blks_read,
        toast_blks_hit,
        tidx_blks_read,
        tidx_blks_hit,
        relsize,
        relsize_diff,
        tablespaceid,
        reltoastrelid,
        relkind,
        in_sample,
        relpages_bytes,
        relpages_bytes_diff
      )
      SELECT
        sserver_id,
        s_id,
        qres.datid,
        dbl.relid,
        dbl.schemaname,
        dbl.relname,
        dbl.seq_scan AS seq_scan,
        dbl.seq_tup_read AS seq_tup_read,
        dbl.idx_scan AS idx_scan,
        dbl.idx_tup_fetch AS idx_tup_fetch,
        dbl.n_tup_ins AS n_tup_ins,
        dbl.n_tup_upd AS n_tup_upd,
        dbl.n_tup_del AS n_tup_del,
        dbl.n_tup_hot_upd AS n_tup_hot_upd,
        dbl.n_live_tup AS n_live_tup,
        dbl.n_dead_tup AS n_dead_tup,
        dbl.n_mod_since_analyze AS n_mod_since_analyze,
        dbl.n_ins_since_vacuum AS n_ins_since_vacuum,
        dbl.last_vacuum,
        dbl.last_autovacuum,
        dbl.last_analyze,
        dbl.last_autoanalyze,
        dbl.vacuum_count AS vacuum_count,
        dbl.autovacuum_count AS autovacuum_count,
        dbl.analyze_count AS analyze_count,
        dbl.autoanalyze_count AS autoanalyze_count,
        dbl.heap_blks_read AS heap_blks_read,
        dbl.heap_blks_hit AS heap_blks_hit,
        dbl.idx_blks_read AS idx_blks_read,
        dbl.idx_blks_hit AS idx_blks_hit,
        dbl.toast_blks_read AS toast_blks_read,
        dbl.toast_blks_hit AS toast_blks_hit,
        dbl.tidx_blks_read AS tidx_blks_read,
        dbl.tidx_blks_hit AS tidx_blks_hit,
        dbl.relsize AS relsize,
        dbl.relsize_diff AS relsize_diff,
        CASE WHEN dbl.tablespaceid=0 THEN qres.tablespaceid ELSE dbl.tablespaceid END AS tablespaceid,
        dbl.reltoastrelid,
        dbl.relkind,
        false,
        dbl.relpages_bytes,
        dbl.relpages_bytes_diff
      FROM dblink('server_db_connection', t_query)
      AS dbl (
          relid                 oid,
          schemaname            name,
          relname               name,
          seq_scan              bigint,
          seq_tup_read          bigint,
          idx_scan              bigint,
          idx_tup_fetch         bigint,
          n_tup_ins             bigint,
          n_tup_upd             bigint,
          n_tup_del             bigint,
          n_tup_hot_upd         bigint,
          n_live_tup            bigint,
          n_dead_tup            bigint,
          n_mod_since_analyze   bigint,
          n_ins_since_vacuum    bigint,
          last_vacuum           timestamp with time zone,
          last_autovacuum       timestamp with time zone,
          last_analyze          timestamp with time zone,
          last_autoanalyze      timestamp with time zone,
          vacuum_count          bigint,
          autovacuum_count      bigint,
          analyze_count         bigint,
          autoanalyze_count     bigint,
          heap_blks_read        bigint,
          heap_blks_hit         bigint,
          idx_blks_read         bigint,
          idx_blks_hit          bigint,
          toast_blks_read       bigint,
          toast_blks_hit        bigint,
          tidx_blks_read        bigint,
          tidx_blks_hit         bigint,
          relsize               bigint,
          relsize_diff          bigint,
          tablespaceid          oid,
          reltoastrelid         oid,
          relkind               char,
          relpages_bytes        bigint,
          relpages_bytes_diff   bigint
      );

      ANALYZE last_stat_tables;

      IF (result #>> '{collect_timings}')::boolean THEN
        result := jsonb_set(result,ARRAY['timings',format('db:%s collect tables stats',qres.datname),'end'],to_jsonb(clock_timestamp()));
        result := jsonb_set(result,ARRAY['timings',format('db:%s collect indexes stats',qres.datname)],jsonb_build_object('start',clock_timestamp()));
      END IF;

      -- Generate index stats query
      t_query := 'SELECT st.*,'
        'stio.idx_blks_read,'
        'stio.idx_blks_hit,'
        '{relation_size} relsize,'
        '0,'
        'pg_class.reltablespace as tablespaceid,'
        '(ix.indisunique OR con.conindid IS NOT NULL) AS indisunique,'
        'pg_class.relpages * current_setting(''block_size'')::integer AS relpages_bytes,'
        '0 AS relpages_bytes_diff '
      'FROM pg_catalog.pg_stat_all_indexes st '
        'JOIN pg_catalog.pg_statio_all_indexes stio USING (relid, indexrelid, schemaname, relname, indexrelname) '
        'JOIN pg_catalog.pg_index ix ON (ix.indexrelid = st.indexrelid) '
        'JOIN pg_catalog.pg_class ON (pg_class.oid = st.indexrelid) '
        'LEFT OUTER JOIN pg_catalog.pg_constraint con ON (con.conindid = ix.indexrelid AND con.contype in (''p'',''u'')) '
        '{lock_join}'
        ;

      IF skip_sizes THEN
        t_query := replace(t_query,'{relation_size}','NULL');
        t_query := replace(t_query,'{lock_join}','');
      ELSE
        t_query := replace(t_query,'{relation_size}',
          'CASE l.relation WHEN st.indexrelid THEN NULL ELSE pg_relation_size(st.indexrelid) END');
        t_query := replace(t_query,'{lock_join}',
          'LEFT OUTER JOIN LATERAL ('
            'SELECT relation '
            'FROM pg_catalog.pg_locks '
            'WHERE '
            '(relation = st.indexrelid AND granted AND locktype = ''relation'' AND mode=''AccessExclusiveLock'')'
          ') l ON (l.relation = st.indexrelid)');
      END IF;

      INSERT INTO last_stat_indexes(
        server_id,
        sample_id,
        datid,
        relid,
        indexrelid,
        schemaname,
        relname,
        indexrelname,
        idx_scan,
        idx_tup_read,
        idx_tup_fetch,
        idx_blks_read,
        idx_blks_hit,
        relsize,
        relsize_diff,
        tablespaceid,
        indisunique,
        in_sample,
        relpages_bytes,
        relpages_bytes_diff
      )
      SELECT
        sserver_id,
        s_id,
        qres.datid,
        relid,
        indexrelid,
        schemaname,
        relname,
        indexrelname,
        dbl.idx_scan AS idx_scan,
        dbl.idx_tup_read AS idx_tup_read,
        dbl.idx_tup_fetch AS idx_tup_fetch,
        dbl.idx_blks_read AS idx_blks_read,
        dbl.idx_blks_hit AS idx_blks_hit,
        dbl.relsize AS relsize,
        dbl.relsize_diff AS relsize_diff,
        CASE WHEN tablespaceid=0 THEN qres.tablespaceid ELSE tablespaceid END tablespaceid,
        indisunique,
        false,
        dbl.relpages_bytes,
        dbl.relpages_bytes_diff
      FROM dblink('server_db_connection', t_query)
      AS dbl (
         relid          oid,
         indexrelid     oid,
         schemaname     name,
         relname        name,
         indexrelname   name,
         idx_scan       bigint,
         idx_tup_read   bigint,
         idx_tup_fetch  bigint,
         idx_blks_read  bigint,
         idx_blks_hit   bigint,
         relsize        bigint,
         relsize_diff   bigint,
         tablespaceid   oid,
         indisunique    bool,
         relpages_bytes bigint,
         relpages_bytes_diff  bigint
      );

      ANALYZE last_stat_indexes;

      IF (result #>> '{collect_timings}')::boolean THEN
        result := jsonb_set(result,ARRAY['timings',format('db:%s collect indexes stats',qres.datname),'end'],to_jsonb(clock_timestamp()));
        result := jsonb_set(result,ARRAY['timings',format('db:%s collect functions stats',qres.datname)],jsonb_build_object('start',clock_timestamp()));
      END IF;

      -- Generate Function stats query
      t_query := 'SELECT f.funcid,'
        'f.schemaname,'
        'f.funcname,'
        'pg_get_function_arguments(f.funcid) AS funcargs,'
        'f.calls,'
        'f.total_time,'
        'f.self_time,'
        'p.prorettype::regtype::text =''trigger'' AS trg_fn '
      'FROM pg_catalog.pg_stat_user_functions f '
        'JOIN pg_catalog.pg_proc p ON (f.funcid = p.oid)';

      INSERT INTO last_stat_user_functions(
        server_id,
        sample_id,
        datid,
        funcid,
        schemaname,
        funcname,
        funcargs,
        calls,
        total_time,
        self_time,
        trg_fn
      )
      SELECT
        sserver_id,
        s_id,
        qres.datid,
        funcid,
        schemaname,
        funcname,
        funcargs,
        dbl.calls AS calls,
        dbl.total_time AS total_time,
        dbl.self_time AS self_time,
        dbl.trg_fn
      FROM dblink('server_db_connection', t_query)
      AS dbl (
         funcid       oid,
         schemaname   name,
         funcname     name,
         funcargs     text,
         calls        bigint,
         total_time   double precision,
         self_time    double precision,
         trg_fn       boolean
      );

      ANALYZE last_stat_user_functions;

      PERFORM dblink_disconnect('server_db_connection');
      IF (result #>> '{collect_timings}')::boolean THEN
        result := jsonb_set(result,ARRAY['timings',format('db:%s collect functions stats',qres.datname),'end'],to_jsonb(clock_timestamp()));
      END IF;
    END LOOP;
   RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION sample_dbobj_delta(IN properties jsonb, IN sserver_id integer, IN s_id integer,
  IN topn integer, IN skip_sizes boolean) RETURNS jsonb AS $$
DECLARE
    qres    record;
    result  jsonb := sample_dbobj_delta.properties;
BEGIN

    /* This function will calculate statistics increments for database objects
    * and store top objects values in sample.
    * Due to relations between objects we need to mark top objects (and their
    * dependencies) first, and calculate increments later
    */
    IF (properties #>> '{collect_timings}')::boolean THEN
      result := jsonb_set(properties,'{timings,calculate tables stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- Marking functions
    UPDATE last_stat_user_functions ulf
    SET in_sample = true
    FROM
        (SELECT
            cur.server_id,
            cur.sample_id,
            cur.datid,
            cur.funcid,
            row_number() OVER (PARTITION BY cur.trg_fn ORDER BY cur.total_time - COALESCE(lst.total_time,0) DESC) time_rank,
            row_number() OVER (PARTITION BY cur.trg_fn ORDER BY cur.self_time - COALESCE(lst.self_time,0) DESC) stime_rank,
            row_number() OVER (PARTITION BY cur.trg_fn ORDER BY cur.calls - COALESCE(lst.calls,0) DESC) calls_rank
        FROM last_stat_user_functions cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
          LEFT OUTER JOIN last_stat_database dblst ON
            (dblst.server_id, dblst.datid, dblst.sample_id, dblst.stats_reset) =
            (dbcur.server_id, dbcur.datid, dbcur.sample_id - 1, dbcur.stats_reset)
          LEFT OUTER JOIN last_stat_user_functions lst ON
            (lst.server_id, lst.sample_id, lst.datid, lst.funcid) =
            (dblst.server_id, dblst.sample_id, dblst.datid, cur.funcid)
        WHERE
            (cur.server_id, cur.sample_id) =
            (sserver_id, s_id)
            AND cur.calls - COALESCE(lst.calls,0) > 0) diff
    WHERE
      least(
        time_rank,
        calls_rank,
        stime_rank
      ) <= topn
      AND (ulf.server_id, ulf.sample_id, ulf.datid, ulf.funcid) =
        (diff.server_id, diff.sample_id, diff.datid, diff.funcid);

    -- Marking indexes
    UPDATE last_stat_indexes uli
    SET in_sample = true
    FROM
      (SELECT
          cur.server_id,
          cur.sample_id,
          cur.datid,
          cur.indexrelid,
          -- Index ranks
          row_number() OVER (ORDER BY cur.idx_blks_read - COALESCE(lst.idx_blks_read,0) DESC) read_rank,
          row_number() OVER (ORDER BY cur.idx_blks_read+cur.idx_blks_hit-
            COALESCE(lst.idx_blks_read+lst.idx_blks_hit,0) DESC) gets_rank,
          row_number() OVER (PARTITION BY cur.idx_scan - COALESCE(lst.idx_scan,0) = 0
            ORDER BY tblcur.n_tup_ins - COALESCE(tbllst.n_tup_ins,0) +
            tblcur.n_tup_upd - COALESCE(tbllst.n_tup_upd,0) +
            tblcur.n_tup_del - COALESCE(tbllst.n_tup_del,0) DESC) dml_unused_rank,
          row_number() OVER (ORDER BY (tblcur.vacuum_count - COALESCE(tbllst.vacuum_count,0) +
            tblcur.autovacuum_count - COALESCE(tbllst.autovacuum_count,0)) *
              -- Coalesce is used here in case of skipped size collection
              COALESCE(cur.relsize,lst.relsize) DESC) vacuum_bytes_rank
      FROM last_stat_indexes cur JOIN last_stat_tables tblcur USING (server_id, sample_id, datid, relid)
        JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
        LEFT OUTER JOIN last_stat_database dblst ON
          (dblst.server_id, dblst.datid, dblst.sample_id, dblst.stats_reset) =
          (dbcur.server_id, dbcur.datid, dbcur.sample_id - 1, dbcur.stats_reset)
        LEFT OUTER JOIN last_stat_indexes lst ON
          (lst.server_id, lst.sample_id, lst.datid, lst.relid, lst.indexrelid) =
          (dblst.server_id, dblst.sample_id, dblst.datid, cur.relid, cur.indexrelid)
        LEFT OUTER JOIN last_stat_tables tbllst ON
          (tbllst.server_id, tbllst.sample_id, tbllst.datid, tbllst.relid) =
          (dblst.server_id, dblst.sample_id, dblst.datid, lst.relid)
      WHERE
        (cur.server_id, cur.sample_id) =
        (sserver_id, s_id)
      ) diff
    WHERE
      (least(
        read_rank,
        gets_rank,
        vacuum_bytes_rank
      ) <= topn
      OR (dml_unused_rank <= topn AND idx_scan = 0))
      AND (uli.server_id, uli.sample_id, uli.datid, uli.indexrelid, uli.in_sample) =
        (diff.server_id, diff.sample_id, diff.datid, diff.indexrelid, false);

    -- Growth rank is to be calculated independently of database stats_reset value
    UPDATE last_stat_indexes uli
    SET in_sample = true
    FROM
      (SELECT
          cur.server_id,
          cur.sample_id,
          cur.datid,
          cur.indexrelid,
          cur.relsize IS NOT NULL AS relsize_avail,
          cur.relpages_bytes IS NOT NULL AS relpages_avail,
          -- Index ranks
          row_number() OVER (ORDER BY cur.relsize - COALESCE(lst.relsize,0) DESC NULLS LAST) growth_rank,
          row_number() OVER (ORDER BY cur.relpages_bytes - COALESCE(lst.relpages_bytes,0) DESC NULLS LAST) pagegrowth_rank
      FROM last_stat_indexes cur
        LEFT OUTER JOIN last_stat_indexes lst ON
          (lst.server_id, lst.sample_id, lst.datid, lst.relid, lst.indexrelid) =
          (cur.server_id, cur.sample_id - 1, cur.datid, cur.relid, cur.indexrelid)
      WHERE
        (cur.server_id, cur.sample_id) =
        (sserver_id, s_id)
      ) diff
    WHERE
      ((relsize_avail AND growth_rank <= topn) OR
      ((NOT relsize_avail) AND relpages_avail AND pagegrowth_rank <= topn))
      AND (uli.server_id, uli.sample_id, uli.datid, uli.indexrelid, uli.in_sample) =
        (diff.server_id, diff.sample_id, diff.datid, diff.indexrelid, false);

    -- Marking tables
    UPDATE last_stat_tables ulst
    SET in_sample = true
    FROM (
      SELECT
          cur.server_id AS server_id,
          cur.sample_id AS sample_id,
          cur.datid AS datid,
          cur.relid AS relid,
          tcur.relid AS toastrelid,
          -- Seq. scanned blocks rank
          row_number() OVER (ORDER BY
            (cur.seq_scan - COALESCE(lst.seq_scan,0)) * cur.relsize +
            (tcur.seq_scan - COALESCE(tlst.seq_scan,0)) * tcur.relsize DESC) scan_rank,
          row_number() OVER (ORDER BY cur.n_tup_ins + cur.n_tup_upd + cur.n_tup_del -
            COALESCE(lst.n_tup_ins + lst.n_tup_upd + lst.n_tup_del, 0) +
            COALESCE(tcur.n_tup_ins + tcur.n_tup_upd + tcur.n_tup_del, 0) -
            COALESCE(tlst.n_tup_ins + tlst.n_tup_upd + tlst.n_tup_del, 0) DESC) dml_rank,
          row_number() OVER (ORDER BY cur.n_tup_upd+cur.n_tup_del -
            COALESCE(lst.n_tup_upd + lst.n_tup_del, 0) +
            COALESCE(tcur.n_tup_upd + tcur.n_tup_del, 0) -
            COALESCE(tlst.n_tup_upd + tlst.n_tup_del, 0) DESC) vacuum_dml_rank,
          row_number() OVER (ORDER BY
            cur.n_dead_tup / NULLIF(cur.n_live_tup+cur.n_dead_tup, 0)
            DESC NULLS LAST) dead_pct_rank,
          row_number() OVER (ORDER BY
            cur.n_mod_since_analyze / NULLIF(cur.n_live_tup, 0)
            DESC NULLS LAST) mod_pct_rank,
          -- Read rank
          row_number() OVER (ORDER BY
            cur.heap_blks_read - COALESCE(lst.heap_blks_read,0) +
            cur.idx_blks_read - COALESCE(lst.idx_blks_read,0) +
            cur.toast_blks_read - COALESCE(lst.toast_blks_read,0) +
            cur.tidx_blks_read - COALESCE(lst.tidx_blks_read,0) DESC) read_rank,
          -- Page processing rank
          row_number() OVER (ORDER BY cur.heap_blks_read+cur.heap_blks_hit+cur.idx_blks_read+cur.idx_blks_hit+
            cur.toast_blks_read+cur.toast_blks_hit+cur.tidx_blks_read+cur.tidx_blks_hit-
            COALESCE(lst.heap_blks_read+lst.heap_blks_hit+lst.idx_blks_read+lst.idx_blks_hit+
            lst.toast_blks_read+lst.toast_blks_hit+lst.tidx_blks_read+lst.tidx_blks_hit, 0) DESC) gets_rank,
          -- Vacuum rank
          row_number() OVER (ORDER BY cur.vacuum_count - COALESCE(lst.vacuum_count, 0) +
            cur.autovacuum_count - COALESCE(lst.autovacuum_count, 0) DESC) vacuum_rank,
          row_number() OVER (ORDER BY cur.analyze_count - COALESCE(lst.analyze_count,0) +
            cur.autoanalyze_count - COALESCE(lst.autoanalyze_count,0) DESC) analyze_rank
      FROM
        -- main relations diff
        last_stat_tables cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
        LEFT OUTER JOIN last_stat_database dblst ON
          (dblst.server_id, dblst.datid, dblst.sample_id, dblst.stats_reset) =
          (dbcur.server_id, dbcur.datid, dbcur.sample_id - 1, dbcur.stats_reset)
        LEFT OUTER JOIN last_stat_tables lst ON
          (lst.server_id, lst.sample_id, lst.datid, lst.relid) =
          (dblst.server_id, dblst.sample_id, dblst.datid, cur.relid)
        -- toast relations diff
        LEFT OUTER JOIN last_stat_tables tcur ON
          (tcur.server_id, tcur.sample_id, tcur.datid, tcur.relid) =
          (dbcur.server_id, dbcur.sample_id, dbcur.datid, cur.reltoastrelid)
        LEFT OUTER JOIN last_stat_tables tlst ON
          (tlst.server_id, tlst.sample_id, tlst.datid, tlst.relid) =
          (dblst.server_id, dblst.sample_id, dblst.datid, lst.reltoastrelid)
      WHERE
        (cur.server_id, cur.sample_id, cur.in_sample) =
        (sserver_id, s_id, false)
        AND cur.relkind IN ('r','m')) diff
    WHERE
      least(
        scan_rank,
        dml_rank,
        dead_pct_rank,
        mod_pct_rank,
        vacuum_dml_rank,
        read_rank,
        gets_rank,
        vacuum_rank,
        analyze_rank
      ) <= topn
      AND (ulst.server_id, ulst.sample_id, ulst.datid, ulst.in_sample) =
        (diff.server_id, diff.sample_id, diff.datid, false)
      AND (ulst.relid = diff.relid OR ulst.relid = diff.toastrelid);

    -- Growth rank is to be calculated independently of database stats_reset value
    UPDATE last_stat_tables ulst
    SET in_sample = true
    FROM (
      SELECT
          cur.server_id AS server_id,
          cur.sample_id AS sample_id,
          cur.datid AS datid,
          cur.relid AS relid,
          tcur.relid AS toastrelid,
          cur.relsize IS NOT NULL AS relsize_avail,
          cur.relpages_bytes IS NOT NULL AS relpages_avail,
          row_number() OVER (ORDER BY cur.relsize - COALESCE(lst.relsize, 0) +
            COALESCE(tcur.relsize,0) - COALESCE(tlst.relsize, 0) DESC NULLS LAST) growth_rank,
          row_number() OVER (ORDER BY cur.relpages_bytes - COALESCE(lst.relpages_bytes, 0) +
            COALESCE(tcur.relpages_bytes,0) - COALESCE(tlst.relpages_bytes, 0) DESC NULLS LAST) pagegrowth_rank
      FROM
        -- main relations diff
        last_stat_tables cur
        LEFT OUTER JOIN last_stat_tables lst ON
          (lst.server_id, lst.sample_id, lst.datid, lst.relid) =
          (cur.server_id, cur.sample_id - 1, cur.datid, cur.relid)
        -- toast relations diff
        LEFT OUTER JOIN last_stat_tables tcur ON
          (tcur.server_id, tcur.sample_id, tcur.datid, tcur.relid) =
          (cur.server_id, cur.sample_id, cur.datid, cur.reltoastrelid)
        LEFT OUTER JOIN last_stat_tables tlst ON
          (tlst.server_id, tlst.sample_id, tlst.datid, tlst.relid) =
          (lst.server_id, lst.sample_id, lst.datid, lst.reltoastrelid)
      WHERE cur.sample_id=s_id AND cur.server_id=sserver_id
        AND cur.relkind IN ('r','m')) diff
    WHERE
      ((relsize_avail AND growth_rank <= topn) OR
      ((NOT relsize_avail) AND relpages_avail AND pagegrowth_rank <= topn))
      AND (ulst.server_id, ulst.sample_id, ulst.datid, in_sample) =
        (diff.server_id, diff.sample_id, diff.datid, false)
      AND (ulst.relid = diff.relid OR ulst.relid = diff.toastrelid);

    /* Also mark tables having marked indexes on them including main
    * table in case of a TOAST index and TOAST table if index is on
    * main table
    */
    UPDATE last_stat_tables ulst
    SET in_sample = true
    FROM
      last_stat_indexes ix
      JOIN last_stat_tables tbl USING (server_id, sample_id, datid, relid)
      LEFT JOIN last_stat_tables mtbl ON
        (mtbl.server_id, mtbl.sample_id, mtbl.datid, mtbl.reltoastrelid) =
        (tbl.server_id, tbl.sample_id, tbl.datid, tbl.relid)
    WHERE
      (ix.server_id, ix.sample_id, ix.in_sample) =
      (sserver_id, s_id, true)
      AND (ulst.server_id, ulst.sample_id, ulst.datid, ulst.in_sample) =
        (tbl.server_id, tbl.sample_id, tbl.datid, false)
      AND ulst.relid IN (tbl.relid, tbl.reltoastrelid, mtbl.relid);

    -- Insert marked objects statistics increments
    -- New table names
    INSERT INTO tables_list (
      server_id,
      datid,
      relid,
      relkind,
      reltoastrelid,
      schemaname,
      relname
    )
    SELECT
      cur.server_id,
      cur.datid,
      cur.relid,
      cur.relkind,
      NULLIF(cur.reltoastrelid, 0),
      cur.schemaname,
      cur.relname
    FROM
      last_stat_tables cur
      LEFT JOIN tables_list tl USING (server_id, datid, relid)
    WHERE
      (cur.server_id, cur.in_sample) =
      (sserver_id, true)
      AND tl.server_id IS NULL
    ;

    -- Tables
    INSERT INTO sample_stat_tables (
      server_id,
      sample_id,
      datid,
      relid,
      tablespaceid,
      seq_scan,
      seq_tup_read,
      idx_scan,
      idx_tup_fetch,
      n_tup_ins,
      n_tup_upd,
      n_tup_del,
      n_tup_hot_upd,
      n_live_tup,
      n_dead_tup,
      n_mod_since_analyze,
      n_ins_since_vacuum,
      last_vacuum,
      last_autovacuum,
      last_analyze,
      last_autoanalyze,
      vacuum_count,
      autovacuum_count,
      analyze_count,
      autoanalyze_count,
      heap_blks_read,
      heap_blks_hit,
      idx_blks_read,
      idx_blks_hit,
      toast_blks_read,
      toast_blks_hit,
      tidx_blks_read,
      tidx_blks_hit,
      relsize,
      relsize_diff,
      relpages_bytes,
      relpages_bytes_diff
    )
    SELECT
      cur.server_id AS server_id,
      cur.sample_id AS sample_id,
      cur.datid AS datid,
      cur.relid AS relid,
      cur.tablespaceid AS tablespaceid,
      cur.seq_scan - COALESCE(lst.seq_scan,0) AS seq_scan,
      cur.seq_tup_read - COALESCE(lst.seq_tup_read,0) AS seq_tup_read,
      cur.idx_scan - COALESCE(lst.idx_scan,0) AS idx_scan,
      cur.idx_tup_fetch - COALESCE(lst.idx_tup_fetch,0) AS idx_tup_fetch,
      cur.n_tup_ins - COALESCE(lst.n_tup_ins,0) AS n_tup_ins,
      cur.n_tup_upd - COALESCE(lst.n_tup_upd,0) AS n_tup_upd,
      cur.n_tup_del - COALESCE(lst.n_tup_del,0) AS n_tup_del,
      cur.n_tup_hot_upd - COALESCE(lst.n_tup_hot_upd,0) AS n_tup_hot_upd,
      cur.n_live_tup AS n_live_tup,
      cur.n_dead_tup AS n_dead_tup,
      cur.n_mod_since_analyze AS n_mod_since_analyze,
      cur.n_ins_since_vacuum AS n_ins_since_vacuum,
      cur.last_vacuum AS last_vacuum,
      cur.last_autovacuum AS last_autovacuum,
      cur.last_analyze AS last_analyze,
      cur.last_autoanalyze AS last_autoanalyze,
      cur.vacuum_count - COALESCE(lst.vacuum_count,0) AS vacuum_count,
      cur.autovacuum_count - COALESCE(lst.autovacuum_count,0) AS autovacuum_count,
      cur.analyze_count - COALESCE(lst.analyze_count,0) AS analyze_count,
      cur.autoanalyze_count - COALESCE(lst.autoanalyze_count,0) AS autoanalyze_count,
      cur.heap_blks_read - COALESCE(lst.heap_blks_read,0) AS heap_blks_read,
      cur.heap_blks_hit - COALESCE(lst.heap_blks_hit,0) AS heap_blks_hit,
      cur.idx_blks_read - COALESCE(lst.idx_blks_read,0) AS idx_blks_read,
      cur.idx_blks_hit - COALESCE(lst.idx_blks_hit,0) AS idx_blks_hit,
      cur.toast_blks_read - COALESCE(lst.toast_blks_read,0) AS toast_blks_read,
      cur.toast_blks_hit - COALESCE(lst.toast_blks_hit,0) AS toast_blks_hit,
      cur.tidx_blks_read - COALESCE(lst.tidx_blks_read,0) AS tidx_blks_read,
      cur.tidx_blks_hit - COALESCE(lst.tidx_blks_hit,0) AS tidx_blks_hit,
      cur.relsize AS relsize,
      cur.relsize - COALESCE(lst.relsize,0) AS relsize_diff,
      cur.relpages_bytes AS relpages_bytes,
      cur.relpages_bytes - COALESCE(lst.relpages_bytes,0) AS relpages_bytes_diff
    FROM
      last_stat_tables cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
      LEFT JOIN last_stat_database dblst ON
        (dblst.server_id, dblst.sample_id, dblst.datid, dblst.stats_reset) =
        (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid, dbcur.stats_reset)
      LEFT OUTER JOIN last_stat_tables lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.relid) =
        (dblst.server_id, dblst.sample_id, dblst.datid, cur.relid)
    WHERE
      (cur.server_id, cur.sample_id, cur.in_sample) = (sserver_id, s_id, true);

    -- Update incorrectly calculated relation growth in case of database stats reset
    UPDATE sample_stat_tables usst
    SET
      relsize_diff = cur.relsize - COALESCE(lst.relsize,0),
      relpages_bytes_diff = cur.relpages_bytes - COALESCE(lst.relpages_bytes,0)
    FROM
      last_stat_tables cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
      JOIN last_stat_database dblst ON
        (dblst.server_id, dblst.sample_id, dblst.datid) =
        (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid)
      LEFT OUTER JOIN last_stat_tables lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.relid) =
        (dblst.server_id, dblst.sample_id, dblst.datid, cur.relid)
    WHERE
      (cur.server_id, cur.sample_id, cur.in_sample) = (sserver_id, s_id, true)
      AND dblst.stats_reset != dbcur.stats_reset
      AND (usst.server_id, usst.sample_id, usst.datid, usst.relid) =
        (cur.server_id, cur.sample_id, cur.datid, cur.relid);

    -- Total table stats
    INSERT INTO sample_stat_tables_total(
      server_id,
      sample_id,
      datid,
      tablespaceid,
      relkind,
      seq_scan,
      seq_tup_read,
      idx_scan,
      idx_tup_fetch,
      n_tup_ins,
      n_tup_upd,
      n_tup_del,
      n_tup_hot_upd,
      vacuum_count,
      autovacuum_count,
      analyze_count,
      autoanalyze_count,
      heap_blks_read,
      heap_blks_hit,
      idx_blks_read,
      idx_blks_hit,
      toast_blks_read,
      toast_blks_hit,
      tidx_blks_read,
      tidx_blks_hit,
      relsize_diff
    )
    SELECT
      cur.server_id,
      cur.sample_id,
      cur.datid,
      cur.tablespaceid,
      cur.relkind,
      sum(cur.seq_scan - COALESCE(lst.seq_scan,0)),
      sum(cur.seq_tup_read - COALESCE(lst.seq_tup_read,0)),
      sum(cur.idx_scan - COALESCE(lst.idx_scan,0)),
      sum(cur.idx_tup_fetch - COALESCE(lst.idx_tup_fetch,0)),
      sum(cur.n_tup_ins - COALESCE(lst.n_tup_ins,0)),
      sum(cur.n_tup_upd - COALESCE(lst.n_tup_upd,0)),
      sum(cur.n_tup_del - COALESCE(lst.n_tup_del,0)),
      sum(cur.n_tup_hot_upd - COALESCE(lst.n_tup_hot_upd,0)),
      sum(cur.vacuum_count - COALESCE(lst.vacuum_count,0)),
      sum(cur.autovacuum_count - COALESCE(lst.autovacuum_count,0)),
      sum(cur.analyze_count - COALESCE(lst.analyze_count,0)),
      sum(cur.autoanalyze_count - COALESCE(lst.autoanalyze_count,0)),
      sum(cur.heap_blks_read - COALESCE(lst.heap_blks_read,0)),
      sum(cur.heap_blks_hit - COALESCE(lst.heap_blks_hit,0)),
      sum(cur.idx_blks_read - COALESCE(lst.idx_blks_read,0)),
      sum(cur.idx_blks_hit - COALESCE(lst.idx_blks_hit,0)),
      sum(cur.toast_blks_read - COALESCE(lst.toast_blks_read,0)),
      sum(cur.toast_blks_hit - COALESCE(lst.toast_blks_hit,0)),
      sum(cur.tidx_blks_read - COALESCE(lst.tidx_blks_read,0)),
      sum(cur.tidx_blks_hit - COALESCE(lst.tidx_blks_hit,0)),
      CASE
        WHEN skip_sizes THEN NULL
        ELSE sum(cur.relsize - COALESCE(lst.relsize,0))
      END
    FROM last_stat_tables cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
      LEFT OUTER JOIN last_stat_database dblst ON
        (dblst.server_id, dblst.datid, dblst.sample_id, dblst.stats_reset) =
        (dbcur.server_id, dbcur.datid, dbcur.sample_id - 1, dbcur.stats_reset)
      LEFT OUTER JOIN last_stat_tables lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.relid) =
        (dblst.server_id, dblst.sample_id, dblst.datid, cur.relid)
    WHERE (cur.server_id, cur.sample_id) = (sserver_id, s_id)
    GROUP BY cur.server_id, cur.sample_id, cur.datid, cur.relkind, cur.tablespaceid;

    IF NOT skip_sizes THEN
    /* Update incorrectly calculated aggregated tables growth in case of
     * database statistics reset
     */
      UPDATE sample_stat_tables_total usstt
      SET relsize_diff = calc.relsize_diff
      FROM (
          SELECT
            cur.server_id,
            cur.sample_id,
            cur.datid,
            cur.relkind,
            cur.tablespaceid,
            sum(cur.relsize - COALESCE(lst.relsize,0)) AS relsize_diff
          FROM last_stat_tables cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
            JOIN last_stat_database dblst ON
              (dblst.server_id, dblst.sample_id, dblst.datid) =
              (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid)
            LEFT OUTER JOIN last_stat_tables lst ON
              (lst.server_id, lst.sample_id, lst.datid, lst.relid) =
              (dblst.server_id, dblst.sample_id, dblst.datid, cur.relid)
          WHERE (cur.server_id, cur.sample_id) = (sserver_id, s_id)
            AND dblst.stats_reset != dbcur.stats_reset
          GROUP BY cur.server_id, cur.sample_id, cur.datid, cur.relkind, cur.tablespaceid
        ) calc
      WHERE (usstt.server_id, usstt.sample_id, usstt.datid, usstt.relkind, usstt.tablespaceid) =
        (calc.server_id, calc.sample_id, calc.datid, calc.relkind, calc.tablespaceid);

    END IF;
    /*
    Preserve previous relation sizes in if we couldn't collect
    size this time (for example, due to locked relation)*/
    UPDATE last_stat_tables cur
    SET relsize = lst.relsize
    FROM last_stat_tables lst
    WHERE
      (cur.server_id, cur.sample_id) = (sserver_id, s_id)
      AND (lst.server_id, lst.sample_id, lst.datid, lst.relid) =
      (cur.server_id, cur.sample_id - 1, cur.datid, cur.relid)
      AND cur.relsize IS NULL;

    IF (result #>> '{collect_timings}')::boolean THEN
      result := jsonb_set(result,'{timings,calculate tables stats,end}',to_jsonb(clock_timestamp()));
      result := jsonb_set(result,'{timings,calculate indexes stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- New index names
    INSERT INTO indexes_list (
      server_id,
      datid,
      indexrelid,
      relid,
      schemaname,
      indexrelname
    )
    SELECT
      cur.server_id,
      cur.datid,
      cur.indexrelid,
      cur.relid,
      cur.schemaname,
      cur.indexrelname
    FROM
      last_stat_indexes cur
      LEFT JOIN indexes_list il USING (server_id, datid, indexrelid)
    WHERE
      (cur.server_id, cur.in_sample) =
      (sserver_id, true)
      AND il.server_id IS NULL
    ;
    -- Index stats
    INSERT INTO sample_stat_indexes (
      server_id,
      sample_id,
      datid,
      indexrelid,
      tablespaceid,
      idx_scan,
      idx_tup_read,
      idx_tup_fetch,
      idx_blks_read,
      idx_blks_hit,
      relsize,
      relsize_diff,
      indisunique,
      relpages_bytes,
      relpages_bytes_diff
    )
    SELECT
      cur.server_id AS server_id,
      cur.sample_id AS sample_id,
      cur.datid AS datid,
      cur.indexrelid AS indexrelid,
      cur.tablespaceid AS tablespaceid,
      cur.idx_scan - COALESCE(lst.idx_scan,0) AS idx_scan,
      cur.idx_tup_read - COALESCE(lst.idx_tup_read,0) AS idx_tup_read,
      cur.idx_tup_fetch - COALESCE(lst.idx_tup_fetch,0) AS idx_tup_fetch,
      cur.idx_blks_read - COALESCE(lst.idx_blks_read,0) AS idx_blks_read,
      cur.idx_blks_hit - COALESCE(lst.idx_blks_hit,0) AS idx_blks_hit,
      cur.relsize,
      cur.relsize - COALESCE(lst.relsize,0) AS relsize_diff,
      cur.indisunique,
      cur.relpages_bytes AS relpages_bytes,
      cur.relpages_bytes - COALESCE(lst.relpages_bytes,0) AS relpages_bytes_diff
    FROM
      last_stat_indexes cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
      LEFT JOIN last_stat_database dblst ON
        (dblst.server_id, dblst.sample_id, dblst.datid, dblst.stats_reset) =
        (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid, dbcur.stats_reset)
      LEFT OUTER JOIN last_stat_indexes lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.indexrelid) =
        (dblst.server_id, dblst.sample_id, dblst.datid, cur.indexrelid)
    WHERE
      (cur.server_id, cur.sample_id, cur.in_sample) = (sserver_id, s_id, true);

    -- Update incorrectly calculated relation growth in case of database stats reset
    UPDATE sample_stat_indexes ussi
    SET
      relsize_diff = cur.relsize - COALESCE(lst.relsize,0),
      relpages_bytes_diff = cur.relpages_bytes - COALESCE(lst.relpages_bytes,0)
    FROM
      last_stat_indexes cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
      JOIN last_stat_database dblst ON
        (dblst.server_id, dblst.sample_id, dblst.datid) =
        (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid)
      LEFT OUTER JOIN last_stat_indexes lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.indexrelid) =
        (dblst.server_id, dblst.sample_id, dblst.datid, cur.indexrelid)
    WHERE
      (cur.server_id, cur.sample_id, cur.in_sample) = (sserver_id, s_id, true)
      AND dblst.stats_reset != dbcur.stats_reset
      AND (ussi.server_id, ussi.sample_id, ussi.datid, ussi.indexrelid) =
        (cur.server_id, cur.sample_id, cur.datid, cur.indexrelid);

    -- Total indexes stats
    INSERT INTO sample_stat_indexes_total(
      server_id,
      sample_id,
      datid,
      tablespaceid,
      idx_scan,
      idx_tup_read,
      idx_tup_fetch,
      idx_blks_read,
      idx_blks_hit,
      relsize_diff
    )
    SELECT
      cur.server_id,
      cur.sample_id,
      cur.datid,
      cur.tablespaceid,
      sum(cur.idx_scan - COALESCE(lst.idx_scan,0)),
      sum(cur.idx_tup_read - COALESCE(lst.idx_tup_read,0)),
      sum(cur.idx_tup_fetch - COALESCE(lst.idx_tup_fetch,0)),
      sum(cur.idx_blks_read - COALESCE(lst.idx_blks_read,0)),
      sum(cur.idx_blks_hit - COALESCE(lst.idx_blks_hit,0)),
      CASE
        WHEN skip_sizes THEN NULL
        ELSE sum(cur.relsize - COALESCE(lst.relsize,0))
      END
    FROM last_stat_indexes cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
      LEFT OUTER JOIN last_stat_database dblst ON
        (dblst.server_id, dblst.sample_id, dblst.datid, dblst.stats_reset) =
        (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid, dbcur.stats_reset)
      LEFT OUTER JOIN last_stat_indexes lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.relid, lst.indexrelid) =
        (dblst.server_id, dblst.sample_id, dblst.datid, cur.relid, cur.indexrelid)
    WHERE
      (cur.server_id, cur.sample_id) = (sserver_id, s_id)
    GROUP BY cur.server_id, cur.sample_id, cur.datid, cur.tablespaceid;

    /* Update incorrectly calculated aggregated index growth in case of
     * database statistics reset
     */
    IF NOT skip_sizes THEN
      UPDATE sample_stat_indexes_total ussit
      SET relsize_diff = calc.relsize_diff
      FROM (
          SELECT
            cur.server_id,
            cur.sample_id,
            cur.datid,
            cur.tablespaceid,
            sum(cur.relsize - COALESCE(lst.relsize,0)) AS relsize_diff
          FROM last_stat_indexes cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
            JOIN last_stat_database dblst ON
              (dblst.server_id, dblst.sample_id, dblst.datid) =
              (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid)
            LEFT OUTER JOIN last_stat_indexes lst ON
              (lst.server_id, lst.sample_id, lst.datid, lst.indexrelid) =
              (dblst.server_id, dblst.sample_id, dblst.datid, cur.indexrelid)
          WHERE (cur.server_id, cur.sample_id) = (sserver_id, s_id)
            AND dblst.stats_reset != dbcur.stats_reset
          GROUP BY cur.server_id, cur.sample_id, cur.datid, cur.tablespaceid
        ) calc
      WHERE (ussit.server_id, ussit.sample_id, ussit.datid, ussit.tablespaceid) =
        (calc.server_id, calc.sample_id, calc.datid, calc.tablespaceid);
    END IF;
    /*
    Preserve previous relation sizes in if we couldn't collect
    size this time (for example, due to locked relation)*/
    UPDATE last_stat_indexes cur
    SET relsize = lst.relsize
    FROM last_stat_indexes lst
    WHERE
      (cur.server_id, cur.sample_id) = (sserver_id, s_id)
      AND (lst.server_id, lst.sample_id, lst.datid, lst.indexrelid) =
      (cur.server_id, cur.sample_id - 1, cur.datid, cur.indexrelid)
      AND cur.relsize IS NULL;

    IF (result #>> '{collect_timings}')::boolean THEN
      result := jsonb_set(result,'{timings,calculate indexes stats,end}',to_jsonb(clock_timestamp()));
      result := jsonb_set(result,'{timings,calculate functions stats}',jsonb_build_object('start',clock_timestamp()));
    END IF;

    -- New function names
    INSERT INTO funcs_list (
      server_id,
      datid,
      funcid,
      schemaname,
      funcname,
      funcargs
    )
    SELECT
      cur.server_id,
      cur.datid,
      cur.funcid,
      cur.schemaname,
      cur.funcname,
      cur.funcargs
    FROM
      last_stat_user_functions cur
      LEFT JOIN funcs_list fl USING (server_id, datid, funcid)
    WHERE
      (cur.server_id, cur.in_sample) =
      (sserver_id, true)
      AND fl.server_id IS NULL
    ;

    -- Function stats
    INSERT INTO sample_stat_user_functions (
      server_id,
      sample_id,
      datid,
      funcid,
      calls,
      total_time,
      self_time,
      trg_fn
    )
    SELECT
      cur.server_id AS server_id,
      cur.sample_id AS sample_id,
      cur.datid AS datid,
      cur.funcid,
      cur.calls - COALESCE(lst.calls,0) AS calls,
      cur.total_time - COALESCE(lst.total_time,0) AS total_time,
      cur.self_time - COALESCE(lst.self_time,0) AS self_time,
      cur.trg_fn
    FROM last_stat_user_functions cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
      LEFT OUTER JOIN last_stat_database dblst ON
        (dblst.server_id, dblst.sample_id, dblst.datid, dblst.stats_reset) =
        (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid, dbcur.stats_reset)
      LEFT OUTER JOIN last_stat_user_functions lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.funcid) =
        (dblst.server_id, dblst.sample_id, dblst.datid, cur.funcid)
    WHERE
      (cur.server_id, cur.sample_id, cur.in_sample) = (sserver_id, s_id, true);

    -- Total functions stats
    INSERT INTO sample_stat_user_func_total(
      server_id,
      sample_id,
      datid,
      calls,
      total_time,
      trg_fn
    )
    SELECT
      cur.server_id,
      cur.sample_id,
      cur.datid,
      sum(cur.calls - COALESCE(lst.calls,0)),
      sum(cur.total_time - COALESCE(lst.total_time,0)),
      cur.trg_fn
    FROM last_stat_user_functions cur JOIN last_stat_database dbcur USING (server_id, sample_id, datid)
      LEFT OUTER JOIN last_stat_database dblst ON
        (dblst.server_id, dblst.sample_id, dblst.datid, dblst.stats_reset) =
        (dbcur.server_id, dbcur.sample_id - 1, dbcur.datid, dbcur.stats_reset)
      LEFT OUTER JOIN last_stat_user_functions lst ON
        (lst.server_id, lst.sample_id, lst.datid, lst.funcid) =
        (dblst.server_id, dblst.sample_id, dblst.datid, cur.funcid)
    WHERE
      (cur.server_id, cur.sample_id) = (sserver_id, s_id)
    GROUP BY cur.server_id, cur.sample_id, cur.datid, cur.trg_fn;

    IF (result #>> '{collect_timings}')::boolean THEN
      result := jsonb_set(result,'{timings,calculate functions stats,end}',to_jsonb(clock_timestamp()));
    END IF;

    -- Clear data in last_ tables, holding data only for next diff sample
    DELETE FROM last_stat_tables WHERE server_id=sserver_id AND sample_id != s_id;

    DELETE FROM last_stat_indexes WHERE server_id=sserver_id AND sample_id != s_id;

    DELETE FROM last_stat_user_functions WHERE server_id=sserver_id AND sample_id != s_id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION show_samples(IN server name,IN days integer = NULL)
RETURNS TABLE(
    sample integer,
    sample_time timestamp (0) with time zone,
    sizes_collected boolean,
    dbstats_reset timestamp (0) with time zone,
    bgwrstats_reset timestamp (0) with time zone,
    archstats_reset timestamp (0) with time zone)
SET search_path=@extschema@ AS $$
  SELECT
    s.sample_id,
    s.sample_time,
    count(relsize_diff) > 0 AS sizes_collected,
    max(nullif(db1.stats_reset,coalesce(db2.stats_reset,db1.stats_reset))) AS dbstats_reset,
    max(nullif(bgwr1.stats_reset,coalesce(bgwr2.stats_reset,bgwr1.stats_reset))) AS bgwrstats_reset,
    max(nullif(arch1.stats_reset,coalesce(arch2.stats_reset,arch1.stats_reset))) AS archstats_reset
  FROM samples s JOIN servers n USING (server_id)
    JOIN sample_stat_database db1 USING (server_id,sample_id)
    JOIN sample_stat_cluster bgwr1 USING (server_id,sample_id)
    JOIN sample_stat_tables_total USING (server_id,sample_id)
    LEFT OUTER JOIN sample_stat_archiver arch1 USING (server_id,sample_id)
    LEFT OUTER JOIN sample_stat_database db2 ON (db1.server_id = db2.server_id AND db1.datid = db2.datid AND db2.sample_id = db1.sample_id - 1)
    LEFT OUTER JOIN sample_stat_cluster bgwr2 ON (bgwr1.server_id = bgwr2.server_id AND bgwr2.sample_id = bgwr1.sample_id - 1)
    LEFT OUTER JOIN sample_stat_archiver arch2 ON (arch1.server_id = arch2.server_id AND arch2.sample_id = arch1.sample_id - 1)
  WHERE (days IS NULL OR s.sample_time > now() - (days || ' days')::interval)
    AND server_name = server
  GROUP BY s.sample_id, s.sample_time
  ORDER BY s.sample_id ASC
$$ LANGUAGE sql;
COMMENT ON FUNCTION show_samples(IN server name,IN days integer) IS 'Display available server samples';

CREATE FUNCTION show_samples(IN days integer = NULL)
RETURNS TABLE(
    sample integer,
    sample_time timestamp (0) with time zone,
    sizes_collected boolean,
    dbstats_reset timestamp (0) with time zone,
    clustats_reset timestamp (0) with time zone,
    archstats_reset timestamp (0) with time zone)
SET search_path=@extschema@ AS $$
    SELECT * FROM show_samples('local',days);
$$ LANGUAGE sql;
COMMENT ON FUNCTION show_samples(IN days integer) IS 'Display available samples for local server';

CREATE FUNCTION get_sized_bounds(IN sserver_id integer, IN start_id integer, IN end_id integer)
RETURNS TABLE(
  left_bound    integer,
  right_bound   integer
)
SET search_path=@extschema@ AS $$
SELECT
  left_bound.sample_id AS left_bound,
  right_bound.sample_id AS right_bound
FROM (
    SELECT
      sample_id
    FROM
      sample_stat_tables_total
    WHERE
      server_id = sserver_id
      AND sample_id >= end_id
    GROUP BY
      sample_id
    HAVING
      count(relsize_diff) > 0
    ORDER BY sample_id ASC
    LIMIT 1
  ) right_bound,
  (
    SELECT
      sample_id
    FROM
      sample_stat_tables_total
    WHERE
      server_id = sserver_id
      AND sample_id <= start_id
    GROUP BY
      sample_id
    HAVING
      count(relsize_diff) > 0
    ORDER BY sample_id DESC
    LIMIT 1
  ) left_bound
$$ LANGUAGE sql;
