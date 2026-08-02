#!/usr/bin/env bash
# Usage: bash 00-common/cleanup.sh [--delete-cluster]
# cjons-lab으로 확인된 대상만 정리하며 전역 kubeconfig를 사용하지 않는다.
set -u

COMMON_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$COMMON_DIR/lab_env.sh"

echo '[1/3] M2/M4 실습 컨테이너 정리'
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  for container in cjons-m2-oom cjons-m2-disk cjons-m2-hang; do
    docker rm -f "$container" >/dev/null 2>&1 || true
  done
  if docker compose version >/dev/null 2>&1; then
    docker compose -p cjons-m4 -f "$CJONS_LAB_ROOT/m4-ha-design/docker-compose.yml" \
      down -v --remove-orphans >/dev/null 2>&1 || true
  fi
fi

echo '[2/3] cjons-lab 내 실습 namespace 정리'
if require_lab_context >/dev/null 2>&1; then
    # api-server ns와 PriorityClass는 M6 isolation-pattern.yaml이 만든다.
  kubectl delete namespace cj-lab-traffic cj-lab-resources cj-lab-trouble cj-lab-ai api-server \
    --ignore-not-found --wait=true --timeout=90s || true
  kubectl delete priorityclass high-priority-api --ignore-not-found --timeout=30s || true
else
  echo '[SKIP] cjons-lab 전용 kubeconfig가 없어 Kubernetes 정리를 건너뜁니다.'
fi

echo '[3/3] 완료'
if [ "${1:-}" = '--delete-cluster' ]; then
  if command -v kind >/dev/null 2>&1; then
    kind delete cluster --name "$CJONS_CLUSTER_NAME"
  fi
elif [ -n "${1:-}" ]; then
  echo "Usage: $0 [--delete-cluster]" >&2
  exit 2
fi
