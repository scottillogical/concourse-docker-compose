#!/bin/bash
set -eoux
set -x
./build.sh
docker run --privileged -t local.com/docker-dind echo "hi"
docker run --privileged -t local.com/docker-dind ls /usr/local/bin
