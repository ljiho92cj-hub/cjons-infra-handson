#!/usr/bin/env bash
# source 00-common/lab_env.sh 후 `k ...`를 사용한다.
# k는 전용 kubeconfig와 kind-cjons-lab context를 강제해 개인/회사 클러스터 오조작을 막는다.

if [ -n "${BASH_SOURCE[0]:-}" ]; then
  CJONS_LAB_ENV_SOURCE="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
  CJONS_LAB_ENV_SOURCE="${(%):-%N}"
else
  echo '[ERROR] lab_env.sh는 Bash 또는 Zsh에서 source해야 합니다.' >&2
  return 1 2>/dev/null || exit 1
fi

# zsh에서는 경로 계산에 cd를 아예 쓰지 않는다. 일부 zsh 설정에서는 cd -q로도 억제되지
# 않는 훅·터미널 통합 출력이 $(cd … && pwd -P) 캡처에 끼어들어 경로가 «여분 출력 + pwd»
# 두 줄로 오염된다. 순수 매개변수 확장(:A 절대경로·:h dirname)은 서브프로세스도 cd도
# 없어 어떤 환경 출력도 끼어들 수 없다. bash에는 chpwd류 훅이 없다.
# cd -q로도 억제되지 않는 훅·터미널 통합 출력이 $(cd … && pwd -P) 캡처에 끼어들어
# 경로가 «여분 출력 + pwd» 두 줄로 오염됐다. 순수 매개변수 확장(:A 절대경로·:h dirname)은
# 서브프로세스도 cd도 없어 어떤 환경 출력도 끼어들 수 없다. bash에는 chpwd류 훅이 없다.
if [ -n "${ZSH_VERSION:-}" ]; then
  CJONS_COMMON_DIR="${CJONS_LAB_ENV_SOURCE:A:h}"
  CJONS_LAB_ROOT="${CJONS_COMMON_DIR:h}"
else
  CJONS_COMMON_DIR="$(CDPATH='' cd -- "$(dirname -- "$CJONS_LAB_ENV_SOURCE")" && pwd -P)"
  CJONS_LAB_ROOT="$(CDPATH='' cd -- "$CJONS_COMMON_DIR/.." && pwd -P)"
fi
# shellcheck disable=SC1091
. "$CJONS_COMMON_DIR/versions.env"

CJONS_LAB_STATE="$CJONS_LAB_ROOT/.lab"
CJONS_KUBECONFIG="$CJONS_LAB_STATE/${CJONS_CLUSTER_NAME}.kubeconfig"
CJONS_CONTEXT="kind-${CJONS_CLUSTER_NAME}"
CJONS_METRICS_MANIFEST="$CJONS_LAB_STATE/metrics-server-${CJONS_METRICS_SERVER_VERSION}.yaml"

# ── OS 자동판별 ──────────────────────────────────────────────────────
# macOS / Linux(native) / WSL2 세 환경에서 동일한 실습 절차를 쓰기 위한 판별.
# 모듈 스크립트는 OS별 분기 대신 여기서 export된 CJONS_OS만 참조한다.
#
# 실습 컨테이너(container) 모드:
#   CJONS_IN_CONTAINER=1 이면 호스트 OS와 무관하게 'container'로 판별한다.
#   컨테이너 안의 kind/kubectl은 호스트 Docker 데몬을 원격 조작(sibling container)하므로
#   Windows·macOS·Linux 어디서 띄우든 이 분기 하나로 절차가 완전히 동일해진다.
cjons_detect_os() {
  if [ "${CJONS_IN_CONTAINER:-0}" = "1" ]; then
    printf 'container'
    return
  fi
  case "$(uname -s 2>/dev/null)" in
    Darwin) printf 'macos' ;;
    Linux)
      if grep -qi 'microsoft' /proc/version 2>/dev/null; then
        printf 'wsl2'
      else
        printf 'linux'
      fi
      ;;
    *) printf 'unknown' ;;
  esac
}
CJONS_OS="${CJONS_OS:-$(cjons_detect_os)}"

