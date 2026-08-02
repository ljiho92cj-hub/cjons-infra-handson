#!/usr/bin/env bash
# 전용 kubeconfig의 cjons-lab kind 클러스터를 구성한다. 전역 kubeconfig는 변경하지 않는다.
set -euo pipefail

COMMON_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$COMMON_DIR/lab_env.sh"

command -v kind >/dev/null 2>&1 || { echo '[ERROR] kind가 없습니다.' >&2; exit 1; }
kind version 2>/dev/null | grep -Fq "$CJONS_KIND_VERSION" || {
  echo "[ERROR] kind $CJONS_KIND_VERSION이 필요합니다." >&2
  exit 1
}
docker info >/dev/null 2>&1 || { echo '[ERROR] Docker daemon이 응답하지 않습니다.' >&2; exit 1; }
for image in "$CJONS_NODE_IMAGE" "$CJONS_NGINX_IMAGE" "$CJONS_BUSYBOX_IMAGE" "$CJONS_M2_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 || {
    echo "[ERROR] 사전 이미지가 없습니다: $image" >&2
    echo '        bash 00-common/prefetch_assets.sh를 먼저 실행하세요.' >&2
    exit 1
  }
done
[ -s "$CJONS_METRICS_MANIFEST" ] || {
  echo '[ERROR] metrics-server manifest가 없습니다.' >&2
  echo "        없는 파일: $CJONS_METRICS_MANIFEST" >&2
  echo '        bash 00-common/prefetch_assets.sh를 먼저 실행하세요.' >&2
  exit 1
}

load_image_into_kind() {
  local image="$1"
  if kind load docker-image --name "$CJONS_CLUSTER_NAME" "$image"; then
    return
  fi

  # Docker의 containerd image store를 쓰는 Apple Silicon 환경에서는 kind가
  # --all-platforms로 없는 digest까지 가져오려다 실패할 수 있다. 현재 host
  # 플랫폼만 각 kind node에 가져오는 안전한 fallback으로 같은 이미지를 적재한다.
  local platform
  platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")"
  echo "[WARN] kind 기본 이미지 로드 실패. $platform 단일 플랫폼 import로 재시도: $image" >&2

  local node
  while IFS= read -r node; do
    [ -n "$node" ] || continue
    docker save "$image" |
      docker exec --privileged -i "$node" \
        ctr --namespace=k8s.io images import \
          --platform "$platform" --snapshotter=overlayfs -
  done < <(kind get nodes --name "$CJONS_CLUSTER_NAME")
}

mkdir -p "$CJONS_LAB_STATE"
echo "[INFO] OS=$CJONS_OS · 프로필=$CJONS_PROFILE · 노드수=$CJONS_EXPECTED_NODES · config=$(basename "$CJONS_KIND_CONFIG")"
if kind get clusters 2>/dev/null | grep -Fxq "$CJONS_CLUSTER_NAME"; then
  echo "[INFO] 기존 $CJONS_CLUSTER_NAME 클러스터를 재사용합니다."
  kind get kubeconfig --name "$CJONS_CLUSTER_NAME" > "$CJONS_KUBECONFIG"
else
  kind create cluster \
    --config "$CJONS_KIND_CONFIG" \
    --image "$CJONS_NODE_IMAGE" \
    --kubeconfig "$CJONS_KUBECONFIG"
fi

# 컨테이너 모드: kind가 기록한 https://127.0.0.1:<랜덤포트> 는 호스트 기준 주소라
# 실습 컨테이너 안에서는 닿지 않는다. kind가 제공하는 --internal kubeconfig(=kind 네트워크
# 내부 DNS 이름 https://<클러스터>-control-plane:6443)로 교체한다.
# 이 컨테이너는 lab.sh가 --network kind 로 띄우므로 해당 이름이 그대로 해석된다.
if [ "${CJONS_IN_CONTAINER:-0}" = "1" ]; then
  echo '[INFO] 컨테이너 모드: kubeconfig를 kind 내부 주소로 전환합니다.'
  kind get kubeconfig --internal --name "$CJONS_CLUSTER_NAME" > "$CJONS_KUBECONFIG"
fi
chmod 600 "$CJONS_KUBECONFIG"

# 최초 실행에서 kubeconfig 이 아직 없을 때의 처리:
# lab_env.sh 는 «source 시점»에 kubeconfig 파일이 있을 때만 KUBECONFIG 를 export 한다.
# 이 스크립트는 파일을 «만들기 전»에 lab_env.sh 를 source 하므로, 최초 실행에서는
# export 가 일어나지 않는다. 이후 명령이 맨 kubectl 이면 그 명시가 없어
# `kubectl apply` 가 localhost:8080 으로 붙어 실패했다.
#   error: ... Get "http://localhost:8080/openapi/v2": connect: connection refused
# 파일이 확정된 «지금» 다시 export 한다.
export KUBECONFIG="$CJONS_KUBECONFIG"

require_lab_context

for image in "$CJONS_NGINX_IMAGE" "$CJONS_BUSYBOX_IMAGE" "$CJONS_M2_IMAGE"; do
  load_image_into_kind "$image"
done

kubectl apply -f "$CJONS_METRICS_MANIFEST"
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
  2>/dev/null || true
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Deployment가 Available이 되어도 metrics.k8s.io가 첫 스크레이프를 마치기 전까지는
# `kubectl top`이 실패한다(약 15~60초). check_env.sh ready / verify_all.sh가 이 구간에
# 걸려 FAIL을 내던 문제를 없애기 위해, 실제 API 응답까지 폴링한다.
printf '[INFO] metrics.k8s.io 첫 스크레이프 대기'
for _ in $(seq 1 40); do
  if kubectl top nodes >/dev/null 2>&1; then
    printf ' — 준비 완료\n'
    break
  fi
  printf '.'
  sleep 5
done
if ! kubectl top nodes >/dev/null 2>&1; then
  printf '\n[WARN] metrics API가 아직 응답하지 않습니다. 1~2분 뒤 check_env.sh ready를 다시 실행하세요.\n'
fi

echo '[DONE] cjons-lab 전용 클러스터 준비 완료.'
echo '       source 00-common/lab_env.sh 후 `kubectl get nodes`로 확인하세요.'
