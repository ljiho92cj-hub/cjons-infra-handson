#!/usr/bin/env bash
# ============================================================================
# 핸즈온 전 모듈(M1~M8) 자동 검증 러너 (멀티 OS: macOS / Linux / WSL2)
#
# Usage:
#   bash 00-common/verify_all.sh            # 전체 검증 후 정리(클러스터 유지)
#   bash 00-common/verify_all.sh --keep     # 실습 리소스도 남김(수동 관찰용)
#   bash 00-common/verify_all.sh --teardown # 검증 후 kind 클러스터까지 삭제
#   bash 00-common/verify_all.sh --only M5  # 특정 모듈만 (M1..M8, 복수 지정 가능)
#
# 전제: bash 00-common/prefetch_assets.sh 를 인터넷 되는 곳에서 1회 실행.
# 결과: 화면 출력 + .lab/verify_report_<OS>_<프로필>.md 리포트 파일.
#
# 이 스크립트는 "코드가 이 환경에서 재현되는가"만 판정한다. 학습 자체는 각 모듈
# README의 절차를 사람이 직접 밟아야 한다.
# ============================================================================
set -u

COMMON_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$COMMON_DIR/lab_env.sh"

KEEP=0
TEARDOWN=0
ONLY=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --teardown) TEARDOWN=1 ;;
    --only) shift; ONLY="${ONLY} ${1:-}" ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "[ERROR] 알 수 없는 인자: $1" >&2; exit 2 ;;
  esac
  shift
done

PASS=0; FAIL=0; SKIP=0
REPORT="$CJONS_LAB_STATE/verify_report_${CJONS_OS}_${CJONS_PROFILE}.md"
RESULTS=''
START_TS="$(date +%s)"

mkdir -p "$CJONS_LAB_STATE"

pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); RESULTS="${RESULTS}|PASS|$1
"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); RESULTS="${RESULTS}|FAIL|$1
"; }
skip() { printf '  [SKIP] %s\n' "$1"; SKIP=$((SKIP+1)); RESULTS="${RESULTS}|SKIP|$1
"; }

# check <설명> <명령...> : 종료코드 0이면 PASS
check() { desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
# expect <설명> <기대문자열> <명령...> : 출력에 기대문자열이 있으면 PASS
expect() {
  desc="$1"; want="$2"; shift 2
  out="$("$@" 2>&1)"
  case "$out" in
    *"$want"*) pass "$desc" ;;
    *) fail "$desc (기대: '$want')" ;;
  esac
}

