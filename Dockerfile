FROM flowdocker/postgresql:0.1.63

ADD . /opt/schema
WORKDIR /opt/schema

RUN service postgresql start && \
    ./install.sh && \
    service postgresql stop

USER "postgres"
CMD ["/usr/lib/postgresql/11/bin/postgres", "-i", "-D", "/var/lib/postgresql/11/main"]