# ── 실습 프로필(std/low) 자동판별 ───────────────────────────────────
# std = kind 3노드(control-plane 1 + worker 2). 6 vCPU / 7GiB 이상 권장.
# low = kind 2노드(control-plane 1 + worker 1). 4C·8GB PC(WSL2 memory=5GB) 대응.
#       M1~M8 전 모듈이 low에서도 성립하며, 다중 worker 분산 관찰(M5)만 축소된다.
# 강제 지정: CJONS_PROFILE=std bash 00-common/setup_cluster.sh
CJONS_PROFILE_CACHE="$CJONS_LAB_STATE/profile.env"

cjons_probe_resources() {
  # docker engine 기준 자원(맥/윈도우는 VM 할당량, 리눅스는 호스트 실자원)
  CJONS_NCPU=0
  CJONS_MEM_MB=0
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    CJONS_NCPU="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
    local mem_bytes
    mem_bytes="$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)"
    CJONS_MEM_MB=$(( ${mem_bytes:-0} / 1048576 ))
  fi
  case "$CJONS_NCPU" in ''|*[!0-9]*) CJONS_NCPU=0 ;; esac
}

cjons_resolve_profile() {
  if [ -n "${CJONS_PROFILE:-}" ]; then
    return 0
  fi
  if [ -s "$CJONS_PROFILE_CACHE" ]; then
    # shellcheck disable=SC1090
    . "$CJONS_PROFILE_CACHE"
    [ -n "${CJONS_PROFILE:-}" ] && return 0
  fi
  cjons_probe_resources
  if [ "$CJONS_NCPU" -eq 0 ] || [ "$CJONS_MEM_MB" -eq 0 ]; then
    CJONS_PROFILE=std           # docker 미기동 상태에서는 판단 보류(기본값)
  elif [ "$CJONS_NCPU" -lt 6 ] || [ "$CJONS_MEM_MB" -lt 7168 ]; then
    CJONS_PROFILE=low
  else
    CJONS_PROFILE=std
  fi
  if [ -d "$CJONS_LAB_STATE" ] || mkdir -p "$CJONS_LAB_STATE" 2>/dev/null; then
    printf 'CJONS_PROFILE=%s\n' "$CJONS_PROFILE" > "$CJONS_PROFILE_CACHE" 2>/dev/null || true
  fi
}
cjons_resolve_profile

case "$CJONS_PROFILE" in
  low)
    CJONS_KIND_CONFIG="$CJONS_COMMON_DIR/kind-config-low.yaml"
    CJONS_EXPECTED_NODES=2
    ;;
  *)
    CJONS_PROFILE=std
    CJONS_KIND_CONFIG="$CJONS_COMMON_DIR/kind-config.yaml"
    CJONS_EXPECTED_NODES=3
    ;;
esac
CJONS_WORKER_NODE="${CJONS_CLUSTER_NAME}-worker"

