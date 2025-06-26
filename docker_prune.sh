#!/bin/bash

docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
  | grep -Ev 'gradle:7\.4\.2-jdk17|gcr\.io/cadvisor/cadvisor' \
  | awk '{print $2}' \
  | sort -u \
  | xargs -r docker rmi -f

docker container prune -f
docker network prune -f
docker volume prune -f