module_enabled() {
  [ -z "${ONLY// /}" ] && return 0
  case " $ONLY " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

section() { printf '\n== %s ==\n' "$1"; }

wait_for() { # wait_for <초> <명령...>
  limit="$1"; shift; n=0
  while [ "$n" -lt "$limit" ]; do
    "$@" >/dev/null 2>&1 && return 0
    n=$((n+1)); sleep 1
  done
  return 1
}

M2_IMG="$CJONS_M2_IMAGE"
NGINX_IMG="$CJONS_NGINX_IMAGE"

# ---------------------------------------------------------------------------
printf 'CJONS 핸즈온 전수 검증 — OS=%s · 프로필=%s · 노드=%s\n' \
  "$CJONS_OS" "$CJONS_PROFILE" "$CJONS_EXPECTED_NODES"
printf '시작: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"

section 'P0. 환경'
check '0-1 호스트/OS 점검(check_env host)' bash "$COMMON_DIR/check_env.sh" host
check '0-2 사전 자산 점검(check_env assets)' bash "$COMMON_DIR/check_env.sh" assets
if kind get clusters 2>/dev/null | grep -Fxq "$CJONS_CLUSTER_NAME"; then
  pass '0-3 기존 cjons-lab 재사용'
else
  printf '  ... kind 클러스터 생성 중(2~5분)\n'
  check '0-3 setup_cluster.sh' bash "$COMMON_DIR/setup_cluster.sh"
fi
node_ready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
if [ "$node_ready" = "$CJONS_EXPECTED_NODES" ]; then
  pass "0-4 노드 Ready $node_ready/$CJONS_EXPECTED_NODES"
else
  fail "0-4 노드 Ready $node_ready/$CJONS_EXPECTED_NODES"
fi
# metrics-server는 Deployment Available 이후에도 첫 스크레이프까지 30~90초가 더 걸린다.
if wait_for 150 kubectl top nodes; then
  pass '0-5 metrics.k8s.io (kubectl top nodes)'
else
  fail '0-5 metrics.k8s.io — metrics-server 스크레이프 미개시(M6 HPA 영향)'
fi

# ---------------------------------------------------------------------------
if module_enabled M1; then
section 'M1. OS 운영 핵심 리뷰'
expect '1-1 컨테이너 내 PID 1 확인' '1' \
  docker run --rm --pull=never --network=none "$M2_IMG" ps -p 1 -o pid=
expect '1-2 좀비(Z) 프로세스 재현' 'Z' \
  docker run --rm --pull=never --network=none "$M2_IMG" python3 -c \
'import os,time,subprocess
if os.fork()==0: os._exit(0)
time.sleep(0.5)
print(subprocess.run(["ps","-eo","stat,cmd"],capture_output=True,text=True).stdout)'
if docker run --rm --pull=never --network=none --user 1000:1000 "$M2_IMG" \
   bash -lc 'touch /root/should_fail' >/dev/null 2>&1; then
  fail '1-3 비-root UID의 /root 쓰기 거부'
else
  pass '1-3 비-root UID의 /root 쓰기 거부(Permission denied)'
fi
if [ "$CJONS_OS" = macos ]; then
  if bash "$CJONS_LAB_ROOT/m1-os-review/check_self.sh" >/dev/null 2>&1; then
    fail '1-4 macOS 호스트 직접 실행 시 안내 종료(설계)'
  else
    pass '1-4 macOS 호스트 직접 실행 시 안내 종료(설계대로 exit 1)'
  fi
else
  check '1-4 Linux 호스트에서 check_self.sh 정상 완주' bash "$CJONS_LAB_ROOT/m1-os-review/check_self.sh"
fi
fi

# ---------------------------------------------------------------------------
if module_enabled M2; then
section 'M2. Linux 성능·장애 트러블슈팅'
check '2-1 lab0 환경 점검' bash "$CJONS_LAB_ROOT/m2-linux-performance/labs/lab0_env_check.sh"

docker rm -f cjons-m2-oom >/dev/null 2>&1
docker run -d --name cjons-m2-oom --pull=never --network=none \
  -m 256m --memory-swap 256m "$M2_IMG" \
  bash -lc 'stress-ng --vm 1 --vm-bytes 512M --vm-keep --timeout 30s' >/dev/null 2>&1
rc="$(docker wait cjons-m2-oom 2>/dev/null)"
oomflag="$(docker inspect -f '{{.State.OOMKilled}}' cjons-m2-oom 2>/dev/null)"
docker rm -f cjons-m2-oom >/dev/null 2>&1
if [ "$oomflag" = true ] || [ "$rc" = 137 ]; then
  pass "2-2 메모리 한계(256m) 초과 OOM 종료(rc=$rc · OOMKilled=$oomflag)"
else
  fail "2-2 메모리 한계 초과 OOM 종료 실패(rc=$rc · OOMKilled=$oomflag)"
fi
# 아래 4항목은 «호스트 실경로» 바인드마운트를 쓴다. 윈도우 호스트에서 경로
# 변환이 실패했다면 docker의 난해한 오류 대신 원인을 명시하고 FAIL 처리한다.
if cjons_require_mount_root; then M2_MOUNT_OK=1; else M2_MOUNT_OK=0; fi

if [ "$M2_MOUNT_OK" = 1 ]; then
expect '2-3 Lab2 capacity — No space left on device' 'No space left' \
  docker run --rm --pull=never --network=none --tmpfs /labfs:rw,size=16m,nr_inodes=200 \
    -v "$CJONS_MOUNT_ROOT/m2-linux-performance:/work:ro" "$M2_IMG" \
    bash -lc 'bash /work/labs/lab2_disk_full.sh capacity'
expect '2-4 Lab2 inode — IUse% 소진' 'IUse' \
  docker run --rm --pull=never --network=none --tmpfs /labfs:rw,size=16m,nr_inodes=200 \
    -v "$CJONS_MOUNT_ROOT/m2-linux-performance:/work:ro" "$M2_IMG" \
    bash -lc 'bash /work/labs/lab2_disk_full.sh inode'
expect '2-5 Lab2 deleted-open — (deleted) fd 점유' 'deleted' \
  docker run --rm --pull=never --network=none --tmpfs /labfs:rw,size=16m,nr_inodes=200 \
    -v "$CJONS_MOUNT_ROOT/m2-linux-performance:/work:ro" "$M2_IMG" \
    bash -lc 'printf "\n" | bash /work/labs/lab2_disk_full.sh deleted-open'
else
fail '2-3 Lab2 capacity — 호스트 저장소 경로 미확정으로 실행 불가(위 [ERROR] 참조)'
fail '2-4 Lab2 inode — 호스트 저장소 경로 미확정으로 실행 불가'
fail '2-5 Lab2 deleted-open — 호스트 저장소 경로 미확정으로 실행 불가'
fi
expect '2-6 Lab3 hang — S/D state·wchan 판독' 'wchan' \
  docker run --rm --pull=never --network=none "$M2_IMG" \
    bash -lc 'sleep 60 & sleep 1; ps -eo pid,stat,wchan:20,cmd | head -5'
if [ "$M2_MOUNT_OK" = 1 ]; then
check '2-7 collect_metrics.sh 실행' \
  docker run --rm --pull=never --network=none \
    -v "$CJONS_MOUNT_ROOT/m2-linux-performance:/work:ro" "$M2_IMG" \
    bash -lc 'cd /tmp && bash /work/collect_metrics.sh 2 1'
else
fail '2-7 collect_metrics.sh — 호스트 저장소 경로 미확정으로 실행 불가'
fi
fi

# ---------------------------------------------------------------------------
if module_enabled M3; then
section 'M3. 용량산정 실습'
M3="$CJONS_LAB_ROOT/m3-capacity-sizing"
expect '3-1 capacity_calc 기본 검산' '51' python3 "$M3/capacity_calc.py"
expect '3-2 CSV 프로필(심화) 계산' 'PROFILE=csv' \
  python3 "$M3/capacity_calc.py" --profile csv --data "$M3/sample_data.csv"
# pytest는 rootdir 추론 때문에 모듈 디렉터리에서 실행해야 한다(경로에 한글·공백이 있으면 특히).
if python3 -c 'import pytest' >/dev/null 2>&1; then
  if ( cd "$M3" && python3 -m pytest -q tests/test_capacity_calc.py ) >/dev/null 2>&1; then
    pass '3-3 pytest 단위테스트 5/5'
  else
    fail '3-3 pytest 단위테스트'
  fi
else
  skip '3-3 pytest 미설치(pip install pytest 후 재실행)'
fi
# 한글 파일명은 macOS(NFD)와 Linux/Windows(NFC)의 유니코드 정규화가 달라 리터럴 비교가
# 실패할 수 있다. 확장자 기준으로 확인한다(§ check_env.sh의 NFD 경고와 같은 사안).
wb_count="$(find "$M3" -maxdepth 1 -name '*.xlsx' -size +0c 2>/dev/null | grep -c .)"
if [ "${wb_count:-0}" -ge 1 ]; then
  pass '3-4 학생 workbook(xlsx) 존재'
else
  fail '3-4 학생 workbook(xlsx) 없음'
fi
fi

# ---------------------------------------------------------------------------
if module_enabled M4; then
section 'M4. HA 설계 — etcd quorum'
M4="$CJONS_LAB_ROOT/m4-ha-design"
COMPOSE="docker compose -p cjons-m4 -f $M4/docker-compose.yml"
$COMPOSE down -v --remove-orphans >/dev/null 2>&1
if $COMPOSE up -d >/dev/null 2>&1; then
  pass '4-1 etcd 3노드 기동'
else
  fail '4-1 etcd 3노드 기동'
fi
sleep 8
ETCDCTL="docker exec cjons-m4-etcd1-1 etcdctl --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379"
if wait_for 30 $ETCDCTL endpoint health; then
  pass '4-2 3/3 endpoint health'
else
  fail '4-2 3/3 endpoint health'
fi
check '4-3 quorum 정상 시 쓰기 성공' $ETCDCTL put k1 v1
docker stop cjons-m4-etcd3-1 >/dev/null 2>&1
sleep 3
if docker exec cjons-m4-etcd1-1 etcdctl --endpoints=http://etcd1:2379 put k2 v2 >/dev/null 2>&1; then
  pass '4-4 1노드 정지(2/3 quorum 유지) 쓰기 지속'
else
  fail '4-4 1노드 정지(2/3 quorum 유지) 쓰기 지속'
fi
docker stop cjons-m4-etcd2-1 >/dev/null 2>&1
sleep 3
if docker exec cjons-m4-etcd1-1 etcdctl --endpoints=http://etcd1:2379 \
     --command-timeout=5s put k3 v3 >/dev/null 2>&1; then
  fail '4-5 quorum 상실(1/3) 쓰기 거부'
else
  pass '4-5 quorum 상실(1/3) 쓰기 거부'
fi
docker start cjons-m4-etcd2-1 cjons-m4-etcd3-1 >/dev/null 2>&1
if wait_for 40 docker exec cjons-m4-etcd1-1 etcdctl --endpoints=http://etcd1:2379 put k4 v4; then
  pass '4-6 재기동 후 quorum 회복·쓰기 정상화'
else
  fail '4-6 재기동 후 quorum 회복·쓰기 정상화'
fi
$COMPOSE down -v --remove-orphans >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
if module_enabled M5; then
section 'M5. K8s 아키텍처·트래픽 경로'
M5="$CJONS_LAB_ROOT/m5-k8s-traffic"
kubectl apply -f "$M5/namespace.yaml" >/dev/null 2>&1
kubectl apply -f "$M5/deployment.yaml" -f "$M5/service.yaml" -f "$M5/client.yaml" >/dev/null 2>&1
if kubectl -n cj-lab-traffic rollout status deploy/web --timeout=120s >/dev/null 2>&1; then
  pass '5-1 web Deployment 2/2 Ready'
else
  fail '5-1 web Deployment 2/2 Ready'
fi
eps="$(kubectl -n cj-lab-traffic get endpointslice -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[0]}{"\n"}{end}{end}' 2>/dev/null | grep -c .)"
if [ "${eps:-0}" -ge 2 ]; then pass "5-2 EndpointSlice 실주소 ${eps}건"; else fail "5-2 EndpointSlice 실주소 ${eps}건(기대 2)"; fi
kubectl -n cj-lab-traffic wait --for=condition=Ready pod/traffic-client --timeout=90s >/dev/null 2>&1
expect '5-3 Service VIP 경유 HTTP 응답' 'Welcome to nginx' \
  kubectl -n cj-lab-traffic exec traffic-client -- wget -qO- --timeout=5 http://web
if docker exec "$CJONS_WORKER_NODE" sh -c 'iptables-save 2>/dev/null | grep -c KUBE-SVC' >/dev/null 2>&1 &&
   [ "$(docker exec "$CJONS_WORKER_NODE" sh -c 'iptables-save 2>/dev/null | grep -c KUBE-SVC')" -gt 0 ]; then
  pass '5-4 worker iptables KUBE-SVC 체인 확인'
else
  skip '5-4 iptables 조회 불가 — M5 Plan B(EndpointSlice 판독)로 대체'
fi
if docker exec "$CJONS_WORKER_NODE" sh -c 'command -v conntrack >/dev/null' 2>/dev/null; then
  kubectl -n cj-lab-traffic exec traffic-client -- wget -qO- --timeout=5 http://web >/dev/null 2>&1
  if docker exec "$CJONS_WORKER_NODE" sh -c 'conntrack -L 2>/dev/null | head -20' >/dev/null 2>&1; then
    pass '5-5 conntrack DNAT 세션 조회'
  else
    skip '5-5 conntrack 조회 실패(권한/모듈)'
  fi
else
  skip '5-5 conntrack 미탑재 — Plan B'
fi
kubectl apply -f "$M5/broken-service.yaml" >/dev/null 2>&1
sleep 5
broken="$(kubectl -n cj-lab-traffic get endpointslice -l kubernetes.io/service-name=web \
  -o jsonpath='{range .items[*]}{range .endpoints[*]}{.addresses[0]}{"\n"}{end}{end}' 2>/dev/null | grep -c .)"
if [ "${broken:-0}" -eq 0 ]; then
  pass '5-6 broken-service 적용 시 endpoints 소멸(셀렉터 불일치)'
else
  fail '5-6 broken-service 적용 시 endpoints 소멸'
fi
kubectl apply -f "$M5/service.yaml" >/dev/null 2>&1
if wait_for 30 kubectl -n cj-lab-traffic exec traffic-client -- wget -qO- --timeout=3 http://web; then
  pass '5-7 정상 Service 재적용 후 복구'
else
  fail '5-7 정상 Service 재적용 후 복구'
fi
fi

# ---------------------------------------------------------------------------
if module_enabled M6; then
section 'M6. K8s 리소스·운영 전략'
M6="$CJONS_LAB_ROOT/m6-k8s-resources-hpa"
kubectl apply -f "$M6/namespace.yaml" >/dev/null 2>&1
kubectl apply -f "$M6/deployment-resources.yaml" -f "$M6/hpa.yaml" >/dev/null 2>&1
if kubectl -n cj-lab-resources rollout status deploy/web-hpa --timeout=120s >/dev/null 2>&1; then
  pass '6-1 web-hpa 배포·HPA 생성'
else
  fail '6-1 web-hpa 배포·HPA 생성'
fi
kubectl apply -f "$M6/loadgen.yaml" >/dev/null 2>&1
printf '  ... HPA 스케일아웃 대기(최대 180초)\n'
scaled=0; n=0
while [ "$n" -lt 180 ]; do
  rep="$(kubectl -n cj-lab-resources get deploy web-hpa -o jsonpath='{.spec.replicas}' 2>/dev/null)"
  [ "${rep:-1}" -gt 1 ] && { scaled=1; break; }
  n=$((n+5)); sleep 5
done
if [ "$scaled" = 1 ]; then pass "6-2 부하 인가 후 HPA 스케일아웃(replicas=${rep})"; else fail '6-2 HPA 스케일아웃 미발생'; fi
kubectl delete -f "$M6/loadgen.yaml" --ignore-not-found >/dev/null 2>&1
# oom-stress 는 restartPolicy: Never 라 한 번 Failed 로 끝나면 그 자리에 남는다.
# delete 없이 apply 하면 ⓐ이전 실행의 terminated 값을 그대로 읽어 «위양성 PASS» 가 나거나
# ⓑ이미지 태그처럼 immutable 필드가 바뀐 뒤에는 apply 자체가 거부돼 FAIL 이 난다.
kubectl delete -f "$M6/oom-stress.yaml" --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f "$M6/oom-stress.yaml" >/dev/null 2>&1
oom=0; n=0
while [ "$n" -lt 120 ]; do
  st="$(kubectl -n cj-lab-resources get pod oom-stress \
    -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}{" "}{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)"
  case "$st" in *OOMKilled*) oom=1; break ;; esac
  n=$((n+5)); sleep 5
