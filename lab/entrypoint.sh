#!/usr/bin/env bash
# CJONS 실습 컨테이너 엔트리포인트 — 진입 시 환경을 점검하고 안내한다.
set -uo pipefail

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }

fail=0

# ── 1. 호스트 Docker 소켓 ────────────────────────────────────────────────
if [ ! -S /var/run/docker.sock ]; then
  red '[ERROR] 호스트 Docker 소켓이 마운트되지 않았습니다.'
  echo   '        lab/lab.sh (또는 lab\lab.ps1) 로 실행하십시오.'
  fail=1
elif ! docker info >/dev/null 2>&1; then
  red '[ERROR] Docker 데몬에 연결할 수 없습니다. 호스트에서 Docker가 실행 중인지 확인하십시오.'
  fail=1
fi

# ── 2. kind 네트워크 연결 여부 ───────────────────────────────────────────
# 컨테이너 모드에서는 kubeconfig의 API 서버가 kind 네트워크 내부 DNS 이름이므로,
# 이 컨테이너가 kind 네트워크에 붙어 있어야 kubectl이 통한다.
if [ "${CJONS_SKIP_NETCHECK:-0}" != "1" ] && [ "$fail" -eq 0 ]; then
  if ! docker network inspect kind >/dev/null 2>&1; then
    ylw '[WARN] kind 네트워크가 아직 없습니다. setup_cluster.sh 실행 시 자동 생성됩니다.'
  fi
fi

# ── 3. 작업 디렉터리 ─────────────────────────────────────────────────────
if [ ! -f /work/00-common/versions.env ]; then
  red '[ERROR] /work 에 핸즈온 저장소가 마운트되지 않았습니다.'
  echo   '        저장소 루트에서 lab/lab.sh 를 실행하십시오.'
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo '컨테이너를 종료합니다. 위 오류를 해결한 뒤 다시 실행하십시오.'
  exit 1
fi

if [ "${CJONS_QUIET:-0}" != "1" ]; then
  grn '════════════════════════════════════════════════════════════════'
  grn '  CJONS Infra 심화 핸즈온 — 실습 컨테이너'
  grn '════════════════════════════════════════════════════════════════'
  printf '  kubectl %s · kind %s · k8sgpt %s\n' \
    "$(kubectl version --client=true -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo '?')" \
    "$(kind version 2>/dev/null | awk '{print $2}')" \
    "$(k8sgpt version 2>/dev/null | awk '{print $2}')"
  printf '  호스트 Docker: %s CPU · %s MiB\n' \
    "$(docker info --format '{{.NCPU}}' 2>/dev/null)" \
    "$(( $(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0) / 1048576 ))"
  echo
  echo '  다음 순서로 진행하십시오:'
  echo '    1) bash 00-common/check_env.sh host'
  echo '    2) bash 00-common/prefetch_assets.sh'
  echo '    3) bash 00-common/setup_cluster.sh'
  echo '    4) source 00-common/lab_env.sh   →  kubectl get nodes'
  echo '    전체 자동검증:  bash 00-common/verify_all.sh'
  grn '════════════════════════════════════════════════════════════════'
  echo
fi

exec "$@"
