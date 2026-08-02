#!/usr/bin/env bash
# Usage: bash 00-common/check_env.sh {host|assets|ready}
set -u

COMMON_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$COMMON_DIR/lab_env.sh"

MODE="${1:-host}"
PASS=0
WARN=0
FAIL=0

ok() { printf '[PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
warn() { printf '[WARN] %s\n' "$1"; WARN=$((WARN + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

check_cmd() {
  if command -v "$1" >/dev/null 2>&1; then ok "$1 CLI"; else fail "$1 CLI가 없습니다"; fi
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

os_checks() {
  echo "== OS / 실습 프로필 =="
  echo "[INFO] OS=$CJONS_OS · 프로필=$CJONS_PROFILE(노드 ${CJONS_EXPECTED_NODES}개) · $(uname -sr)"
  case "$CJONS_OS" in
    container) ok "실습 컨테이너 모드(권장) — 호스트 OS와 무관하게 동일 환경" ;;
    macos|linux|wsl2) ok "지원 OS: $CJONS_OS" ;;
    *) fail "지원하지 않는 OS입니다(컨테이너/macOS/Linux/WSL2만 지원). PowerShell·CMD에서 직접 실행하지 마세요" ;;
  esac

  # ── 실습 셸 이미지에 필요한 도구가 «실제로» 들어 있는지 검사 ────────────────
  # 이미지 태그가 같아도 재빌드 전이면 «태그는 최신인데 내용은 구본»일 수 있다.
  # 그 상태에서는 M2 부하 실습(stress-ng)·M4 etcd 판독(etcdctl)이 command not found
  # 로 죽는다. 태그는 내용을 보증하지 않으므로 «도구의 실재»로 판정한다.
  if [ "$CJONS_OS" = "container" ]; then
    local missing=""
    for t in stress-ng tcpdump numactl hwloc-info etcdctl; do
      command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
      fail "실습 셸 이미지가 구버전입니다 — 없는 도구:$missing"
      echo "       태그가 같아도 «내용»이 구본이면 M2 부하·M4 etcd·M8 실습이 실패합니다." >&2
      echo "       [조치] 실습 셸에서 나간 뒤 호스트에서: bash lab/lab.sh build   (Windows: .\\lab\\lab.cmd build)" >&2
    else
      ok '실습 셸 도구 일체(stress-ng·tcpdump·numactl·hwloc·etcdctl)'
    fi
  fi

  # CRLF 오염 검사 — Windows에서 zip 해제·에디터 저장 시 가장 흔한 실습 중단 원인
  local crlf
  crlf="$(find "$CJONS_LAB_ROOT" -type f \( -name '*.sh' -o -name '*.yaml' -o -name '*.py' \) \
    -exec grep -lU $'\r' {} + 2>/dev/null | head -5)"
  if [ -n "$crlf" ]; then
    fail "스크립트에 CRLF(줄바꿈) 오염: $(echo "$crlf" | tr '\n' ' ')"
    echo "       [조치] sudo apt-get install -y dos2unix && find . -type f \\( -name '*.sh' -o -name '*.yaml' -o -name '*.py' \\) -exec dos2unix {} +" >&2
  else
    ok '스크립트 줄바꿈 LF'
  fi

  # 한글 파일명 유니코드 정규화 — macOS는 NFD(자모 분리), Linux/Windows는 NFC로 다룬다.
  # macOS에서 만든 zip을 Linux/WSL2에서 풀면 파일명이 NFD로 남아 이름 비교가 어긋난다.
  if command -v python3 >/dev/null 2>&1; then
    nfd="$(python3 - "$CJONS_LAB_ROOT" <<'PY' 2>/dev/null
import os, sys, unicodedata
root = sys.argv[1]
bad = []
for d, dirs, files in os.walk(root):
    dirs[:] = [x for x in dirs if x not in ('.git', '.lab', '__pycache__')]
    for name in files + dirs:
        if any(ord(c) > 127 for c in name) and not unicodedata.is_normalized('NFC', name):
            bad.append(os.path.relpath(os.path.join(d, name), root))
# 첫 줄 = 건수, 이후 = 문제 경로(최대 5건). 건수만 알면 무엇을 고칠지 알 수 없다.
print(len(bad))
for p in sorted(bad)[:5]:
    print(p)
PY
)"
    nfd_files="$(printf '%s\n' "$nfd" | tail -n +2)"
    nfd="$(printf '%s\n' "$nfd" | head -1)"
    if [ "${nfd:-0}" -gt 0 ]; then
      warn "한글 파일명 ${nfd}건이 NFD(자모 분리) 상태입니다 — 스크립트의 이름 비교가 어긋날 수 있습니다"
      printf '%s\n' "$nfd_files" | while IFS= read -r f; do
        [ -n "$f" ] && echo "       · $f" >&2
      done
      [ "$nfd" -gt 5 ] && echo "       · … 외 $((nfd - 5))건" >&2
      echo "       [조치] convmv -f utf8 -t utf8 --nfc -r --notest .  (또는 파일을 다시 내려받기)" >&2
    else
      ok '파일명 유니코드 정규화(NFC)'
    fi
  fi

  case "$CJONS_OS" in
    container)
      # 컨테이너 모드 고유 점검 3종 — 이 셋이 통과하면 호스트 OS는 무관해진다.
      if [ -S /var/run/docker.sock ]; then
        ok '호스트 Docker 소켓 마운트'
      else
        fail '호스트 Docker 소켓이 없습니다 — lab/lab.sh 로 컨테이너를 실행하세요'
      fi
      # kind 네트워크 소속 여부: 컨테이너 모드 kubeconfig의 API 주소를 해석하려면 필수
      if getent hosts "${CJONS_CLUSTER_NAME}-control-plane" >/dev/null 2>&1; then
        ok "kind 네트워크 DNS 해석(${CJONS_CLUSTER_NAME}-control-plane)"
      elif docker network inspect kind >/dev/null 2>&1; then
        warn '아직 클러스터가 없어 DNS 해석은 setup_cluster.sh 이후 확인됩니다'
      else
        warn 'kind 네트워크가 아직 없습니다(setup_cluster.sh가 생성)'
      fi
      # 실습 결과가 호스트에 남는지 — /work 가 bind mount 인지 확인
      if [ -w /work ]; then
        ok '작업 디렉터리 /work 쓰기 가능(결과 파일이 호스트에 보존됨)'
      else
        fail '/work 에 쓸 수 없습니다'
      fi
      ;;
    wsl2)
      case "$CJONS_LAB_ROOT" in
        /mnt/[a-zA-Z]/*)
          fail 'WSL2에서 /mnt/c 경로에 저장소가 있습니다(9p 파일시스템 — I/O 지연·퍼미션·CRLF 문제 발생)'
          echo '       [조치] cp -r . ~/cjons-infra-handson 후 리눅스 홈에서 실행하세요.' >&2
          ;;
        *) ok 'WSL2 리눅스 파일시스템에서 실행 중' ;;
      esac
      if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        ok 'cgroup v2 (M2 OOM·M6 OOMKill 재현 조건)'
      else
        warn 'cgroup v2가 아닙니다. M2 Lab1/M6 OOMKill 판독 값이 다를 수 있습니다'
      fi
      ;;
    linux)
      if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
        ok 'cgroup v2 (M2 OOM·M6 OOMKill 재현 조건)'
      else
        warn 'cgroup v1입니다. M2 Lab1/M6 OOMKill 판독 값이 다를 수 있습니다'
      fi
      if [ -w /var/run/docker.sock ] || docker info >/dev/null 2>&1; then
        ok 'docker 소켓 접근 권한'
      else
        fail 'docker 소켓 접근 불가 — sudo usermod -aG docker $USER 후 재로그인'
      fi
      ;;
  esac

  # 자원 하한 — kind + metrics-server + etcd compose 동시 기동 기준
  cjons_probe_resources
  if [ "$CJONS_NCPU" -ge 4 ] && [ "$CJONS_MEM_MB" -ge 4608 ]; then
    ok "docker 가용 자원 ${CJONS_NCPU} vCPU / ${CJONS_MEM_MB} MiB"
  elif [ "$CJONS_NCPU" -eq 0 ]; then
    warn 'docker 자원을 조회할 수 없습니다(daemon 미기동)'
  else
    fail "자원 부족: ${CJONS_NCPU} vCPU / ${CJONS_MEM_MB} MiB (최소 4 vCPU · 4.5GiB)"
    case "$CJONS_OS" in
      wsl2) echo '       [조치] C:\Users\<사용자>\.wslconfig 에 memory=5GB / processors=4 설정 후 wsl --shutdown' >&2 ;;
      macos) echo '       [조치] Docker Desktop → Settings → Resources에서 CPU·Memory를 올리세요.' >&2 ;;
    esac
  fi
}

host_checks() {
  echo '== Host / Docker =='
  check_cmd docker
  check_cmd kubectl
  check_cmd kind
  check_cmd python3
  check_cmd curl

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok 'Docker daemon'
    if [ "$(docker info --format '{{.OSType}}' 2>/dev/null)" = linux ]; then
      ok 'Linux container engine'
    else
      fail 'Docker가 Linux container mode가 아닙니다'
    fi
  else
    fail 'Docker daemon이 응답하지 않습니다'
  fi

  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok 'Docker Compose v2'
  else
    fail 'Docker Compose v2 plugin이 없습니다(M4 필수)'
  fi

  if command -v kind >/dev/null 2>&1 && kind version 2>/dev/null | grep -Fq "$CJONS_KIND_VERSION"; then
    ok "kind $CJONS_KIND_VERSION"
  else
    fail "kind $CJONS_KIND_VERSION이 필요합니다"
  fi

}

asset_checks() {
  echo '== Prefetched assets =='
  for image in "$CJONS_NODE_IMAGE" "$CJONS_NGINX_IMAGE" "$CJONS_BUSYBOX_IMAGE" \
    "$CJONS_M2_IMAGE" "$CJONS_ETCD_IMAGE"; do
    if docker image inspect "$image" >/dev/null 2>&1; then
      ok "image: $image"
    else
      fail "image 미준비: $image"
    fi
  done

  if [ -s "$CJONS_METRICS_MANIFEST" ]; then
    if [ "$(hash_file "$CJONS_METRICS_MANIFEST")" = "$CJONS_METRICS_MANIFEST_SHA256" ]; then
      ok "metrics-server manifest $CJONS_METRICS_SERVER_VERSION checksum"
    else
      fail 'metrics-server manifest checksum이 다릅니다'
    fi
  else
    fail "metrics-server manifest 미준비: $CJONS_METRICS_MANIFEST"
    echo "       [조치] bash 00-common/prefetch_assets.sh   (온라인에서 1회 — 고정 URL·sha256 대조)"
  fi

  if docker run --rm --pull=never --network=none "$CJONS_M2_IMAGE" \
    bash -lc 'command -v vmstat sar pidstat iostat strace stress-ng jq curl lsof python3' >/dev/null 2>&1; then
    ok 'M2 Linux tools (offline container check)'
  else
    fail 'M2 이미지의 Linux tools 구성을 확인하세요'
  fi
}

ready_checks() {
  echo '== Dedicated cjons-lab cluster =='
  if require_lab_context; then
    ok "dedicated context: $CJONS_CONTEXT"
  else
    fail 'cjons-lab 전용 context 안전 가드'
    return
  fi

  if kubectl cluster-info >/dev/null 2>&1; then ok 'cjons-lab API reachable'; else fail 'cjons-lab API unreachable'; fi

  local ready_count
  ready_count="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 == "Ready" {count++} END {print count+0}')"
  if [ "$ready_count" -eq "$CJONS_EXPECTED_NODES" ]; then
    ok "$ready_count/$CJONS_EXPECTED_NODES kind nodes Ready ($CJONS_PROFILE 프로필)"
  else
    fail "Ready nodes: $ready_count/$CJONS_EXPECTED_NODES ($CJONS_PROFILE 프로필)"
  fi

  if kubectl top nodes >/dev/null 2>&1; then ok 'metrics.k8s.io available'; else fail 'metrics-server가 아직 준비되지 않았습니다'; fi

  if docker exec "$CJONS_WORKER_NODE" sh -c \
    'command -v iptables >/dev/null && command -v conntrack >/dev/null' >/dev/null 2>&1; then
    ok 'worker iptables/conntrack tools'
  else
    warn 'worker에서 iptables/conntrack 명령을 확인할 수 없어 M5 Plan B를 사용합니다'
  fi
}

case "$MODE" in
  host) os_checks; host_checks ;;
  assets) os_checks; host_checks; asset_checks ;;
  ready) os_checks; host_checks; asset_checks; ready_checks ;;
  *)
    echo "Usage: $0 {host|assets|ready}" >&2
    exit 2
    ;;
esac

printf 'SUMMARY PASS=%s WARN=%s FAIL=%s\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo '[ACTION] FAIL을 해결한 뒤 다음 단계로 진행하세요.' >&2
  exit 1
fi
