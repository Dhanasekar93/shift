# compile runner
FROM golang:1.6 as builder

RUN go get github.com/tools/godep
COPY runner /go/src/github.com/square/shift/runner
RUN cd /go/src/github.com/square/shift/runner \
    && godep get ./... \
    && CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o runner .

# ui / runner runtime
FROM ruby:2.2

ENV MYSQL_PWD root
RUN echo "mysql-server mysql-server/root_password password $MYSQL_PWD" | debconf-set-selections
RUN echo "mysql-server mysql-server/root_password_again password $MYSQL_PWD" | debconf-set-selections

# install deps
RUN apt-get update && apt-get install -y \
    build-essential \
    cpanminus \
    libdbd-mysql-perl \
    libdbi-perl \
    libgmp3-dev \
    libio-socket-ssl-perl \
    libterm-readkey-perl \
    libyaml-perl \
    lsb-core \
    patch \
    perl \
    ruby-dev \
    nginx \ 
    net-tools \
    apache2-utils \
    mysql-client \
    mysql-server \
    supervisor --fix-missing --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# install pt-toolkit
COPY ptosc-patch /opt/code/ptosc-patch
RUN cpanm YAML::Syck \
    && chown -R mysql.mysql /var/lib/mysql

RUN wget https://www.percona.com/downloads/percona-toolkit/3.0.13/source/tarball/percona-toolkit-3.0.13.tar.gz && tar -xf percona-toolkit-3.0.13.tar.gz && cd percona-toolkit-3.0.13/bin && patch pt-online-schema-change /opt/code/ptosc-patch/0001-ptosc-square-changes.patch && cp -r pt-* /usr/local/bin/ && chmod +x /usr/local/bin/*;
# RUN groupadd mysql \
#     useradd -r -g mysql -s /bin/false mysql \
#     cd /usr/local \
#     wget https://dev.mysql.com/get/Downloads/MySQL-8.0/mysql-8.0.17-linux-x86_64-minimal.tar.xz -O /tmp/mysql-8.0.17-linux-x86_64-minimal.tar.xz \
#     tar xf /tmp/mysql-8.0.17-linux-x86_64-minimal.tar.xz \
#     mv /usr/local/mysql-8.0.17-linux-x86_64-minimal mysql \
#     cd mysql \
#     mkdir mysql-files \
#     chown mysql:mysql mysql-files \
#     chmod 750 mysql-files \
#     bin/mysqld --initialize --user=mysql \
#     bin/mysql_ssl_rsa_setup \
#     bin/mysqld_safe --user=mysql & \
#     cp support-files/mysql.server /etc/init.d/mysql_80

# copy / install ui
COPY ui/Gemfile ui/Gemfile.lock /opt/code/ui/
RUN cd /opt/code/ui \
    && bundle install
COPY ui /opt/code/ui

# copy runner executable
COPY --from=builder /go/src/github.com/square/shift/runner/runner /opt/code/runner/

# create shift log dir
RUN mkdir -p /tmp/shift

# clean apt cache
RUN apt-get clean

# copying entrypoint script
COPY docker-entrypoint.sh /opt/code/

# runtime
WORKDIR /opt/code
EXPOSE 80

ENV RAILS_ENV production

ENTRYPOINT ["/opt/code/docker-entrypoint.sh"]
CMD ["supervisord", "-n"]

# TODO:
# patch ui/app/controllers/application_controller.rb to support cert-based account system
