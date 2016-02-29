# dependency-postgresql

## Installation

    ./install.sh

## Initial deployment notes:

    sudo yum install http://yum.postgresql.org/9.4/redhat/rhel-6-x86_64/pgdg-ami201503-94-9.4-1.noarch.rpm
    sudo yum install -y postgresql94
    sudo yum install -y git
    sudo yum install -y ruby

    Install https://github.com/mbryzek/schema-evolution-manager

    echo "dependency.crqe2ozpjr64.us-east-1.rds.amazonaws.com:5432:dependency:api:PASSWORD" > ~/.pgpass
    chmod 0600 ~/.pgpass

    cd /web/dependency/schema
    sem-dist
    scp -i /web/keys/ssh/mbryzek-key-pair-us-east.pem dist/schema-0.0.1.tar.gz ec2-user@ADDRESS:~/
    ssh -i /web/keys/ssh/mbryzek-key-pair-us-east.pem ec2-user@54.175.54.172
    tar xfz schema-*.tar.gz
    cd schema-*

    sem-apply --user api --host TODO.rds.amazonaws.com --name dependency

