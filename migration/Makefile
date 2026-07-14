MIGRATION = \
	$(EXTENSION)--4.14--$(PGPROFILE_VERSION).sql

$(EXTENSION)--4.14--4.15.sql: \
	migration/migration.sql
	sed \
	-e '1i \\\echo Use "ALTER EXTENSION $(EXTENSION) UPDATE" to load this file. \\quit' \
	$(sed_extension) \
	migration/migration.sql \
	>> $(EXTENSION)--4.14--4.15.sql;