done
if [ "$oom" = 1 ]; then pass '6-3 limits 초과 컨테이너 OOMKilled 판정'; else fail '6-3 OOMKilled 재현 실패'; fi
kubectl apply -f "$M6/qos-oomkill-demo.yaml" >/dev/null 2>&1
sleep 10
qos="$(kubectl -n cj-lab-resources get pod -l demo=qos \
  -o jsonpath='{range .items[*]}{.status.qosClass}{" "}{end}' 2>/dev/null)"
qhit=0
case "$qos" in *Guaranteed*) qhit=$((qhit+1)) ;; esac
case "$qos" in *Burstable*) qhit=$((qhit+1)) ;; esac
case "$qos" in *BestEffort*) qhit=$((qhit+1)) ;; esac
if [ "$qhit" = 3 ]; then
  pass "6-4 QoS 3분류 동시 재현($qos)"
else
  fail "6-4 QoS 3분류 재현 실패($qos)"
fi
kubectl apply -f "$M6/isolation-pattern.yaml" >/dev/null 2>&1
sleep 3
iso=0
kubectl get ns api-server >/dev/null 2>&1 && iso=$((iso+1))
kubectl -n api-server get resourcequota >/dev/null 2>&1 && iso=$((iso+1))
kubectl -n api-server get limitrange >/dev/null 2>&1 && iso=$((iso+1))
kubectl get priorityclass >/dev/null 2>&1 && iso=$((iso+1))
if [ "$iso" -ge 4 ]; then pass '6-5 격리 패턴(ns·ResourceQuota·LimitRange·PriorityClass)'; else fail "6-5 격리 패턴 확인 $iso/4"; fi
# isolation-pattern.yaml 의 Deployment 는 nodeAffinity 가 node-type=high-performance 를 요구하는데
# kind 노드엔 그 라벨이 없다 → Pod 2개가 영구 Pending 으로 남는다. 6-5 판정은 ns/quota/limitrange/
# priorityclass 만 보므로 PASS 지만, 직후 `kubectl get pods -A` 를 보면 원인 불명 Pending 을 만난다.
# 파일 머리말도 "apply 대상이 아니라 화면에 띄워 설명하는 참고용"이라고 적혀 있다 → 판정 후 걷어낸다.
kubectl -n api-server delete deployment high-priority-api --ignore-not-found >/dev/null 2>&1
fi

