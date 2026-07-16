CREATE FUNCTION collect_tablespace_stats(IN sserver_id integer, IN ssample_id integer
) RETURNS void AS $collect_tablespace_stats$
begin
    -- Get tablespace stats
    /*
    * pg_tablespace_size can return NULL for unused tablespaces so we need to
    * ignore them
    */
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
      ssample_id,
      dbl.tablespaceid,
      dbl.tablespacename,
      dbl.tablespacepath,
      dbl.size AS size,
      dbl.size_delta AS size_delta
      FROM dblink('server_connection', $$
            SELECT oid as tablespaceid,
                   spcname as tablespacename,
                   pg_catalog.pg_tablespace_location(oid) as tablespacepath,
                   pg_catalog.pg_tablespace_size(oid) as size,
                   0 as size_delta
              FROM pg_catalog.pg_tablespace
              WHERE pg_catalog.pg_tablespace_size(oid) IS NOT NULL
            $$)
    AS dbl (
        tablespaceid            oid,
        tablespacename          name,
        tablespacepath          text,
        size                    bigint,
        size_delta              bigint
    );
    EXECUTE format('ANALYZE last_stat_tablespaces_srv%1$s',
      sserver_id);
end;
$collect_tablespace_stats$ LANGUAGE plpgsql;
