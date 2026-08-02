#!/usr/bin/env bash
# CJONS 실습 컨테이너 실행기 (macOS / Linux / WSL2)
#
#   bash lab/lab.sh              → 실습 셸 진입
#   bash lab/lab.sh build        → 이미지 빌드(최초 1회)
#   bash lab/lab.sh verify       → 전 모듈 자동검증을 컨테이너 안에서 1회 실행
#   bash lab/lab.sh -- <명령>    → 컨테이너 안에서 임의 명령 1회 실행
#
# 이 스크립트는 호스트 Docker 소켓을 컨테이너에 넘겨(sibling container 방식)
# 컨테이너 안의 kind가 호스트 Docker에 클러스터를 만들게 한다.
set -euo pipefail

IMAGE="${CJONS_LAB_IMAGE:-cjons-lab:1.0}"
NETWORK="kind"                       # kind가 노드 컨테이너를 붙이는 네트워크와 동일해야 한다
CONTAINER_NAME="cjons-lab-shell"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"

die() { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
info() { printf '\033[36m[INFO] %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[WARN] %s\033[0m\n' "$*" >&2; }

command -v docker >/dev/null 2>&1 || die 'docker CLI가 없습니다. Docker Desktop 또는 Docker Engine을 설치하십시오.'
docker info >/dev/null 2>&1 || die 'Docker 데몬이 응답하지 않습니다. Docker를 먼저 실행하십시오.'

# ── 소켓 경로 판별 ───────────────────────────────────────────────────────
# Docker Desktop(mac/Win)·Colima·OrbStack은 사용자 홈 아래 소켓을 쓰기도 한다.
HOST_SOCK=""
for cand in /var/run/docker.sock "$HOME/.docker/run/docker.sock" "$HOME/.colima/default/docker.sock" "$HOME/.orbstack/run/docker.sock"; do
  [ -S "$cand" ] && { HOST_SOCK="$cand"; break; }
done
[ -n "$HOST_SOCK" ] || die 'Docker 소켓을 찾지 못했습니다. DOCKER_HOST 설정을 확인하십시오.'

build_image() {
  info "이미지 빌드: $IMAGE"
  docker build -t "$IMAGE" "$SCRIPT_DIR"
  info '빌드 완료.'
  # 이미 떠 있는 컨테이너는 «빌드 전» 이미지로 계속 돈다. 새 내용은 반영되지 않는다.
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    warn '실습 컨테이너가 실행 중입니다 — 방금 빌드한 내용은 그 컨테이너에 반영되지 않습니다.'
    warn "반영하려면: 모든 실습 셸에서 exit → (남아 있으면) docker rm -f $CONTAINER_NAME → 다시 진입"
  fi
}

ensure_image() {
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    info "이미지가 없어 자동 빌드합니다: $IMAGE"
    build_image
    return
  fi
  # ── 태그가 같아도 «내용»이 구본일 수 있다 ─────────────────────────────────
  # Dockerfile 에 도구를 추가해도 「태그가 있으면 건너뛴다」로 두면 옛 이미지가
  # 계속 재사용된다. 태그는 내용을 보증하지 않으므로 «도구의 실재»로 판정한다.
  if ! docker run --rm --entrypoint sh "$IMAGE" \
       -c 'command -v stress-ng >/dev/null 2>&1 && command -v etcdctl >/dev/null 2>&1' \
       >/dev/null 2>&1; then
    warn "$IMAGE 에 실습 도구(stress-ng·etcdctl)가 없습니다 — 자동 재빌드합니다."
    build_image
  fi
}

ensure_network() {
  # kind는 'kind' 네트워크를 자동 생성하지만, 실습 셸이 먼저 뜰 수 있으므로 선점 생성한다.
  docker network inspect "$NETWORK" >/dev/null 2>&1 || {
    info "docker 네트워크 생성: $NETWORK"
    docker network create "$NETWORK" >/dev/null
  }
}

run_container() {
  ensure_image
  ensure_network

  # ── 이미 떠 있으면 «Stop하지 말고» 셸을 하나 더 붙인다 ───────────────────
  # M5 Lab 5-1(관찰 창 A + 조작 창 B)·M6은 두 셸을 «동시에» 요구한다.
  # 무조건 rm -f 하면 두 번째 창을 열려던 수강생이 첫 번째 창(--watch 관찰 중)을 날린다.
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    info '실습 컨테이너가 이미 실행 중입니다 — 기존 창을 그대로 두고 새 셸을 붙입니다.'
    info "이 셸에서도 'source 00-common/lab_env.sh' 를 한 번 실행해야 kubectl 이 실습 클러스터를 가리킵니다."
    # 「실행 중이면 붙인다」의 사각지대 —
    # 이미지를 새로 빌드해도 이미 떠 있는 컨테이너는 «옛 이미지»로 계속 돈다.
    _run_img="$(docker inspect -f '{{.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    _tag_img="$(docker inspect -f '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
    if [ -n "$_run_img" ] && [ -n "$_tag_img" ] && [ "$_run_img" != "$_tag_img" ]; then
      warn '이 컨테이너는 «이전 이미지»로 떠 있습니다 — 새로 빌드한 내용이 반영되지 않은 상태입니다.'
      warn "반영하려면: 모든 실습 셸에서 exit → (남아 있으면) docker rm -f $CONTAINER_NAME → 다시 진입"
    fi
    exec docker exec -it -w /work "$CONTAINER_NAME" "$@"
  fi

  # Stop된 잔여 컨테이너만 정리한다.
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  # --network kind : kubeconfig의 cjons-lab-control-plane:6443 을 DNS로 찾기 위함
  # -v repo:/work  : 실습 코드와 결과 파일(.lab/)이 호스트에 그대로 남는다
  # --cap-add SYSLOG : dmesg(커널 링버퍼 조회) 허용. 없으면
  #   `dmesg: read kernel buffer failed: Operation not permitted` 로 막힌다.
  #   --privileged 는 쓰지 않는다 — 필요한 능력 하나만 준다(최소권한).
  # --cap-add NET_ADMIN/NET_RAW : tcpdump·ss 로 트래픽 경로를 직접 관찰(M5).
  exec docker run -it --rm \
    --name "$CONTAINER_NAME" \
    --hostname cjons-lab-shell \
    --network "$NETWORK" \
    --cap-add SYSLOG \
    --cap-add NET_ADMIN \
    --cap-add NET_RAW \
    -v "$HOST_SOCK:/var/run/docker.sock" \
    -v "$REPO_ROOT:/work" \
    -w /work \
    -e CJONS_IN_CONTAINER=1 \
    -e "CJONS_HOST_REPO=$REPO_ROOT" \
    -e "CJONS_LAB_IMAGE=$IMAGE" \
    -e "CJONS_PROFILE=${CJONS_PROFILE:-}" \
    -e "CJONS_QUIET=${CJONS_QUIET:-0}" \
    "$IMAGE" "$@"
}

case "${1:-shell}" in
  build)
    build_image
    ;;
  verify)
    info '컨테이너 안에서 전 모듈 자동검증을 실행합니다.'
    run_container bash -lc 'bash 00-common/check_env.sh host && bash 00-common/prefetch_assets.sh && bash 00-common/setup_cluster.sh && bash 00-common/verify_all.sh'
    ;;
  shell)
    run_container bash
    ;;
  --)
    shift
    run_container "$@"
    ;;
  *)
    run_container "$@"
    ;;
esac
