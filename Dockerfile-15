FROM flowdocker/postgresql15:latest

ADD . /opt/schema
WORKDIR /opt/schema

RUN service postgresql start && \
    ./install.sh && \
    service postgresql stop

USER "postgres"
CMD ["/usr/lib/postgresql/15/bin/postgres", "-i", "-D", "/var/lib/postgresql/15/main"]
