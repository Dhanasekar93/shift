#!/bin/bash

# render runner config
mkdir -p /opt/code/runner/config

printf "[client]
user     = ${RUNNER_MYSQL_USER}
password = ${RUNNER_MYSQL_PASS}
host 	 = ${RUNNER_MYSQL_HOST}
" > /opt/code/runner/config/my_production.cnf

printf "# config for the database client
mysql_user: ${RUNNER_MYSQL_USER}
mysql_password: ${RUNNER_MYSQL_PASS}
mysql_cert: ${RUNNER_MYSQL_CERT}
mysql_key: ${RUNNER_MYSQL_KEY}
mysql_rootCA: ${RUNNER_MYSQL_ROOTCA}
mysql_defaults_file: config/my_production.cnf

# config for the rest client
rest_api: http://127.0.0.1:3000/api/v1/
rest_cert:
rest_key:

# general config
log_dir: /tmp/shift/
pt_osc_path: pt-online-schema-change
enable_trash: ${RUNNER_ENABLE_TRASH:-false}
pending_drops_db: ${RUNNER_PENDING_DROPS_DB}
log_sync_interval: ${RUNNER_LOG_SYNC_INTERVAL:-10}
state_sync_interval: ${RUNNER_STATE_SYNC_INTERVAL:-10}
stop_file_path: /tmp/shift-stop/stop_shift_runner

# optionally override the host/port/db to run an OSC on
host_override: ${RUNNER_HOST_OVERRIDE}
port_override: ${RUNNER_PORT_OVERRIDE}
database_override: ${RUNNER_DATABASE_OVERRIDE}
" > /opt/code/runner/config/production-config.yaml

# TODO:
# patch ui/config/environments/production.rb at runtime in this script
# for now, we modify it directly in place

# render supervisord config
mkdir -p /etc/supervisor/conf.d
printf "[program:shift-ui]
command = bundle exec rails server -b 0.0.0.0 -p 3000
directory = /opt/code/ui/
autostart = true
stdout_logfile = /dev/stdout
stdout_logfile_maxbytes = 0
redirect_stderr = true

[program:shift-runner]
command = /opt/code/runner/runner
directory = /opt/code/runner/
autostart = true
stdout_logfile = /dev/stdout
stdout_logfile_maxbytes = 0
redirect_stderr = true

[program:nginx]
priority = 4
command = nginx -g 'daemon off;'
stdout_logfile = /var/log/nginx.log
stderr_logfile = /var/log/nginx.log
autostart = true

[program:mysql]
priority = 4
command = mysqld
autostart = true
" > /etc/supervisor/conf.d/shift.conf

echo "server {
	listen 80 default_server;
	server_name _;
	auth_basic 'Restricted Access! Mydbops Monitoring';
	auth_basic_user_file /etc/nginx/conf.d/.htpasswd;
	root /opt/code/ui/public;

	location / {
		proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Host \$host:\$proxy_port;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-NginX-Proxy true;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_redirect off;
		include  /etc/nginx/mime.types;
	}
}" > /etc/nginx/sites-enabled/default


if [ -n "${SERVER_PASSWORD}" -a -z "${UPDATE_MODE}" ]; then
	SERVER_USER=${SERVER_USER:-mydbops}
	SERVER_PASSWORD=${SERVER_PASSWORD:-DBops474}
    htpasswd -cb /etc/nginx/conf.d/.htpasswd ${SERVER_USER} ${SERVER_PASSWORD}
fi

export ENVIRONMENT="production"
export PATH="/usr/local/bin:/usr/local/bundle/bin:$PATH"
export RAILS_ENV="production"
export RAILS_SERVE_STATIC_FILES=1

exec "$@"
