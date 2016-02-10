#!/usr/bin/env bash

POSTGRES_URLS=${PGBOUNCER_URLS:-DATABASE_URL}
POOL_MODE=${PGBOUNCER_POOL_MODE:-transaction}
SERVER_RESET_QUERY=${PGBOUNCER_SERVER_RESET_QUERY}
n=1

# if the SERVER_RESET_QUERY and pool mode is session, pgbouncer recommends DISCARD ALL be the default
# http://pgbouncer.projects.pgfoundry.org/doc/faq.html#_what_should_my_server_reset_query_be
if [ -z "${SERVER_RESET_QUERY}" ] &&  [ "$POOL_MODE" == "session" ]; then
  SERVER_RESET_QUERY="DISCARD ALL;"
fi

# Enable this option to prevent stunnel failure with Amazon RDS when a dyno resumes after sleeping
if [ -z "${ENABLE_STUNNEL_AMAZON_RDS_FIX}" ]; then
  AMAZON_RDS_STUNNEL_OPTION=""
else
  AMAZON_RDS_STUNNEL_OPTION="options = NO_TICKET"
fi

mkdir -p /app/vendor/stunnel/var/run/stunnel/
cat >> /app/vendor/stunnel/stunnel-pgbouncer.conf << EOFEOF
foreground = yes

options = NO_SSLv2
options = SINGLE_ECDH_USE
options = SINGLE_DH_USE
socket = r:TCP_NODELAY=1
options = NO_SSLv3
${AMAZON_RDS_STUNNEL_OPTION}
ciphers = HIGH:!ADH:!AECDH:!LOW:!EXP:!MD5:!3DES:!SRP:!PSK:@STRENGTH
debug = ${PGBOUNCER_STUNNEL_LOGLEVEL:-notice}
EOFEOF

cat >> /app/vendor/pgbouncer/pgbouncer.ini << EOFEOF
[pgbouncer]
listen_addr = localhost
listen_port = 6000
auth_type = md5
auth_file = /app/vendor/pgbouncer/users.txt

; When server connection is released back to pool:
;   session      - after client disconnects
;   transaction  - after transaction finishes
;   statement    - after statement finishes
pool_mode = ${POOL_MODE}
server_reset_query = ${SERVER_RESET_QUERY}
max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN:-100}
default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE:-1}
min_pool_size = ${PGBOUNCER_MIN_POOL_SIZE:-0}
reserve_pool_size = ${PGBOUNCER_RESERVE_POOL_SIZE:-1}
reserve_pool_timeout = ${PGBOUNCER_RESERVE_POOL_TIMEOUT:-5.0}
server_lifetime = ${PGBOUNCER_SERVER_LIFETIME:-3600}
server_idle_timeout = ${PGBOUNCER_SERVER_IDLE_TIMEOUT:-600}
log_connections = ${PGBOUNCER_LOG_CONNECTIONS:-1}
log_disconnections = ${PGBOUNCER_LOG_DISCONNECTIONS:-1}
log_pooler_errors = ${PGBOUNCER_LOG_POOLER_ERRORS:-1}
stats_period = ${PGBOUNCER_STATS_PERIOD:-60}

; PW modification: enable hard-coded user name which can issue the
; SHOW commands to get stats from pgbouncer.
;
; - jhw@prosperworks.com, 2016-02-09
;
stats_users = pgbouncer-stats

[databases]
EOFEOF

for POSTGRES_URL in $POSTGRES_URLS
do
  eval POSTGRES_URL_VALUE=\$$POSTGRES_URL
  IFS=':' read DB_USER DB_PASS DB_HOST DB_PORT DB_NAME <<< $(echo $POSTGRES_URL_VALUE | perl -lne 'print "$1:$2:$3:$4:$5" if /^postgres(?:ql)?:\/\/([^:]*):([^@]*)@(.*?):(.*?)\/(.*?)$/')

  DB_MD5_PASS="md5"`echo -n ${DB_PASS}${DB_USER} | md5sum | awk '{print $1}'`

  CLIENT_DB_NAME="db${n}"

  echo "Setting ${POSTGRES_URL}_PGBOUNCER config var"

  if [ "$PGBOUNCER_PREPARED_STATEMENTS" == "false" ]
  then
    export ${POSTGRES_URL}_PGBOUNCER=postgres://$DB_USER:$DB_PASS@127.0.0.1:6000/$CLIENT_DB_NAME?prepared_statements=false
  else
    export ${POSTGRES_URL}_PGBOUNCER=postgres://$DB_USER:$DB_PASS@127.0.0.1:6000/$CLIENT_DB_NAME
  fi

  cat >> /app/vendor/stunnel/stunnel-pgbouncer.conf << EOFEOF
[$POSTGRES_URL]
client = yes
protocol = pgsql
accept  = /tmp/.s.PGSQL.610${n}
connect = $DB_HOST:$DB_PORT
retry = ${PGBOUNCER_CONNECTION_RETRY:-"no"}
EOFEOF


  # The password field for pgbouncer-stats was computed like so:
  #
  #   echo -n PASSWORDpgbouncer-user | md5sum | awk '{print $1}'
  #
  # ...except PASSWORD was something else.  See ali/bin/launcher.sh
  # for the actual password.
  #
  # This is as above where DB_MD5_PASS is calculated, and also per
  # https://pgbouncer.github.io/config.html, in the section
  # "Authentication file format".
  #
  # - jhw@prosperworks.com, 2016-02-09
  #
  cat >> /app/vendor/pgbouncer/users.txt << EOFEOF
"$DB_USER" "$DB_MD5_PASS"
"pgbouncer-stats" "md5dfeafe5f5d25a3393d3dfa6f2d8d8d8c"
EOFEOF

  cat >> /app/vendor/pgbouncer/pgbouncer.ini << EOFEOF
$CLIENT_DB_NAME= dbname=$DB_NAME port=610${n}
EOFEOF

  let "n += 1"
done

chmod go-rwx /app/vendor/pgbouncer/*
chmod go-rwx /app/vendor/stunnel/*
