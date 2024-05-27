#!/bin/bash

# Function to check Docker Compose file existence and extract image and version
check_docker_compose() {
  local file="docker-compose-elasticsearch-v$1.yaml"
  if [ -f "$file" ]; then
    echo "Docker Compose file $file exists"
    # Extract image and version from the Docker Compose file
    local image=$(grep -oP 'image: \K(.+)' "$file")
    local version=$(grep -oP 'tag: \K(.+)' "$file")
    # Update the name field in the GitHub Actions workflow file
    sed -i "s/name: CIT Elasticsearch/name: CIT Elasticsearch\n  image: $image\n  version: $version/" .github/workflows/main.yml
    echo "Updated name field with image: $image and version: $version"
    # Store the compose file for later use
    echo "$file"
  else
    echo "Docker Compose file $file not found"
    echo ""
  fi
}

# Function to run Elasticsearch using docker run
setup_es_docker_run() {
  local tag=$1
  local image=docker.elastic.co/elasticsearch/elasticsearch
  local params=(
    --detach
    --publish 9200:9200
    --env "http.host=0.0.0.0"
    --env "transport.host=127.0.0.1"
    --env "xpack.security.enabled=false"
  )
  local major_version=${tag%%.*}
  if (( major_version < 8 )); then
    params+=(--env "xpack.monitoring.enabled=false")
  else
    params+=(--env "xpack.monitoring.collection.enabled=false")
  fi
  if (( major_version > 7 )); then
    params+=(--env "action.destructive_requires_name=false")
  fi

  local cid
  cid=$(docker run "${params[@]}" "${image}:${tag}")
  echo "cid=${cid}" >> "$GITHUB_OUTPUT"
  echo "${cid}"
}

# Function to run OpenSearch using docker run
setup_opensearch_docker_run() {
  local image=opensearchproject/opensearch
  local tag=$1
  local params=(
    --detach
    --publish 9200:9200
    --env "http.host=0.0.0.0"
    --env "transport.host=127.0.0.1"
    --env "plugins.security.disabled=true"
  )
  local cid
  cid=$(docker run "${params[@]}" "${image}:${tag}")
  echo "cid=${cid}" >> "$GITHUB_OUTPUT"
  echo "${cid}"
}

# Check for both versions of Docker Compose files
compose_file_7=$(check_docker_compose 7)
compose_file_8=$(check_docker_compose 8)

# If either compose file is found, bring up the services using docker-compose
if [ -n "$compose_file_7" ]; then
  docker-compose -f "$compose_file_7" up -d
  use_docker_compose=true
elif [ -n "$compose_file_8" ]; then
  docker-compose -f "$compose_file_8" up -d
  use_docker_compose=true
else
  use_docker_compose=false
fi

# Rest of your script...
PS4='T$(date "+%H:%M:%S") '
set -euxf -o pipefail

# use global variables to reflect status of db
db_is_up=

usage() {
  echo $"Usage: $0 <elasticsearch|opensearch> <version>"
  exit 1
}

check_arg() {
  if [ ! $# -eq 3 ]; then
    echo "ERROR: need exactly two arguments, <elasticsearch|opensearch> <image> <jaeger-version>"
    usage
  fi
}

wait_for_storage() {
  local distro=$1
  local url=$2
  local cid=$3
  local params=(
    --silent
    --output
    /dev/null
    --write-out
    "%{http_code}"
  )
  local counter=0
  local max_counter=60
  while [[ "$(curl "${params[@]}" "${url}")" != "200" && ${counter} -le ${max_counter} ]]; do
    echo "waiting for ${url} to be up..."
    sleep 10
    counter=$((counter+1))
  done
  # after the loop, do final verification and set status as global var
  if [[ "$(curl "${params[@]}" "${url}")" != "200" ]]; then
    echo "ERROR: ${distro} is not ready"
    if [ "$use_docker_compose" = true ]; then
      docker-compose logs
    else
      docker logs "${cid}"
      docker kill "${cid}"
    fi
    db_is_up=0
  else
    echo "SUCCESS: ${distro} is ready"
    db_is_up=1
  fi
}

bring_up_storage() {
  local distro=$1
  local version=$2
  local cid

  echo "starting ${distro} ${version}"
  for retry in 1 2 3
  do
    echo "attempt $retry"
    if [ "$distro" = "elasticsearch" ]; then
      if [ "$use_docker_compose" = false ]; then
        cid=$(setup_es_docker_run "${version}")
      fi
    elif [ "$distro" = "opensearch" ]; then
      if [ "$use_docker_compose" = false ]; then
        cid=$(setup_opensearch_docker_run "${version}")
      fi
    else
      echo "Unknown distribution $distro. Valid options are opensearch or elasticsearch"
      usage
    fi
    wait_for_storage "${distro}" "http://localhost:9200" "${cid}"
    if [ ${db_is_up} = "1" ]; then
      break
    fi
  done
  if [ ${db_is_up} = "1" ]; then
    # shellcheck disable=SC2064
    trap "teardown_storage ${cid}" EXIT
  else
    echo "ERROR: unable to start ${distro}"
    exit 1
  fi
}

teardown_storage() {
  if [ "$use_docker_compose" = true ]; then
    docker-compose down
  else
    local cid=$1
    docker kill "${cid}"
  fi
}

main() {
  check_arg "$@"
  local distro=$1
  local es_version=$2
  local j_version=$3

  bring_up_storage "${distro}" "${es_version}"

  if [[ "${j_version}" == "v2" ]]; then
    STORAGE=${distro} SPAN_STORAGE_TYPE=${distro} make jaeger-v2-storage-integration-test
  else
    STORAGE=${distro} make storage-integration-test
    make index-cleaner-integration-test
    make index-rollover-integration-test
  fi
}

main "$@"
