#!/usr/bin/env bash

set -Eeuo pipefail

DEPLOYMENT_DIRECTORY="${DEPLOYMENT_DIRECTORY:-/opt/nodejs-aws-jenkins}"
COMPOSE_SERVICE="${COMPOSE_SERVICE:-nodejs-app}"
MAX_HEALTH_ATTEMPTS="${MAX_HEALTH_ATTEMPTS:-20}"
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-3}"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <image-repository> <image-tag>"
  exit 1
fi

IMAGE_REPOSITORY="$1"
IMAGE_TAG="$2"

if [[ -z "${IMAGE_REPOSITORY}" || -z "${IMAGE_TAG}" ]]; then
  echo "ERROR: Image repository and image tag must not be empty."
  exit 1
fi

if [[ ! -d "${DEPLOYMENT_DIRECTORY}" ]]; then
  echo "ERROR: Deployment directory does not exist:"
  echo "  ${DEPLOYMENT_DIRECTORY}"
  exit 1
fi

cd "${DEPLOYMENT_DIRECTORY}"

if [[ ! -f "compose.yaml" && \
      ! -f "compose.yml" && \
      ! -f "docker-compose.yaml" && \
      ! -f "docker-compose.yml" ]]; then
  echo "ERROR: No Docker Compose file found in:"
  echo "  ${DEPLOYMENT_DIRECTORY}"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed or not available in PATH."
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: Docker Compose V2 is not available."
  exit 1
fi

export IMAGE_REPOSITORY
export IMAGE_TAG

echo "===================================================="
echo "Application deployment"
echo "===================================================="
echo "Deployment directory: ${DEPLOYMENT_DIRECTORY}"
echo "Compose service:      ${COMPOSE_SERVICE}"
echo "Image repository:     ${IMAGE_REPOSITORY}"
echo "Image tag:            ${IMAGE_TAG}"
echo

echo "Validating Docker Compose configuration..."
docker compose config --quiet

echo "Pulling image: ${IMAGE_REPOSITORY}:${IMAGE_TAG}"
docker compose pull "${COMPOSE_SERVICE}"

echo "Starting application container..."
docker compose up \
  --detach \
  --remove-orphans \
  "${COMPOSE_SERVICE}"

container_id="$(
  docker compose ps \
    --quiet \
    "${COMPOSE_SERVICE}"
)"

if [[ -z "${container_id}" ]]; then
  echo "ERROR: No container was created for service:"
  echo "  ${COMPOSE_SERVICE}"

  docker compose ps
  docker compose logs --tail=100 "${COMPOSE_SERVICE}"

  exit 1
fi

echo "Container ID: ${container_id}"
echo "Waiting for the container health check..."

for ((attempt = 1; attempt <= MAX_HEALTH_ATTEMPTS; attempt++)); do
  container_status="$(
    docker inspect \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
      "${container_id}" \
      2>/dev/null || true
  )"

  echo "Attempt ${attempt}/${MAX_HEALTH_ATTEMPTS}: ${container_status:-not-found}"

  case "${container_status}" in
    healthy)
      echo
      echo "Deployment completed successfully."
      docker compose ps
      exit 0
      ;;

    unhealthy | exited | dead)
      echo
      echo "ERROR: Application container is ${container_status}."
      echo
      echo "Container status:"
      docker compose ps
      echo
      echo "Recent application logs:"
      docker compose logs \
        --tail=100 \
        "${COMPOSE_SERVICE}"
      exit 1
      ;;

    running | starting | created | restarting | "")
      sleep "${HEALTH_CHECK_INTERVAL}"
      ;;

    *)
      echo "Container is currently in state: ${container_status}"
      sleep "${HEALTH_CHECK_INTERVAL}"
      ;;
  esac
done

echo
echo "ERROR: Application did not become healthy before timeout."
echo
echo "Container status:"
docker compose ps
echo
echo "Recent application logs:"
docker compose logs \
  --tail=100 \ 
  "${COMPOSE_SERVICE}"

exit 1