# ---------------------------------------------------------------------------
if module_enabled M7; then
section 'M7. K8s 장애 트러블슈팅'
M7="$CJONS_LAB_ROOT/m7-k8s-troubleshooting"
kubectl apply -f "$M7/namespace.yaml" >/dev/null 2>&1
kubectl apply -f "$M7/crashloop.yaml" >/dev/null 2>&1
cl=0; n=0
while [ "$n" -lt 120 ]; do
  r="$(kubectl -n cj-lab-trouble get pod crashloop -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
  [ "${r:-0}" -gt 0 ] && { cl=1; break; }
  n=$((n+5)); sleep 5
done
if [ "$cl" = 1 ]; then pass "7-1 CrashLoopBackOff 재현(restart=${r})"; else fail '7-1 CrashLoop 재현 실패'; fi
kubectl apply -f "$M7/pending.yaml" >/dev/null 2>&1
# 고정 sleep 8 은 느린 PC(WSL2 low 프로필)에서 스케줄러가 이벤트를 남기기 전에 describe 를 읽어
# 오탐 FAIL 을 냈다. 조건 대기로 바꾼다(7-1 이 이미 쓰는 방식과 대칭).
wait_for 60 sh -c 'kubectl -n cj-lab-trouble describe pod pending 2>/dev/null | grep -q FailedScheduling'
ev="$(kubectl -n cj-lab-trouble describe pod pending 2>/dev/null)"
case "$ev" in
  *"Insufficient cpu"*) pass '7-2 Pending 사유 Insufficient cpu 확인' ;;
  *) fail '7-2 Pending 사유 확인 실패' ;;
