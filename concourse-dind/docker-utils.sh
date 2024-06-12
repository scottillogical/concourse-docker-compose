#!/usr/bin/env bash
LOG_FILE=${LOG_FILE:-/var/log/docker.log}
SKIP_PRIVILEGED=${SKIP_PRIVILEGED:-false}
STARTUP_TIMEOUT=${STARTUP_TIMEOUT:-120}
MAX_CONCURRENT_DOWNLOADS=${MAX_CONCURRENT_DOWNLOADS:-""}
MAX_CONCURRENT_UPLOADS=${MAX_CONCURRENT_UPLOADS:-""}
INSECURE_REGISTRY=${INSECURE_REGISTRY:-""}
REGISTRY_MIRROR=${REGISTRY_MIRROR:-""}
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

check_privileged() {
    set +e
    ip link add dummy0 type dummy >/dev/null 2>&1
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}This docker image needs to be run with --privileged${NC}" >&2
        exit 2
    fi
    ip link de dummy0 >/dev/null 2>&1
    set -e
}

sanitize_cgroups() {
  if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
    return
  fi

  mkdir -p /sys/fs/cgroup
  mountpoint -q /sys/fs/cgroup || \
    mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup /sys/fs/cgroup

  mount -o remount,rw /sys/fs/cgroup

  sed -e 1d /proc/cgroups | while read sys hierarchy num enabled; do
    if [ "$enabled" != "1" ]; then
      # subsystem disabled; skip
      continue
    fi

    grouping="$(cat /proc/self/cgroup | cut -d: -f2 | grep "\\<$sys\\>")" || true
    if [ -z "$grouping" ]; then
      # subsystem not mounted anywhere; mount it on its own
      grouping="$sys"
    fi

    mountpoint="/sys/fs/cgroup/$grouping"

    mkdir -p "$mountpoint"

    # clear out existing mount to make sure new one is read-write
    if mountpoint -q "$mountpoint"; then
      umount "$mountpoint"
    fi

    mount -n -t cgroup -o "$grouping" cgroup "$mountpoint"

    if [ "$grouping" != "$sys" ]; then
      if [ -L "/sys/fs/cgroup/$sys" ]; then
        rm "/sys/fs/cgroup/$sys"
      fi

      ln -s "$mountpoint" "/sys/fs/cgroup/$sys"
    fi
  done

  if [ ! -e /sys/fs/cgroup/systemd ] && [ $(cat /proc/self/cgroup | grep '^1:name=openrc:' | wc -l) -eq 0 ]; then
    mkdir /sys/fs/cgroup/systemd
    mount -t cgroup -o none,name=systemd none /sys/fs/cgroup/systemd
  fi
}

start_docker() {
  echo "Starting Docker..."

  if [ -f /var/run/docker.pid ]; then
    echo -e "${YELLOW}Docker is already running${NC}"
    return 2
  fi

  mkdir -p /var/log
  mkdir -p /var/run

  if [ "$SKIP_PRIVILEGED" = "false" ]; then
    check_privileged

    sanitize_cgroups

    # check for /proc/sys being mounted readonly, as systemd does
    if grep '/proc/sys\s\+\w\+\s\+ro,' /proc/mounts >/dev/null; then
      mount -o remount,rw /proc/sys
    fi
  fi

  local mtu=$(cat /sys/class/net/$(ip route get 8.8.8.8|awk '{ print $5 }')/mtu)
  local server_args="--mtu ${mtu}"
  local registry=""

  if [ -n "$MAX_CONCURRENT_DOWNLOADS" ]; then
    server_args="${server_args} --max-concurrent-downloads=$MAX_CONCURRENT_DOWNLOADS"
  fi

  if [ -n "$MAX_CONCURRENT_UPLOADS" ]; then
    server_args="${server_args} --max-concurrent-uploads=$MAX_CONCURRENT_UPLOADS"
  fi

  for registry in $INSECURE_REGISTRY; do
    server_args="${server_args} --insecure-registry ${registry}"
  done

  if [ -n "$REGISTRY_MIRROR" ]; then
    server_args="${server_args} --registry-mirror $REGISTRY_MIRROR"
  fi

  export server_args LOG_FILE
  trap stop_docker EXIT

  try_start() {
    # The official dind entrypoint script seems to be too unstable with concourse
    # causing random docker start failures
    #/usr/local/bin/dockerd-entrypoint.sh ${server_args} >$LOG_FILE 2>&1 &
    dockerd --data-root /var/lib/docker ${server_args} >$LOG_FILE 2>&1 &

    sleep 1

    echo waiting for docker to come up...
    until docker info >/dev/null 2>&1; do
      sleep 1
      if ! kill -0 "$(cat /var/run/docker.pid)" 2>/dev/null; then
        return 1
      fi
    done
  }

  if [ "$(command -v declare)" ]; then
    declare -fx try_start

    if ! timeout ${STARTUP_TIMEOUT} bash -ce 'while true; do try_start && break; done'; then
      [ -f "$LOG_FILE" ] && cat "${LOG_FILE}"
      echo -e "${RED}Docker failed to start within ${STARTUP_TIMEOUT} seconds${NC}" >&2
      return 1
    fi
  else
    try_start
  fi
}

