# pg_profile changelog
## 4.10
- Support of *pg_stat_kcache* 2.3.1
- Support of PostgreSQL 18 statistics
- Support of *pg_stat_statements* 1.12

## 4.9
- Added table and index storage parameter sections (@blackstranger, @Djoongaar)
- Report design refactored (@Djoongaar)
- Fixed left 'idle in transaction' sesssion after take_sample() call
- objects, functions and statements statistics can be excluded from
  sample using *set_server_setting()* function
- Accurate relation sizes collection is disabled for the new
  installations (@blackstranger)
- Minor optimizations

## 4.8
- Added database extension version section
- Add possibility to exclude some databases from report

## 4.7
- support of PostgreSQL 17 cluster statistics
- support of *pg_stat_statements* 1.11
- support of *pg_stat_kcache* 2.3.0
- *pg_stat_statements_reset()* call can be skipped now
- visualisation of session states timeline (@Djoongaar)
- *take_sample()* function inherits *lock_timeout* setting
- *md5()* hash replaced by *sha224()* to avoid errors in FIPS mode
- other bugfixes #100, #105

## 4.6
- Query text preview available in all query statistic sections
- Hidable report contents on the left edge
- The new subsample feature allows to track session states and include them in the report. See [Subsamples](doc/pg_profile.md#subsamples)
- New grafana dashboard *pg_profile_activity* visualizing session states distribution over time using the data collected by subsamples. See [Grafana README](grafana/README.md)
- Added database version section to the top of the report

## 4.5
- Fix broken *take_sample()* function after performing a sample during execution of *pg_repack*
- Test stability improved for *retention_and_baselines* test

## 4.4
- Query text preview in "Top SQL by ..." report sections (@Djoongaar)
- Substring-based report entries filter (@Djoongaar)
- Samples import rewritten. Import performance improved for huge dumps
- *pg_stat_kcache* 2.2.3 supported

## 4.3
- Postgres 16 supported
- data collection supported for *pg_stat_slru*
- New report section "Cluster I/O statistics" (for Postgres 16)
- New report section "Cluster SLRU statistics"
- New report section "Top tables by new-page updated tuples" (for Postgres 16)
- Highlight of topics in table of contents sidebar containing selected object data (@Djoongaar)
- Privileges. Every user can now build a report, but the *pg_read_all_stats* role must be granted to user to see query texts. See [Privileges](doc/pg_profile.md#privileges)

## 4.2
- Interactive reports.
- _max_sample_age_ field added to the output of show_servers() function. (Reported by @bat-manav in #40)
- WAL LSN of report bounds is now shown in "Cluster statistics" section
- Fixed #62 reported by @portnov - incorrect values in V15 before sirst statistics reset
- Support of temporary I/O time statistics for statements from _pg_stat_statements_ extension.
- Fixed #65 reported by @pkonotopov - Idle in transaction timeout during a sample.
- #66 implemented. Now the take_sample(text, boolean) function returns the result of the operation.
- Manual objects creation script fixed. #64 reported by @ Poleon-Na

## 4.1
- Avoid serialization of parallel samples (#48 by @xinferum) caused by locking due to analyze operations.
- Fixed retention of last statements data. The new statements sample taking procedure implemented in 4.0 contained a bug - the obsolete data was not deleted from last_ tables. Update to 4.1 will fix this error and cleanup all obsolete data.
- Support of PostgreSQL 15 (*pg_stat_statements* v1.10) data collection
- JIT statistic section will appear in report for *pg_stat_statements* v1.10 (implemented by @Djoongaar).

## 4.0
- Corrected nested-level statements support (#37)
- Added username field in statement-related sections
- Statement statistics collection optimized
- _pg_stat_kcache_ 2.2.1 (#39)

## 3.9
- Support of the *pg_wait_sampling* extension
- Manual samples delete functions (reported by @xinferum in #30)
- Obsolete samples management optimized
- bugfix: take_sample() function was waited on a lock on servers table entry due to missplaced lock check routine

## 3.8
- Checksum failures detection
- Server name prefix for importing server names to avoid name conflicts during import
- Added Block I/O times in Database statistics section
- Report generation engine completely rewritten for future improvements
- Other fixes and optimizations

## 3.7
- per-database checksum_failures is tracked and reported if detected during report interval
- fixed session statistics import
- fixed error in the docs #27

## 0.3.6
- WAL fields in statements by blocks dirtied report section
- *pg_class.relpages* is collected in samples now. This data is used in estimations while *pg_relations_size()* data is unavailable due to relation size collection policy.
- set application_name while taking a sample
- fixed #29 reported by @xinferum (relation size collection window)
- query texts in reports is now truncated to 20 000 characters by default
- internal fixes and optimizations
- fixed #31 reported by @sgrinko "ERROR: integer out of range" while collecting relation size data based on pg_class.relpages

## 0.3.5
- WAL fields in statements by blocks dirtied report section
- *pg_class.relpages* is collected in samples now. This data is used in estimations while *pg_relations_size()* data is unavailable due to relation size collection policy.
- set application_name while taking a sample
- fixed #29 reported by xinferum (relation size collection window)
- query texts in reports is now truncated to 20 000 characters by default
- internal fixes and optimizations

## 0.3.4
- support of new statistics of Postgres 14 (session and WAL statistics).
- optimized report building.
- limited relations sizes collection with defined _size collection policy_ will now collect sizes for only seq-scanned or vacuumed tables in each sample providing useful estimations in reports without overall database objects size collections.
- fixed incorrect database growth value in case of database statistics reset in a report interval.
- interval bounds in the report contains timezone now (reported by @antiorum in #21).
- fixed settings collection. pg_profile dump could not be loaded if there was a postgres updrage on the source system.
- fixed statements aggregation in report tables. Due to different query texts the same statement could appear several times in one report section making it difficult to realize workload of the statement.

## 0.3.3
- minor fix: Field _~SeqBytes_ of report section "Top tables by estimated sequentially scanned volume" was having value of first interval in cells of first and second interval.

## 0.3.2
- restored statements _queryid_ compatibility with current version of pgcenter utility
- query text storage improved
- linear interpolation of relation sizes slightly optimized

## 0.3.1
- relation sizes collection policy added
- data export and import feature added
- support of pg_stat_kcache extension version 2.2.0
- server description added
- FIX: template databases are now detected by pg_database.datistemplate field

## 0.2.1
- detailed sample taking timings collection feature.
- removed unmeaning zeros from report tables
- Latest two samples report function get_report_latest() added.
- FIX: time range based report-generating calls seldom failed. Reported by @cuprumtan
- FIX: kcache v.2.1.3 support #11 by @guilhermebrike
- FIX: field %Elapsed of sections "Top SQL by planning time" and "Top SQL by execution time"
- FIX: corrected statistics reset detection condition
- FIX: corrected diff reports join condition
- pg_stat_statements *queryid* field is shown in reports
- fixes and optimizations

## 0.1.4
- snapshot() function now tracks time elapsed taking sample on each server
- Top indexes by blocks fetched/read report section now contains index scan count field
- New _take_sample_subset()_ function can be used in parallel samples collection in case of many servers.
- fix of #9 reported by @Guzya - incorrect database and tablespace size in report

## 0.1.3
- Hotfix of #8 reported by @cuprumtan

## 0.1.2

- pg_stat_statements version 1.8 support:
  - Statement planning time
  - Statement WAL generation
- fix: "Hit(%)" field was incorrectly calculated
- Baseline creation on time range is now supported
- CPU timings are now shown in "Top SQL by elapsed time" if kcache extension was available
- I/O timing statistics added to "Statements statistics by database" section
- "WAL segments archived" and "WAL segments archive failed" statistics added to "Cluster statistics" section
- Workaround for pg_table_size and AccessExclusiveLocks. Now in many cases snapshot will be taken successfully without size of locked relation.
- Top vacuum and analyze count tables in reports
- Implicit index vacuum I/O load estimation
- Added trigger functions timing statistics
- Many pg_profile functions renamed to be more standard-compatible (see [doc/pg_profile.md](https://github.com/zubkov-andrei/pg_profile/blob/0.1.2/doc/pg_profile.md) file)
  - *gets* renamed to *fetches*
  - *snapshots* renamed to *samples*, and *snapshot()* function renamed to *take_sample()*, but for backward compatibility *snapshot()* call is possible.
  - *retention* renamed to *max_sample_age*
  - *node* renamed to *server*
  - *pages* renamed to *blocks*
- fixed issue #7 reported by @kayform
- Added a lot of table header hints

## 0.1.1

Due to total refactoring done in this release, migration from 0.0.7 is very difficult, so right now migration from 0.0.7 is not supported.

- Code reorganization, new Makefile
- Sequential scanned table now sorted by scanned pages estimation
- Order correction in top tables by read IO
- TOAST tables is now calculated and shown with main tables
- More fields in "Top SQL by I/O wait time" section
- Non-superuser install (see Privileges in doc)
- Collect postgres GUC parameters historic values and show them in reports
- Tablespaces support: size, growth and objects belong (Daria Vilkova)
- Fixed object rename issue
- New sections in report: "Top SQL by shared dirtied", "Top SQL by shared written", "Top tables by gets", "Top indexes by gets"
- Improved statement list in reports - now clicked statement_id is highlighted
- Workaround for amazon RDS
- Database sizes is now shown in reports (Daria Vilkova)
- Reports can be generated using time intervals (tstzrange type)
- *snapshot_show()* now displays info about stats reset, also report contains information about stats reset
- a lot of bugfixes and other improvements

## 0.0.7

- Interval compare reports
- Sequential scans now ordered by appox. seq. scanned pages (based on relation size)
- Added report examples in repository (issue #5 reported by @saifulmuhajir)
- Simplified baseline management for local node

## 0.0.6
- Collect data from other PostgreSQL clusters

## 0.0.5a
- bugfix: In index stats base relation size was displayed as IX size

## 0.0.5
- Growth column in "Databases stats" report section
- Bgwriter and WAL-generation stats in new report section "Cluster stats"
- Explicit lock_timeout setting to 5 minutes in snapshot functions
- Snapshot now uses pg_advisory_lock on "magic" number 2174049485089987259. More than one snapshot() functions running is not allowed.
- "Top SQL by temp usage" section now shows temp utilization for workareas in "Work_" columns, and for temporary tables in "Local_" columns. Thanks, @lesovsky
- New report section section "Top Delete/Update tables with vacuum run count"
- New report section "Top growing indexes"
- Tables, Indexes and Functions names moved to dedicated tables


## 0.0.4a
- bugfix of #1 with postgresql on non-standard port, thanks @triwada

## 0.0.4
- queryid in pgCenter style
- normalized query storage table
- fixed report bug when processing statements with html tags
- minor fixes

## 0.0.3
- Baseline feature (exclude snapshots from default retention policy)
- Functions for displaying available snapshots and baselines
- Minor optimizations in report building functions

## 0.0.2
- extension parameters pg_profile.topn and pg_profile.retention

## 0.0.1
- first alpha version

