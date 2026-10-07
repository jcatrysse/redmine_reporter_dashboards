# This plugin together with 30 GEOxyz plugins

Redmine 7.0-stable-GEOxyz, PostgreSQL 16, production mode, fresh database, 2026-10-07. Installed
next to this plugin: every GEOxyz plugin on its `redmine70-migration` branch except the eight
that still `alias_method` core `Issue`/`IssueQuery`/`Query`/`ProjectsHelper` methods (see
`../geoxyz-all-with-alias-chains/` and docs/REDMINE7-MIGRATION.md, "Together with every GEOxyz
plugin"). Liquid resolves to 4.0.4 here (redmineup 1.1.13). Result: smoke 30, core flows 6, nine
plugin scenarios, 0 problems.
