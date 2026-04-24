MIGRATION = \
	$(EXTENSION)--4.11--$(PGPROFILE_VERSION).sql

$(EXTENSION)--4.11--4.13.sql: migration/func_drop.sql migration/func_create.sed \
	migration/migration.sql data/report_templates.sql $(functions)
	sed \
	-e '1i \\\echo Use "ALTER EXTENSION $(EXTENSION) UPDATE" to load this file. \\quit' \
	$(sed_extension) \
	migration/func_drop.sql \
	schema/sequences.sql \
	sample/query_pg_stat_lock.sql \
	sample/calculate_lock_stats.sql \
	report/functions/sequences.sql \
	report/functions/stat_lock.sql \
	> $(EXTENSION)--4.11--4.13.sql;
	sed -n \
	$(sed_extension) \
	-f migration/func_create.sed \
	$(functions) \
	>> $(EXTENSION)--4.11--4.13.sql;
	sed \
	$(sed_extension) \
	migration/migration.sql  data/report_templates.sql \
	>> $(EXTENSION)--4.11--4.13.sql;