require_lab_context() {
  if ! command -v kubectl >/dev/null 2>&1; then
    echo '[ERROR] kubectl이 없습니다. 00-common/check_env.sh host를 먼저 실행하세요.' >&2
    return 1
  fi
  if [ ! -s "$CJONS_KUBECONFIG" ]; then
    echo "[ERROR] 전용 kubeconfig이 없습니다: $CJONS_KUBECONFIG" >&2
    echo '        bash 00-common/setup_cluster.sh로 cjons-lab을 생성하세요.' >&2
    return 1
  fi

  local server
  server="$(kubectl --kubeconfig "$CJONS_KUBECONFIG" --context "$CJONS_CONTEXT" \
    config view --minify -o 'jsonpath={.clusters[0].cluster.server}' 2>/dev/null)" || {
      echo "[ERROR] $CJONS_CONTEXT context를 확인할 수 없습니다." >&2
      return 1
    }
  # 안전 가드: 개인·회사 클러스터 오조작 방지.
  #  - 호스트 모드: kind가 발급하는 https://127.0.0.1:<port>
    #  - 컨테이너 모드: kind --internal kubeconfig의
  #    https://<클러스터명>-control-plane:6443 (kind 네트워크 내부 DNS)
  case "$server" in
    https://127.0.0.1:*|https://localhost:*) ;;
    "https://${CJONS_CLUSTER_NAME}-control-plane:6443")
      if [ "${CJONS_IN_CONTAINER:-0}" != "1" ]; then
        echo '[ERROR] 컨테이너 전용 kubeconfig을 호스트에서 사용하려 했습니다.' >&2
        echo '        가장 간단한 해결: «저장소 루트에서» bash lab/lab.sh 로 실습 셸에 접속해 진행하십시오.' >&2
        echo "        (모듈 폴더에서 실행하면 No such file — 루트는 ${CJONS_LAB_ROOT:-저장소 최상위})" >&2
        echo '        (호스트에서 직접 쓰려면 bash 00-common/setup_cluster.sh를 다시 실행)' >&2
        return 1
      fi
      ;;
    *)
      echo '[ERROR] 안전 가드가 로컬 kind API가 아닌 server를 차단했습니다.' >&2
      return 1
      ;;
  esac
}

k() {
  require_lab_context || return 1
  kubectl --kubeconfig "$CJONS_KUBECONFIG" --context "$CJONS_CONTEXT" "$@"
}

# ── «kubectl 과 k 를 하나로» — 이 셸에 전용 kubeconfig을 export 한다 ──
# 이전에는 전용 kubeconfig을 k 함수 안에서만 넘겼기 때문에, 강의 슬라이드의
# 실무형 `kubectl ...` 를 그대로 치면 KUBECONFIG 미설정 → localhost:8080 refused 로
# 실패한다. «도구 이름이 다르다»는 것 자체가 불필요한 인지 부담이기도 하다.
#
# 해결: source 시점에 KUBECONFIG 를 «이 셸 한정»으로 export 한다.
#   - `kubectl ...`  → 실습 클러스터로 그대로 동작(슬라이드 명령이 곧 실행 명령)
#   - `k8sgpt ...`   → KUBECONFIG 를 읽으므로 접두어 없이 동작
#   - `k ...`        → 그대로 유지. context 까지 «강제»하는 안전 래퍼(권장 기본값)
#
# 안전성: 전역 ~/.kube/config 는 여전히 만들지 않는다. export 는 이 셸에서만 유효하며,
# 가리키는 대상이 실습 전용 클러스터이므로 개인·회사 클러스터를 건드릴 위험은
# «오히려 줄어든다»(맨 kubectl 이 기존 context 를 따라가지 않게 된다).
if [ -s "$CJONS_KUBECONFIG" ]; then
  export KUBECONFIG="$CJONS_KUBECONFIG"
  # 안내는 «셸당 한 번»만. check_env.sh 등 하위 스크립트가 이 파일을 다시 source 해도
    # 같은 문구가 두 번 찍히지 않게 한다.
  if [ "${CJONS_QUIET:-0}" != "1" ] && [ "${CJONS_KUBECONFIG_NOTICED:-0}" != "1" ]; then
    export CJONS_KUBECONFIG_NOTICED=1
    echo "[INFO] 이 셸의 KUBECONFIG = 실습 전용($CJONS_CONTEXT) — kubectl·k8sgpt 를 그대로 쓰십시오." >&2
    echo '       (개인·회사 클러스터를 쓰려면 이 source 를 하지 않은 새 터미널을 여십시오)' >&2
  fi
fi

