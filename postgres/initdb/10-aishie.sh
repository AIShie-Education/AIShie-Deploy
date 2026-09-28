#!/bin/sh
# The databases of AIShie Core and of the agent runtime, each owned by a role
# of its own. PostgreSQL's image runs this once, when its volume is empty,
# against the server it starts for the purpose.
#
# The passwords come from the container's environment (postgres.env), and
# psql reads them from there with \getenv: they are on no command line, and
# the SQL quotes them, whatever they hold. Neither the statements nor their
# errors are logged, so the passwords are not either.
#
# Each database is its owner's alone: the runtime's role cannot connect to
# Core's database, nor Core's to the runtime's.
set -eu

for name in AISHIE_CORE_DB_PASSWORD AISHIE_RUNTIME_DB_PASSWORD; do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "10-aishie.sh: $name is not set in postgres.env: see env/postgres.env.example" >&2
    exit 1
  fi
done
unset value

psql -v ON_ERROR_STOP=1 --no-psqlrc --username "${POSTGRES_USER:-postgres}" --dbname postgres <<'SQL'
\set VERBOSITY terse
\set SHOW_CONTEXT never
SET log_min_error_statement = panic;
SET log_statement = none;
\getenv core_pw AISHIE_CORE_DB_PASSWORD
\getenv runtime_pw AISHIE_RUNTIME_DB_PASSWORD
CREATE ROLE aishie_core LOGIN PASSWORD :'core_pw';
CREATE ROLE aishie_runtime LOGIN PASSWORD :'runtime_pw';
\unset core_pw
\unset runtime_pw
CREATE DATABASE aishie_core OWNER aishie_core;
CREATE DATABASE aishie_runtime OWNER aishie_runtime;
REVOKE ALL ON DATABASE aishie_core FROM PUBLIC;
REVOKE ALL ON DATABASE aishie_runtime FROM PUBLIC;
SQL
echo "10-aishie.sh: created the databases aishie_core and aishie_runtime, each with its own role"
