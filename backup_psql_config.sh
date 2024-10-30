#!/bin/bash
tar -czvf /opt/backups/configs/"`date +%d-%m-%Y`"-postgresql_configs.tar.gz /etc/postgresql/14/main &&
tar -czvf /opt/backups/configs/"`date +%d-%m-%Y`"-pgbouncer_configs.tar.gz /etc/pgbouncer &&
tar -czvf /opt/backups/configs/"`date +%d-%m-%Y`"-signers_jcp_jdk_configs.tar.gz /opt/registerx/jcp/ &&
cp -v /opt/postgresql/.bash_history /opt/backups/configs/ &&
cp -v /opt/postgresql/.psql_history /opt/backups/configs/ &&
find "/opt/backups/configs" -type f -mtime +5 -exec rm {} \;