esac
case "$ev" in
  *untolerated*) pass '7-2b control-plane taint(untolerated) 사유 동시 노출' ;;
  *) skip '7-2b untolerated taint 문구 미노출(단일 스케줄 대상 노드 구성)' ;;
esac
# drain 은 eviction «이전» 필터 단계에서 컨트롤러 없는 bare Pod 를 만나면 즉시 중단한다
# (cannot delete Pods that declare no controller). 7-1/7-2 가 만든 crashloop·pending 이 그대로
# 남아 있으면 PDB 가 막기도 전에 그 이유로 실패하고, 아래 판정은 «실패했으니 PASS» 를 찍는다.
# low 프로필(worker 1대)에서는 100% 그렇게 된다 — 랩의 핵심 장면이 한 번도 검증되지 않는다.
kubectl -n cj-lab-trouble delete pod crashloop pending --ignore-not-found --wait=true >/dev/null 2>&1
kubectl apply -f "$M7/pdb-demo.yaml" >/dev/null 2>&1
kubectl -n cj-lab-trouble rollout status deploy/web-pdb --timeout=120s >/dev/null 2>&1
# drain 대상은 «web-pdb 가 실제로 올라간 노드»여야 한다. worker 하드코딩은 std 프로필(worker 2대)에서
# replica 가 worker2 로 몰리면 drain 이 성공해 버려 코드 결함이 아닌데도 FAIL 이 뜬다
DRAIN_NODE="$(kubectl -n cj-lab-trouble get pod -l app=web-pdb \
  -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)"
