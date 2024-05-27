#!/bin/bash

PS4='T$(date "+%H:%M:%S") '
set -euxf -o pipefail

usage() {
  echo $"Usage: $0 <elasticsearch|opensearch> <version> <jaeger-version>"
  exit 1
}

check_arg() {
  if [ ! $# -eq 3 ]; then
    echo "ERROR: need exactly three arguments, <elasticsearch|opensearch> <image> <jaeger-version>"
    usage
  fi
}

create_compose_file() {
  local distro=$1
  local version=$2
  cat > docker-compose-${distro}-v7.yaml <<EOL
version: '3.7'
services:
  ${distro}:
    image: docker.elastic.co/elasticsearch/elasticsearch:${version}
    ports:
      - "9200:9200"
    environment:
      - discovery.type=single-node
EOL
}

update_compose_file() {
  local distro=$1
  local version=$2
  if [ ! -f "docker-compose-${distro}-v7.yaml" ]; then
    create_compose_file "${distro}" "${version}"
  else
    sed -i "s/image: .*/image: docker.elastic.co\/elasticsearch\/elasticsearch:${version}/" docker-compose-${distro}-v7.yaml
  fi
}

setup_storage() {
  local distro=$1
  local version=$2
  local j_version=$3

  echo "Starting ${distro} ${version}"
  
  update_compose_file "${distro}" "${version}"
  
  docker-compose -f docker-compose-${distro}-v7.yaml up -d
}

wait_for_storage() {
  local distro=$1

  local counter=0
  local max_counter=60
  while [ "${counter}" -le "${max_counter}" ]; do
    if docker inspect "${distro}" >/dev/null 2>&1; then
      echo "${distro} is up"
      break
    else
      echo "Waiting for ${distro} to start..."
      sleep 10
      counter=$((counter + 1))
    fi
  done

  if [ "${counter}" -gt "${max_counter}" ]; then
    echo "Timeout waiting for ${distro} to start"
    exit 1
  fi
}

main() {
  check_arg "$@"

  local distro=$1
  local version=$2
  local j_version=$3

  setup_storage "${distro}" "${version}" "${j_version}"
  wait_for_storage "${distro}"

  if [ "${j_version}" == "v2" ]; then
    STORAGE="${distro}" SPAN_STORAGE_TYPE="${distro}" make jaeger-v2-storage-integration-test
  else
    STORAGE="${distro}" make storage-integration-test
    make index-cleaner-integration-test
    make index-rollover-integration-test
  fi

  docker-compose -f docker-compose-${distro}-v7.yaml down
}

main "$@"
