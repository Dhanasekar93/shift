# AGENTS.md

## Cursor Cloud specific instructions

### Overview

Shift is an online MySQL schema migration tool consisting of three components:
- **UI** (`ui/`): Rails 4.2 app on Ruby 2.2 — web UI + REST API (port 3000)
- **Runner** (`runner/`): Go agent that polls the API and executes migrations via `pt-online-schema-change`
- **pt-osc patch** (`ptosc-patch/`): Percona Toolkit patch

### System dependencies (pre-installed in snapshot)

- **Ruby 2.2.10** via RVM at `~/.rvm/rubies/ruby-2.2.10`
- **OpenSSL 1.0.2u** at `/opt/openssl-1.0.2u` (required to compile Ruby 2.2)
- **MySQL Connector/C 6.1.11** at `/opt/mysql-connector-c-6.1.11` (required for the `mysql2` 0.3.19 gem — MySQL 8.0 headers are incompatible)
- **MySQL 8.0** server (started with `--skip-ssl` for compatibility with the old connector)
- **MariaDB dev libraries** (`libmariadb-dev`, `libmariadb-dev-compat`) installed for build tooling

### Starting MySQL

MySQL must be started manually (no systemd in this container):

```bash
sudo /usr/sbin/mysqld --user=mysql --datadir=/var/lib/mysql --skip-ssl &
```

Wait ~5 seconds, then verify: `mysql -u root -proot -h 127.0.0.1 -e "SELECT 1;"`

Root credentials: `root` / `root` on host `127.0.0.1` (TCP only — socket access may have permission issues).

### Starting the Rails UI

```bash
source ~/.rvm/scripts/rvm && rvm use 2.2.10
export LD_LIBRARY_PATH=/opt/mysql-connector-c-6.1.11/lib:$LD_LIBRARY_PATH
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
cd /workspace/ui
bundle exec rails server -b 0.0.0.0 -p 3000
```

`LD_LIBRARY_PATH` is critical — without it, the `mysql2` gem cannot find `libmysqlclient.so.18`.

### Building and running the Go runner

```bash
export GO111MODULE=off
export GOPATH=/tmp/gopath:/workspace/runner/Godeps/_workspace
mkdir -p /tmp/gopath/src/github.com/square/shift
ln -sf /workspace/runner /tmp/gopath/src/github.com/square/shift/runner
cd /tmp/gopath/src/github.com/square/shift/runner
go build -o /workspace/runner/shift-runner .
cd /workspace/runner && ./shift-runner -logtostderr
```

### Running tests

- **Rails tests**: `cd /workspace/ui && bundle exec rake spec` (see `ui/README.md`)
- **Go tests**: `cd /tmp/gopath/src/github.com/square/shift/runner/pkg && go test ./...` (see `runner/README.md`)

### Key gotchas

1. **`LD_LIBRARY_PATH` must be set** before any Ruby process that loads `mysql2`. The gem is compiled against MySQL Connector/C 6.1.11 at `/opt/mysql-connector-c-6.1.11/lib`.
2. **MySQL must run with `--skip-ssl`** because the old Connector/C 6.1 library's OpenSSL usage is incompatible with the system OpenSSL 3.x.
3. **`SSL_CERT_FILE` must point to system CA certs** for `bundle install` to work, since Ruby 2.2's OpenSSL 1.0.2 lacks modern CA roots.
4. The `mysql2` 0.3.19 gem must be compiled against `/opt/mysql-connector-c-6.1.11` (not the system MySQL 8.0 headers). If you need to reinstall it: `gem install mysql2 -v '0.3.19' -- --with-mysql-config=/opt/mysql-connector-c-6.1.11/bin/mysql_config`
5. **Go runner uses Godep** (not Go modules). Set `GO111MODULE=off` and configure GOPATH with a symlink as shown above.
6. The `development.rb` config must have `mysql_helper.db_config` password matching the MySQL root password (`root`).