# ── docker -v 바인드마운트용 «호스트 기준» 저장소 경로 ──────────────────────
# 실습 컨테이너는 호스트 Docker 데몬을 조작한다(sibling container). 따라서
# `docker run -v <경로>:...` 의 <경로>는 **컨테이너 안 경로(/work)가 아니라
# 호스트의 실제 경로**여야 한다. lab.sh/lab.ps1 이 CJONS_HOST_REPO 로 넘겨준다.
# 호스트 직접 실행 모드에서는 두 값이 같으므로 그대로 쓰면 된다.
# ── 윈도우 호스트 경로 검증 ────────────────────────────────────────────────
# 호스트가 Windows이면 CJONS_HOST_REPO 가 `C:\Test\infra` 형태로 들어온다.
#
# **이 값은 대개 그대로 잘 동작한다.** Docker Desktop for Windows가 컨테이너에
# 중계한 소켓에서도 윈도우 경로를 데몬 경로로 번역해 주기 때문이다
#
# 다만 그 번역은 **Docker Desktop이 해 주는 것**이라, Desktop 없이 WSL 배포판 안의
# Docker Engine을 직접 쓰는 «부록·예외 경로»에서는 일어나지 않는다. 그 경우
# 리눅스 docker CLI가 `-v` 스펙을 콜론으로 쪼개 `C:\...` 가 깨진다.
#
# 그래서 «추정하지 않고 확인한다» — 원본을 먼저 시험하고(표준 경로, 그대로 채택),
# 실패할 때만 데몬 경로 후보를 순회한다. 결과는 .lab/ 에 캐시한다.
cjons_probe_mount_candidate() {
  # $1 을 -v 좌변으로 실제 마운트해 보고 저장소 표식 파일이 보이면 0을 반환한다.
  # 존재하지 않는 경로를 -v 하면 docker가 «빈 디렉터리를 만들어» 마운트하므로,
  # 「마운트 성공」이 아니라 「표식 파일이 보이는가」로 판정해야 한다.
  docker run --rm --entrypoint /bin/sh \
    -v "$1:/probe:ro" "${CJONS_LAB_IMAGE:-cjons-lab:1.0}" \
    -c 'test -f /probe/00-common/versions.env' >/dev/null 2>&1
}

cjons_probe_mount_root() {
  # $1 = 윈도우 경로. 성공 시 «실제로 통하는» -v 좌변을 stdout으로 반환한다.
  local win="$1" drive rest cand

  # (1) 원본 그대로 먼저 시도한다 — 이것이 표준 경로다.
  #     Docker Desktop for Windows는 컨테이너에 중계한 소켓에서도 윈도우 경로를
  #     데몬 경로로 번역해 준다. 실제 환경에서
  #     `C:\Test\infra` 그대로 M2 바인드마운트 4항목이 전부 PASS했다.
  #     따라서 「윈도우 경로는 무조건 깨진다」는 전제로 값을 바꾸면 오히려 회귀가 된다.
  if cjons_probe_mount_candidate "$win"; then
    printf '%s' "$win"
    return 0
  fi

  # (2) 번역이 일어나지 않는 구성(예: Docker Desktop 없이 WSL 배포판 안의 Docker Engine을
  #     직접 쓰는 «부록·예외 경로»)에서만 데몬 경로 후보를 순회한다.
  drive="$(printf '%s' "$win" | sed -n 's|^\([A-Za-z]\):[\\/].*$|\1|p' | tr '[:upper:]' '[:lower:]')"
  rest="$(printf '%s' "$win" | sed -n 's|^[A-Za-z]:[\\/]\(.*\)$|\1|p' | tr '\\' '/')"
  [ -n "$drive" ] || return 1
  for cand in \
    "/run/desktop/mnt/host/$drive/$rest" \
    "/host_mnt/$drive/$rest" \
    "/mnt/$drive/$rest" \
    "/$drive/$rest"
  do
    if cjons_probe_mount_candidate "$cand"; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

cjons_resolve_mount_root() {
  local win="$1" cache="$CJONS_LAB_STATE/mountroot.env" resolved=""

    # 윈도우 경로가 아니면(= macOS·Linux 호스트) 원본 경로를 그대로 쓴다.
  case "$win" in
    [A-Za-z]:[\\/]*) ;;
    *) printf '%s' "$win"; return 0 ;;
  esac

  # 캐시 적중 — 원본 경로가 같을 때만 유효하다(저장소를 옮기면 자동 무효화).
  if [ -f "$cache" ]; then
    # shellcheck disable=SC1090
    . "$cache"
    if [ "${CJONS_MOUNT_ROOT_SRC:-}" = "$win" ] && [ -n "${CJONS_MOUNT_ROOT_RESOLVED:-}" ]; then
      printf '%s' "$CJONS_MOUNT_ROOT_RESOLVED"
      return 0
    fi
  fi

  resolved="$(cjons_probe_mount_root "$win" 2>/dev/null)" || resolved=""
  if [ -z "$resolved" ]; then
    echo "[WARN] 윈도우 호스트 경로($win)를 Docker 데몬이 보는 경로로 변환하지 못했습니다." >&2
    echo "       M1·M2의 'docker run -v \$CJONS_MOUNT_ROOT/...' 명령이 실패할 수 있습니다." >&2
    echo "       저장소를 공백·한글이 없는 경로(예: C:\\Test\\infra)에 두었는지 확인한 뒤," >&2
    echo "       Docker Desktop > Settings > Resources > File sharing 에 해당 드라이브가 있는지 보십시오." >&2
    printf '%s' "$win"
    return 1
  fi

  mkdir -p "$CJONS_LAB_STATE" 2>/dev/null || true
  {
    echo "# lab_env.sh가 자동 생성합니다. 손으로 고치지 마십시오."
    echo "CJONS_MOUNT_ROOT_SRC='$win'"
    echo "CJONS_MOUNT_ROOT_RESOLVED='$resolved'"
  } > "$cache" 2>/dev/null || true
  printf '%s' "$resolved"
}