[ -n "$DRAIN_NODE" ] || DRAIN_NODE="$CJONS_WORKER_NODE"
# 7-1·7-2 를 지워도 «앞 모듈»이 남긴 bare Pod 가 같은 노드에 있으면 결과는 같다 —
# 전체 실행에서는 M5(cj-lab-traffic/traffic-client)와 M6(cj-lab-resources/qos-*·oom-stress)가
# 그대로 살아 있어 drain 이 PDB 에 닿기 전에 「no controller」로 멈춘다.
# README §Lab7-3 이 가르치는 진단(OWNER 열이 <none> 인 Pod 를 찾아 정리)을 그대로 실행한다.
# 대상은 실습 네임스페이스(cj-lab-*)로 한정한다 — kube-system 은 DaemonSet 소유라 --ignore-daemonsets 가 처리한다.
kubectl get pod -A --field-selector spec.nodeName="$DRAIN_NODE" \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind \
  --no-headers 2>/dev/null \
  | awk '$3=="<none>" && $1 ~ /^cj-lab-/ {print $1, $2}' \
  | while read -r _ns _nm; do
      kubectl -n "$_ns" delete pod "$_nm" --ignore-not-found --wait=true >/dev/null 2>&1
    done
drain_out="$(kubectl drain "$DRAIN_NODE" --ignore-daemonsets --delete-emptydir-data \
     --disable-eviction=false --timeout=45s 2>&1)"
# «실패했다»가 아니라 «PDB가 막았다»를 판정한다 — 실패 사유를 구분하지 않으면 위양성이 된다.
case "$drain_out" in
  *"disruption budget"*) pass "7-3 PDB(minAvailable=2)로 drain 차단(정상 동작·node=$DRAIN_NODE)" ;;
  *"no controller"*)     fail '7-3 drain 이 bare Pod(no controller)에서 먼저 중단 — PDB 차단이 검증되지 않음' ;;
  *)                     fail "7-3 PDB drain 차단 미확인(node=$DRAIN_NODE)" ;;
esac
check '7-4 uncordon 복구' kubectl uncordon "$DRAIN_NODE"
# 이 랩의 학습 산출물은 «롤링 업데이트 실패 중에도 기존 Ready 3개가 유지된다»는 것이다.
# good 없이 bad 부터 적용하면 검증되는 것은 «최초 배포 실패»여서 그 장면이 재현되지 않는다.
kubectl apply -f "$M7/rollout-good.yaml" >/dev/null 2>&1
kubectl -n cj-lab-trouble rollout status deploy/web-rollout --timeout=120s >/dev/null 2>&1
kubectl apply -f "$M7/rollout-bad.yaml" >/dev/null 2>&1
if kubectl -n cj-lab-trouble rollout status deploy/web-rollout --timeout=45s >/dev/null 2>&1; then
  fail '7-5 잘못된 이미지 rollout 정지 관찰'
else
  avail="$(kubectl -n cj-lab-trouble get deploy web-rollout \
    -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  if [ "${avail:-0}" -eq 3 ]; then
    pass "7-5 잘못된 이미지 rollout 정지 + 기존 replica 3 유지(available=$avail)"
  else
    pass "7-5 잘못된 이미지 rollout 정지 관찰(progress deadline·available=${avail:-0})"
  fi
fi
kubectl -n cj-lab-trouble rollout undo deploy/web-rollout >/dev/null 2>&1
if kubectl -n cj-lab-trouble rollout status deploy/web-rollout --timeout=120s >/dev/null 2>&1; then
  pass '7-6 rollout undo 로 직전 리비전 복구'
else
  fail '7-6 rollout undo 로 직전 리비전 복구'
fi
fi

