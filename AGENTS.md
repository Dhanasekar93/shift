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

### Slack notifications

Three config options (Bot Token is preferred):

**Option A** (preferred): `SLACK_BOT_TOKEN` + `SLACK_CHANNEL_ID`
**Option B**: Bot token in `SLACK_WEBHOOK_URL` + `SLACK_CHANNEL_ID` (auto-detected if value starts with `xoxb-`)
**Option C**: Incoming Webhook URL in `SLACK_WEBHOOK_URL` (starts with `https://hooks.slack.com/services/...`)

**Important**: Use the **Bot User OAuth Token** (`xoxb-...`) from OAuth & Permissions, NOT the App-Level Token (`xapp-...`) from Basic Information. App-level tokens will authenticate but return `not_allowed_token_type` on `chat.postMessage`. The bot needs `chat:write` scope. See `README.md` for full setup steps.

Slack messages include:
- Status-specific icons (rocket for start, checkmark for complete, etc.)
- Migration detail fields (ID, cluster, database, DDL, requestor, copy %)
- **Action buttons**: "Approve", "Start", and "Rename" appear contextually — clicking them triggers `/slack_actions/{approve,start,rename}` which performs the action and redirects to the migration detail page.

### Audit trail

Every state transition creates a `Comment` record with `[AUDIT]` prefix and UTC timestamp (author: `system` or `slack`). Visible in the migration detail page under "Comments". This provides a complete, tamper-evident history of who did what and when.

### Full migration lifecycle (ALTER TABLE with pt-osc)

1. **File** (UI/API) → status `preparing` (0), staged for runner
2. **Runner prepares** (dry-run pt-osc, collects table stats) → status `awaiting_approval` (1)
3. **Approve** (UI/API/CLI/Slack button) → status `awaiting_start` (2)
4. **Start** (UI/API/CLI/Slack button) → status `copy_in_progress` (3), staged for runner
5. **Runner copies rows** via pt-osc (progress % tracked) → status `awaiting_rename` (4)
6. **Rename** (UI/API/CLI/Slack button) → status `rename_in_progress` (5), staged for runner
7. **Runner renames tables** → status `completed` (8)

For CREATE/DROP TABLE: steps 5-6 are skipped (runner completes directly after step 4).

### pt-online-schema-change setup

The system `pt-online-schema-change` must have the Shift patch applied (adds `--exit-at`, `--save-state`). Applied via:
```bash
sudo patch /usr/bin/pt-online-schema-change /workspace/ptosc-patch/0001-ptosc-square-changes.patch
```
Also requires `YAML::Syck` Perl module: `sudo cpanm YAML::Syck`

### Custom options JSON compatibility

The `custom_options` blob in the migrations table must store values as **strings** (not integers) for Go 1.22 compatibility. E.g., `{"max_threads_running":"200"}` not `{"max_threads_running":200}`. The Rails `encodeCustomOptions` method stores integers by default; if filing via API, pass string values.
