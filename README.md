# shift <img src="/ui/public/logo.png" height="40">
shift is an application that makes it easy to run online schema migrations for MySQL databases
<br><br><br>
<img src="/ui/screenshots/summary.png">
<br><br><br>

## Who should use it?
shift was designed to solve the following problem - running schema migrations manually takes too much time. As such, it is most effective when schema migrations are taking up too much of your time (ex: for an operations or DBA team at a large organization), but really it can be used by anyone. As of writing this, shift has had no problem running hundreds of migrations a day or running migrations that take over a week to complete.

## Features
* safe, online schema changes (invokes the tried-and-true pt-online-schema-change)
    * supports all "ALTER TABLE...", "CREATE TABLE...", or "DROP TABLE..." ddl
* a ui where you can see the status of migrations and run them with the click of a button
* self-service - out of the box, any user can file and run migrations, and an admin is only required to approve the ddl (this is all configurable though)
* shard support - easily run a single migration on any number of shards

## Components
shift consists of 3 components. Each component has its own readme with more details
* [ui](https://github.com/square/shift/tree/master/ui): a rails app where you can file, track, and run database migrations
* [runner](https://github.com/square/shift/tree/master/runner): a go agent that consumes jobs from an api exposed by the ui
* [pt-osc patch](https://github.com/square/shift/tree/master/ptosc-patch): a patch for pt-online-schema-change from the percona toolkit

## Demo
Watch a demo video [here](https://www.youtube.com/watch?v=u5L7PqIk--k)

## Installation
Read the installation guide [here](https://github.com/square/shift/wiki/Installation-Guide)

## License

Copyright (c) 2016 Square Inc. Distributed under the Apache 2.0 License.
See LICENSE file for further details.

---

## Run locally with `docker-compose`

If you haven't initialized database, do it first and do it only once:

```
# spin up db container
docker-compose up -d db

# wait for db container's own initialization to finish
docker-compose logs -f

# get docker mysql host
docker_mysql_host=`docker exec -it mydbops_mysql /bin/bash -c 'hostname -I'`

# then run db:setup task
docker-compose run --rm shift bash -c 'cd /opt/code/ui; bundle exec rake db:setup; mysql -u ${MYSQL_USER} -p ${MYSQL_PASSWORD} -h ${docker_mysql_host} -e "INSERT IGNORE INTO shift.clusters (name,app,rw_host,port,admin_review_required,is_staging) VALUES ('PRODUCTION','local-app','${RUNNER_MYSQL_HOST}','${RUNNER_MYSQL_PORT}',1,0);"'
```

after `db:setup`, you can spin up the whole stack:

```
docker-compose up
```

and access ui at `http://<ip>:3000`



INSERT IGNORE INTO shift.clusters (name,app,rw_host,port,admin_review_required,is_staging) VALUES ('localhost','local-app','127.0.0.1','3306',1,0);