stop_docker() {
  echo "Stopping Docker..."

  if [ ! -f /var/run/docker.pid ]; then
    return 0
  fi

  local pid=$(cat /var/run/docker.pid)
  if [ -z "$pid" ]; then
    return 0
  fi

  kill -TERM $pid
  rm /var/run/docker.pid
}

log_in() {
  local username="$1"
  local password="$2"
  local registry="$3"

  if [ -n "${username}" ] && [ -n "${password}" ]; then
    echo "${password}" | docker login -u "${username}" --password-stdin ${registry}
  else
    mkdir -p ~/.docker
    touch ~/.docker/config.json
    # This ensures the resulting JSON object remains syntactically valid
    echo "$(cat ~/.docker/config.json){\"credsStore\":\"ecr-login\"}" | jq -s add > ~/.docker/config.json
  fi
}

private_registry() {
  local repository="${1}"

  local registry="$(extract_registry "${repository}")"
  if echo "${registry}" | grep -q -x '.*[.:].*' ; then
    return 0
  fi

  return 1
}

extract_registry() {
  local repository="${1}"

  echo "${repository}" | cut -d/ -f1
}

extract_repository() {
  local long_repository="${1}"

  echo "${long_repository}" | cut -d/ -f2-
}

image_from_tag() {
  docker images --no-trunc "$1" | awk "{if (\$2 == \"$2\") print \$3}"
}

image_from_digest() {
  docker images --no-trunc --digests "$1" | awk "{if (\$3 == \"$2\") print \$4}"
}

certs_to_file() {
  local raw_ca_certs="${1}"
  local cert_count="$(echo $raw_ca_certs | jq -r '. | length')"

  for i in $(seq 0 $(expr "$cert_count" - 1));
  do
    local cert_dir="/etc/docker/certs.d/$(echo $raw_ca_certs | jq -r .[$i].domain)"
    mkdir -p "$cert_dir"
    echo $raw_ca_certs | jq -r .[$i].cert >> "${cert_dir}/ca.crt"
  done
}

set_client_certs() {
  local raw_client_certs="${1}"
  local cert_count="$(echo $raw_client_certs | jq -r '. | length')"

  for i in $(seq 0 $(expr "$cert_count" - 1));
  do
    local cert_dir="/etc/docker/certs.d/$(echo $raw_client_certs | jq -r .[$i].domain)"
    [ -d "$cert_dir" ] || mkdir -p "$cert_dir"
    echo $raw_client_certs | jq -r .[$i].cert >> "${cert_dir}/client.cert"
    echo $raw_client_certs | jq -r .[$i].key >> "${cert_dir}/client.key"
  done
}

docker_load() {
    images=${1}
    for i in ${images}; do
      echo "Loading ${i} ..."
      docker load -qi ${i} || ( echo -e "${RED}Failed to load image ${i}${NC}" >&2 && exit 1 ) &
    done

    # Waiting for all docker images to be loaded
    for i in $(seq 1 300); do
      if ! jobs | grep -q "docker load"; then
        echo -e "${GREEN}All docker images have been loaded!${NC}"
        break
      fi
      sleep 1
    done
}

docker_pull() {
  pull_attempt=1
  max_attempts=3
  while [ "$pull_attempt" -le "$max_attempts" ]; do
    printf "Pulling ${GREEN}%s${NC}" "$1"

    if [ "$pull_attempt" != "1" ]; then
      printf " (attempt %s of %s)" "$pull_attempt" "$max_attempts"
    fi

    printf "...\n"

    if docker pull "$1"; then
      printf "\nSuccessfully pulled ${GREEN}%s${NC}.\n\n" "$1"
      return 0
    fi

    echo

    pull_attempt=$(expr "$pull_attempt" + 1)
  done

  printf "\n${RED}Failed to pull image %s${NC}" "$1" >&2
  return 1
}