# CJONS_MOUNT_ROOT_OK=0 이면 -v 좌변으로 쓸 수 있는 경로를 확정하지 못한 것이다.
# 이 경우 CJONS_MOUNT_ROOT에는 원본 값이 그대로 들어가 있어 「쓰면 실패」한다.
# 조용히 진행하다 docker의 난해한 오류를 만나지 않도록, 사용처에서 먼저 이 값을 본다.
CJONS_MOUNT_ROOT_OK=1
if [ "${CJONS_IN_CONTAINER:-0}" = "1" ] && [ -n "${CJONS_HOST_REPO:-}" ]; then
  CJONS_MOUNT_ROOT="$(cjons_resolve_mount_root "$CJONS_HOST_REPO")" || CJONS_MOUNT_ROOT_OK=0
else
  CJONS_MOUNT_ROOT="$CJONS_LAB_ROOT"
fi

# 바인드마운트를 쓰는 스크립트·실습이 진입 직후 호출하는 가드.
cjons_require_mount_root() {
  [ "${CJONS_MOUNT_ROOT_OK:-1}" = "1" ] && return 0
  echo '[ERROR] 호스트 저장소 경로를 확정하지 못해 -v 바인드마운트 실습을 진행할 수 없습니다.' >&2
  echo "        현재 값: CJONS_MOUNT_ROOT=$CJONS_MOUNT_ROOT (그대로 쓰면 실패합니다)" >&2
  echo '        위 [WARN] 안내를 조치한 뒤 `source 00-common/lab_env.sh` 를 다시 실행하십시오.' >&2
  return 1
}

# 이미지에 심어 둔 «미로드 안내» 함수를 해제한다. 여기까지 왔다면 환경이 로드된
# 것이므로 kubectl 은 실제 바이너리를 그대로 써야 한다(k 는 아래에서 재정의됨).
unset -f kubectl 2>/dev/null || true

export CJONS_COMMON_DIR CJONS_LAB_ROOT CJONS_LAB_STATE CJONS_KUBECONFIG CJONS_MOUNT_ROOT CJONS_MOUNT_ROOT_OK
export CJONS_CONTEXT CJONS_METRICS_MANIFEST CJONS_LAB_ENV_SOURCE
export CJONS_OS CJONS_PROFILE CJONS_KIND_CONFIG CJONS_EXPECTED_NODES CJONS_WORKER_NODE