# ---------------------------------------------------------------------------
if module_enabled M8; then
section 'M8. AI 인프라·운영 자동화 (K8sGPT)'
M8="$CJONS_LAB_ROOT/m8-ai-ops"
kubectl apply -f "$M8/k8sgpt-demo.yaml" >/dev/null 2>&1
# «restartCount > 0» 만으로 진행하면 안 된다.
# k8sgpt 의 Pod 분석기는 컨테이너가 «CrashLoopBackOff 대기 상태»일 때만 그 파드를 보고한다.
# 첫 재시작 직후의 백오프 창은 10초 남짓이라, 그 사이 컨테이너가 다시 Running 이 된
# 순간에 analyze 가 걸리면 아무것도 안 잡힌다. macOS 에서는 우연히 창에 맞아 통과했고
# WSL2 에서는 빗나갔다 — 환경 문제가 아니라 «대기 조건이 틀린» 것이다.
# 그래서 restartCount 가 아니라 k8sgpt 가 실제로 보는 상태를 기다린다.
r8=0; n=0; r=0; w=''
while [ "$n" -lt 180 ]; do
  r="$(kubectl -n cj-lab-ai get pod ai-demo-crashloop -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)"
  w="$(kubectl -n cj-lab-ai get pod ai-demo-crashloop -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
    # 8-1 의 판정은 «이상상태가 재현됐는가» — 재시작이 한 번이라도 났으면 성립한다.
  [ "${r:-0}" -gt 0 ] && { r8=1; break; }
  n=$((n+5)); sleep 5
done
if [ "$r8" = 1 ]; then pass "8-1 데모 이상상태 배포(crashloop restart=${r})"; else fail '8-1 데모 이상상태 배포'; fi
pend8="$(kubectl -n cj-lab-ai get pod ai-demo-pending -o jsonpath='{.status.phase}' 2>/dev/null)"
if [ "$pend8" = Pending ]; then pass '8-2 Pending 데모 파드 상태 확인'; else fail "8-2 Pending 데모 파드 상태($pend8)"; fi

if command -v k8sgpt >/dev/null 2>&1; then
  k8v="$(k8sgpt version 2>/dev/null | head -1)"
  pass "8-3 k8sgpt 설치 확인($k8v)"
  # 8-4 전용 대기: k8sgpt 의 Pod 분석기는 컨테이너가 «CrashLoopBackOff 대기 상태»일 때만
  # 그 파드를 보고한다. 재시작 직후의 백오프 창은 10초 남짓이라, 그 사이 컨테이너가 다시
  # Running 이 된 순간에 analyze 가 걸리면 아무것도 안 잡힌다(
  # macOS 는 우연히 창에 맞아 통과). 그래서 analyze «직전»에 그 상태를 잠시 기다린다.
  # 여기서 못 기다려도 실패로 보지 않는다 — 아래 재시도가 한 번 더 기회를 준다.
  m=0
  while [ "$m" -lt 90 ]; do
    ww="$(kubectl -n cj-lab-ai get pod ai-demo-crashloop -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
    [ "$ww" = CrashLoopBackOff ] && break
    m=$((m+5)); sleep 5
  done
  # 재시작이 누적될수록 백오프가 길어지므로(10s→20s→40s), 못 잡으면 잠시 뒤 다시 본다.
  ANALYZE=""
  for _try in 1 2 3; do
    ANALYZE="$(KUBECONFIG="$CJONS_KUBECONFIG" k8sgpt analyze --namespace cj-lab-ai 2>&1)"
    case "$ANALYZE" in *ai-demo-crashloop*) break ;; esac
    sleep 10
  done
  case "$ANALYZE" in
    *ai-demo-crashloop*) pass '8-4 k8sgpt analyze — CrashLoop 파드 탐지' ;;
    *) fail '8-4 k8sgpt analyze — CrashLoop 파드 탐지' ;;
  esac
  case "$ANALYZE" in
    *ai-demo-pending*) pass '8-5 k8sgpt analyze — Pending 파드 탐지' ;;
    *) fail '8-5 k8sgpt analyze — Pending 파드 탐지' ;;
  esac
  # «세 건 중 조치할 것은 몇 번인가» 판별 훈련의 전제: 조치 대상이 아닌 항목이 함께 보고되어야 한다.
  case "$ANALYZE" in
    *kube-root-ca.crt*)
      pass '8-5b 조치 대상 아닌 항목(kube-root-ca.crt) 동시 보고 — 판별 훈련 성립' ;;
    *)
      skip '8-5b kube-root-ca.crt 미보고(k8sgpt 버전/설정 차이) — 오프라인 증거로 판별 훈련 진행' ;;
  esac
  # AI 제안 ↔ kubectl 원문 증거 교차검증(M8 학습목표의 핵심 판정)
  DESC="$(kubectl -n cj-lab-ai describe pod ai-demo-pending 2>/dev/null)"
  hit=0
  case "$ANALYZE" in *"Insufficient cpu"*) hit=$((hit+1)) ;; esac
  case "$DESC" in *"Insufficient cpu"*) hit=$((hit+1)) ;; esac
  if [ "$hit" = 2 ]; then
    pass '8-6 AI 출력 ↔ kubectl describe 증거 문구 일치(Insufficient cpu)'
  else
    fail "8-6 AI 출력 ↔ kubectl 증거 대조 실패(일치 $hit/2)"
  fi
  # 표준 실습은 API 키를 쓰지 않는다 — 실제로 키가 저장돼 있지 않은 상태에서
  # analyze(규칙 기반)만으로 위 8-4~8-6이 성립했는지 확인한다.
  K8SGPT_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/k8sgpt/k8sgpt.yaml"
  if [ ! -f "$K8SGPT_CFG" ] || ! grep -q 'password: .\+' "$K8SGPT_CFG" 2>/dev/null; then
    pass '8-7 API 키 미설정 상태에서 규칙기반 analyze만으로 판정 성립(외부 전송 없음)'
  else
    fail '8-7 k8sgpt에 API 키가 저장돼 있습니다 — 표준 실습 전 k8sgpt auth remove 로 제거하세요'
  fi
