# CJONS 실습 컨테이너
# ─────────────────────────────────────────────────────────────────────────────
# 목적: Windows / macOS / Linux 어느 PC에서든 **완전히 동일한 CLI 환경**으로
#       M1~M8 핸즈온을 수행한다. 수강생 PC에는 Docker만 있으면 된다.
#
# 동작 방식(sibling container):
#   호스트의 Docker 소켓을 이 컨테이너에 마운트해, 컨테이너 안의 kind/docker CLI가
#   **호스트 Docker 데몬**에 클러스터 노드를 만든다. Docker-in-Docker가 아니므로
#   --privileged 가 필요 없고 메모리 이중 점유도 없다(4C/8GB PC 대응).
#
# 빌드:  docker build -t cjons-lab:1.0 lab/
# 실행:  bash lab/lab.sh        (Windows PowerShell 은 lab\lab.ps1)
# ─────────────────────────────────────────────────────────────────────────────
FROM ubuntu:24.04

# 재현성을 위해 툴 버전을 이미지에 고정한다. 호스트 OS·아키텍처가 달라도
# 컨테이너 안의 버전은 항상 같다 — 이것이 "동일 결과 검증"의 근거다.
ARG KIND_VERSION=v0.32.0
ARG KUBECTL_VERSION=v1.35.5
ARG K8SGPT_VERSION=v0.4.36
ARG DOCKER_CLI_VERSION=27.5.1
ARG COMPOSE_VERSION=v2.32.4
ARG ETCD_VERSION=v3.6.11

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CJONS_IN_CONTAINER=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      bash ca-certificates curl wget git jq gnupg \
      python3 python3-venv python3-pip \
      procps psmisc lsof strace sysstat iproute2 iputils-ping dnsutils netcat-openbsd \
      util-linux coreutils findutils gawk sed grep less vim-tiny \
      dos2unix unzip tar gzip file bc tzdata \
      stress-ng tcpdump numactl hwloc \
 && rm -rf /var/lib/apt/lists/*

# ── 아키텍처 판별(amd64 / arm64 동시 지원) ──────────────────────────────────
# Apple Silicon(arm64)과 Intel/AMD(amd64) 어느 쪽에서 빌드해도 같은 태그로 동작한다.
# 아키텍처 이름 규칙이 배포처마다 다르다(실제 확인 결과):
#   kubectl·kind      : amd64  / arm64
#   docker static·compose : x86_64 / aarch64      ← arm64 로 쓰면 404
#   k8sgpt            : x86_64 / arm64
# 세 가지를 각각 변수로 분리해야 두 아키텍처 모두에서 빌드가 성립한다.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) KARCH=amd64; DL_ARCH=x86_64;  K8SGPT_ARCH=x86_64 ;; \
      arm64) KARCH=arm64; DL_ARCH=aarch64; K8SGPT_ARCH=arm64 ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    \
    # docker CLI (클라이언트 전용 — 데몬은 호스트 것을 쓴다)
    curl -fsSL "https://download.docker.com/linux/static/stable/${DL_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
      -o /tmp/docker.tgz; \
    tar -xzf /tmp/docker.tgz -C /tmp; \
    install -m 0755 /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker /tmp/docker.tgz; \
    \
    # docker compose v2 (M4 etcd 쿼럼 실습에서 사용)
    mkdir -p /usr/local/lib/docker/cli-plugins; \
    curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-${DL_ARCH}" \
      -o /usr/local/lib/docker/cli-plugins/docker-compose; \
    chmod 0755 /usr/local/lib/docker/cli-plugins/docker-compose; \
    \
    # kubectl
    curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${KARCH}/kubectl" -o /usr/local/bin/kubectl; \
    chmod 0755 /usr/local/bin/kubectl; \
    \
    # kind
    curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${KARCH}" -o /usr/local/bin/kind; \
    chmod 0755 /usr/local/bin/kind; \
    \
    # k8sgpt (M8) — 자산명이 x86_64 / arm64 규칙이라 별도 변수를 쓴다
    curl -fsSL "https://github.com/k8sgpt-ai/k8sgpt/releases/download/${K8SGPT_VERSION}/k8sgpt_Linux_${K8SGPT_ARCH}.tar.gz" \
      -o /tmp/k8sgpt.tgz; \
    tar -xzf /tmp/k8sgpt.tgz -C /tmp k8sgpt; \
    install -m 0755 /tmp/k8sgpt /usr/local/bin/k8sgpt; \
    rm -f /tmp/k8sgpt /tmp/k8sgpt.tgz; \
    \
    # etcdctl (M4) — 클라이언트를 실습 셸에 두면 etcd 컨테이너로 docker exec 하지 않고도
    # 클라이언트를 실습 셸에 두면 --endpoints 로 3노드를 한 자리에서 다룰 수 있어
    # 「쿼럼이 무엇을 막는가」를 명령 한 줄 차이로 보여줄 수 있다. 서버는 설치하지 않는다.
    curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${KARCH}.tar.gz" \
      -o /tmp/etcd.tgz; \
    tar -xzf /tmp/etcd.tgz -C /tmp --strip-components=1 "etcd-${ETCD_VERSION}-linux-${KARCH}/etcdctl"; \
    install -m 0755 /tmp/etcdctl /usr/local/bin/etcdctl; \
    rm -f /tmp/etcdctl /tmp/etcd.tgz

# M3 용량산정 실습용 파이썬 패키지 (오프라인 재현을 위해 버전 고정)
RUN pip3 install --no-cache-dir --break-system-packages \
      pytest==8.3.4 openpyxl==3.1.5

# 설치 검증 — 빌드 시점에 한 번 더 확인해서, 깨진 이미지가 배포되지 않게 한다
RUN set -eux; \
    docker --version; \
    docker compose version; \
    kubectl version --client=true; \
    kind version; \
    k8sgpt version; \
    etcdctl version; \
    stress-ng --version; \
    tcpdump --version 2>&1 | head -1; \
    sar -V 2>&1 | head -1; \
    python3 --version; \
    pytest --version

# ── 붙여넣기 표식(bracketed paste) 누출 방지 ────────────────────────────────
# 여러 줄을 붙여넣을 때 표식이 명령에 섞여 아래처럼 실패하는 경우가 있다.
#   bash: $'\E[200~k': command not found      ← 앞의 ESC[200~
#   ...creationTimestamp~                      ← 뒤의 ESC[201~ 잔해
# 호스트 터미널(Windows Terminal 등)은 bracketed paste를 켜서 보내는데 컨테이너 readline이
# 이를 처리하지 않으면 그대로 명령줄에 들어온다. 이미지에서 명시적으로 켜 둔다.
RUN printf '%s\n' 'set enable-bracketed-paste on' >> /etc/inputrc

# ── `k` 미활성 안내 ────────────────────────────────────────────────────────
# `k` 는 00-common/lab_env.sh 가 정의하는 «함수»라 셸마다 따로 활성화해야 한다.
# M5·M6은 창을 두 개 쓰는데, 두 번째 창에서 source를 잊으면 `k: command not found`
# 만 보이고 이유를 알 길이 없다. 그래서 미로드 상태의
# `k` 를 안내 함수로 미리 정의해 둔다 — lab_env.sh 를 source 하면 그쪽 정의로 대체된다.
RUN printf '%s\n' \
  '' \
  '# ── CJONS: 실습 환경 미로드 안내 (lab_env.sh 를 source 하면 해제됨) ──' \
  '# 교재 표기가 kubectl 이므로 kubectl 에도 같은 안내를 둔다.' \
  '#   미로드 상태의 kubectl 은 기본값 localhost:8080 으로 붙어 «Unhandled Error» 를' \
  '#   7줄씩 쏟아내는데, 그 안에 정작 원인(kubeconfig 미로드)이 보이지 않는다.' \
  'k() {' \
  '  echo "[HINT] 이 셸에서는 아직 실습 환경이 로드되지 않았습니다." >&2' \
  '  echo "       저장소 루트에서 실행하십시오 (셸마다 1회):" >&2' \
  '  echo "         source 00-common/lab_env.sh" >&2' \
  '  return 127' \
  '}' \
  'kubectl() {' \
  '  if [ -n "${KUBECONFIG:-}" ]; then command kubectl "$@"; return $?; fi' \
  '  echo "[HINT] 이 셸에는 실습 kubeconfig 가 로드되지 않았습니다 — localhost:8080 으로 붙습니다." >&2' \
  '  echo "       저장소 루트에서 실행하십시오 (셸마다 1회):" >&2' \
  '  echo "         source 00-common/lab_env.sh" >&2' \
  '  return 127' \
  '}' \
  >> /root/.bashrc

# ── sysstat 수집 디렉토리 ───────────────────────────────────────────────────
# `sar -u`(인자 없는 과거 조회)는 /var/log/sysstat 의 일별 파일을 읽는데, 컨테이너에는
# sadc 수집 데몬이 없어 파일이 아예 없다. 디렉토리를 만들어 두면 "Cannot open ..." 대신
# 「수집된 데이터가 없다」가 분명해진다. 실습은 실시간 형식(`sar -u 1 3`)을 쓴다.
RUN mkdir -p /var/log/sysstat

COPY entrypoint.sh /usr/local/bin/cjons-entrypoint
RUN chmod 0755 /usr/local/bin/cjons-entrypoint

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/cjons-entrypoint"]
CMD ["bash"]
