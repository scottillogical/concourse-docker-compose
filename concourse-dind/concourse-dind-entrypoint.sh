#!/usr/bin/env bash

set -e

source /opt/docker-utils.sh

start_docker

# Required or some images like vault fails to run properly
# @TODO search/explain the real reason
mount | grep "none on /tmp type tmpfs" >/dev/null && umount /tmp

"$@"