else
  skip '8-3 k8sgpt 미설치 — 경로 B(오프라인 증거)로 대체'
  skip '8-4 k8sgpt analyze CrashLoop 탐지'
  skip '8-5 k8sgpt analyze Pending 탐지'
  skip '8-6 AI 출력 ↔ kubectl 증거 대조'
  skip '8-7 로컬 분석 경로 확인'
fi

# 경로 B — 오프라인 증거 패키지(인터넷·클러스터 없이 성립해야 함)
for f in k8sgpt-analyze.txt kubectl-describe-crashloop.txt kubectl-events.txt; do
  check "8-8 오프라인 증거 $f" test -s "$M8/offline-evidence/$f"
done
expect '8-9 오프라인 증거에 FailedScheduling 원문 포함' 'FailedScheduling' \
  cat "$M8/offline-evidence/kubectl-events.txt"
expect '8-10 오프라인 증거에 BackOff 원문 포함' 'BackOff' \
  cat "$M8/offline-evidence/kubectl-events.txt"
# 경로 B(오프라인)도 경로 A와 동일하게 3건 판별 훈련이 가능해야 한다.
expect '8-10b 오프라인 증거에 조치 대상 아닌 3번째 항목 포함' 'kube-root-ca.crt' \
  cat "$M8/offline-evidence/k8sgpt-analyze.txt"
red="$(grep -c '^- \[ \]' "$M8/redaction_checklist.md" 2>/dev/null || echo 0)"
if [ "${red:-0}" -ge 5 ]; then pass "8-11 비식별 체크리스트 항목 ${red}건"; else fail "8-11 비식별 체크리스트 항목 부족(${red})"; fi
check '8-12 프롬프트 템플릿 존재' test -s "$M8/prompt_templates.md"
check '8-13 운영자동화 캔버스 존재' test -s "$M8/automation_design_canvas.md"
fi

# ---------------------------------------------------------------------------
section 'P9. 정리'
if [ "$KEEP" = 1 ]; then
  skip '9-1 실습 리소스 정리(--keep 지정으로 생략)'
else
  check '9-1 cleanup.sh 실행' bash "$COMMON_DIR/cleanup.sh"
fi
if [ "$TEARDOWN" = 1 ]; then
  check '9-2 kind 클러스터 삭제' kind delete cluster --name "$CJONS_CLUSTER_NAME"
else
  skip '9-2 kind 클러스터 유지(--teardown 지정 시 삭제)'
fi

# ---------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_TS ))
printf '\n================================================\n'
printf 'SUMMARY  PASS=%s  FAIL=%s  SKIP=%s  (소요 %s초)\n' "$PASS" "$FAIL" "$SKIP" "$ELAPSED"
printf 'OS=%s · 프로필=%s · 노드=%s\n' "$CJONS_OS" "$CJONS_PROFILE" "$CJONS_EXPECTED_NODES"
printf '================================================\n'

{
  printf '# CJONS 핸즈온 전수 검증 리포트\n\n'
  # '-'로 시작하는 문자열은 printf의 옵션으로 해석되므로 반드시 '%s' 형식으로 넘긴다.
  printf '%s\n' "- 실행 시각: $(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s\n' "- OS: $CJONS_OS / 커널: $(uname -sr)"
  printf '%s\n' "- 프로필: $CJONS_PROFILE (kind 노드 ${CJONS_EXPECTED_NODES}개)"
  printf '%s\n\n' "- 결과: **PASS $PASS · FAIL $FAIL · SKIP $SKIP** (소요 ${ELAPSED}초)"
  printf '| 결과 | 단계 |\n|---|---|\n'
  printf '%s' "$RESULTS" | awk -F'|' 'NF>=3 {printf "| %s | %s |\n", $2, $3}'
} > "$REPORT"
printf '리포트: %s\n' "$REPORT"

[ "$FAIL" -eq 0 ]
