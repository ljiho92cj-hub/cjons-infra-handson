# M7. Kubernetes 장애 트러블슈팅

모든 랩은 `get → describe/events → logs --previous(컨테이너가 실행된 경우) → rollout`의 같은 판독 순서를 반복합니다. 전역 namespace/context를 바꾸지 않고 모든 명령에 namespace를 명시합니다.

## 준비

```bash
source 00-common/lab_env.sh
bash 00-common/check_env.sh ready
cd m7-k8s-troubleshooting
kubectl apply -f namespace.yaml
```

## Lab 7-1. CrashLoopBackOff

```bash
kubectl apply -f crashloop.yaml
RESTARTS=0
for ATTEMPT in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
  RESTARTS="$(kubectl -n cj-lab-trouble get pod crashloop \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
  [ "${RESTARTS:-0}" -gt 0 ] && break
  sleep 5
done
[ "${RESTARTS:-0}" -gt 0 ]
kubectl -n cj-lab-trouble get pod crashloop
kubectl -n cj-lab-trouble describe pod crashloop
kubectl -n cj-lab-trouble get events --sort-by=.metadata.creationTimestamp
kubectl -n cj-lab-trouble logs crashloop --previous
```

> **`logs --previous` 가 실패해도 실습 실패가 아닙니다.**
> 첫 재시작 «직후» 에는 이전 컨테이너의 로그가 이미 회수돼
> `unable to retrieve container logs for containerd://…` 가 날 수 있습니다.
> 몇 초 뒤 다시 실행하거나 `--previous` 를 빼고 `kubectl logs crashloop` 로 보십시오 —
> 이 컨테이너는 매 실행마다 같은 두 줄(`starting` · `missing configuration`)을 남기므로 판독 내용은 같습니다.
> **이 랩의 성공 증거는 `RESTARTS` 증가와 `BackOff` 이벤트**이며, 로그는 원인 문구를 확인하는 보조 증거입니다.

고정 `sleep` 대신 최대 120초 동안 첫 재시작을 기다립니다. `Last State`, `Exit Code`, 재시작 횟수와 종료 직전 로그를 연결합니다. 이 사례는 OOM이나 probe가 아니라 애플리케이션 시작 설정 오류입니다.

## Lab 7-2. Pending

```bash
kubectl apply -f pending.yaml
kubectl -n cj-lab-trouble get pod pending
kubectl -n cj-lab-trouble describe pod pending
kubectl -n cj-lab-trouble get events --sort-by=.metadata.creationTimestamp
```

Pod가 스케줄되지 않아 컨테이너 실행 로그가 없습니다. `requests.cpu=100`과 노드 `Allocatable`을 비교하고 `FailedScheduling / Insufficient cpu`를 근거로 남긴 뒤 정리합니다.

```bash
kubectl -n cj-lab-trouble delete pod pending
```

## Lab 7-3. drain과 PodDisruptionBudget 교착

drain은 **컨트롤러 없는 Pod를 만나면 PDB 검증에 닿기 전에 중단**됩니다. Lab 7-1의 단독 Pod가 그렇고,
**앞 모듈이 남긴 Pod도 마찬가지**입니다 — 예를 들어 M5의 `cj-lab-traffic/traffic-client` 와 **직전 모듈 M6의 `cj-lab-resources/qos-*`·`oom-stress`(모두 단독 Pod)** 가 같은 노드에 남아
있어 `cannot delete Pods that declare no controller` 로 drain이 즉시 끊기고, **PDB가 막는 장면을 관찰하지 못했습니다.**

먼저 이번 랩의 장애 주입을 정리하고, drain 대상 노드에 컨트롤러 없는 Pod가 남아 있는지 확인하십시오.

```bash
kubectl -n cj-lab-trouble delete pod crashloop pending --ignore-not-found --wait=true
kubectl apply -f pdb-demo.yaml
kubectl -n cj-lab-trouble rollout status deployment/web-pdb --timeout=90s
kubectl -n cj-lab-trouble get pdb web-pdb
DRAIN_NODE="$(kubectl -n cj-lab-trouble get pod -l app=web-pdb \
  -o jsonpath='{.items[0].spec.nodeName}')"
printf 'drain_target=%s\n' "$DRAIN_NODE"
```

drain 대상 노드에 **컨트롤러 없는 Pod**가 남아 있는지 먼저 봅니다. `OWNER` 열이 `<none>` 이면 그 Pod가 원인입니다.

```bash
kubectl get pod -A --field-selector spec.nodeName="$DRAIN_NODE" \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind
```

`<none>` 이 보이면 해당 모듈의 네임스페이스를 정리한 뒤 진행하십시오(앞 모듈 마무리를 건너뛴 경우 흔합니다).

```bash
kubectl delete namespace cj-lab-resources --ignore-not-found --wait=true --timeout=60s  # M6 잔여
kubectl delete namespace cj-lab-traffic   --ignore-not-found --wait=true --timeout=60s  # M5 잔여
```

> **이 조회는 «그 순간»의 스냅샷입니다.** 다른 창에서 앞 모듈 실습이 계속 돌고 있으면 조회 뒤에 생긴 Pod는
> 잡히지 않습니다(조회에는 없던 다른 네임스페이스의 단독 Pod가 drain 시점에 나타나
> 「no controller」로 먼저 막을 수 있습니다). **최종 판정은 drain 자신의 메시지로 합니다** —
> `violate the pod disruption budget` 이면 PDB(=이 랩의 목표), `declare no controller` 면 잔여 Pod입니다.
> 후자가 보이면 그 네임스페이스를 지우고 drain을 다시 실행하십시오.

`ALLOWED DISRUPTIONS=0`을 확인한 뒤 45초 timeout으로 drain을 시도합니다. 명령이 실패 종료하는 것이 이 장애 주입의 성공 결과입니다.

```bash
kubectl drain "$DRAIN_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=45s || \
  echo '[EXPECTED] drain이 정상 종료하지 않았습니다 — 아래 「무엇이 막았는가」로 원인을 확인하십시오.'
kubectl -n cj-lab-trouble get pdb web-pdb
kubectl uncordon "$DRAIN_NODE"
kubectl delete -f pdb-demo.yaml --ignore-not-found
```

> **무엇이 막았는가 — 메시지를 반드시 구분해서 읽으십시오.**
>
> | drain 출력 | 무엇이 막았나 | 이 랩의 성공인가 |
> |---|---|---|
> | `Cannot evict pod as it would violate the pod's disruption budget` | **PDB** — `minAvailable=2` 를 깨뜨릴 수 없어 eviction 거부 | **성공** |
> | `cannot delete Pods that declare no controller (use --force to override)` | 컨트롤러 없는 Pod(앞 모듈 잔여 등) — **PDB에 닿기도 전에 중단** | 실패. 위 정리 후 재시도 |
>
> 「drain이 실패했으니 PDB가 막은 것」이라고 넘겨짚지 마십시오. **막은 주체를 증거로 특정하는 것**이 이 랩의 핵심입니다.

새 replica를 추가해 `minAvailable=2`를 만족시키거나, PDB를 완화하거나, 정비를 연기하는 세 선택의 영향을 비교합니다. 실습 후 `uncordon`은 필수입니다.

## Lab 7-4. 롤링 업데이트 실패와 rollback

```bash
kubectl apply -f rollout-good.yaml
kubectl -n cj-lab-trouble rollout status deployment/web-rollout --timeout=90s
kubectl -n cj-lab-trouble get pod -l app=web-rollout

kubectl apply -f rollout-bad.yaml
kubectl -n cj-lab-trouble rollout status deployment/web-rollout --timeout=45s || \
  echo '[EXPECTED] 새 replica가 Ready가 되지 않아 rollout이 timeout됐습니다.'
BAD_POD="$(kubectl -n cj-lab-trouble get pod -l app=web-rollout \
  --sort-by=.metadata.creationTimestamp -o name | tail -n 1)"
printf 'failed_pod=%s\n' "$BAD_POD"
kubectl -n cj-lab-trouble describe "$BAD_POD"
```

`nginx:cjons-missing-v2.1` + `imagePullPolicy: Never`이므로 외부 registry 네트워크 없이 `ErrImageNeverPull`이 재현됩니다. 정상/장애 두 매니페스트에는 모두 `maxUnavailable: 0`, `maxSurge: 1`, `progressDeadlineSeconds: 60`이 있어 기존 Ready Pod 3개가 유지됩니다.

```bash
kubectl -n cj-lab-trouble rollout undo deployment/web-rollout
kubectl -n cj-lab-trouble rollout status deployment/web-rollout --timeout=90s
kubectl -n cj-lab-trouble rollout history deployment/web-rollout
```

> **`history`에 REVISION 1이 없고 2·3만 보이는 것이 정상입니다.**
> `undo`는 옛 revision을 «되돌리는» 것이 아니라 **그 내용을 새 revision으로 다시 적용**합니다.
> 그래서 revision 1(정상 이미지)의 내용이 revision **3**으로 올라가고, 1은 목록에서 사라집니다.
> 2는 방금 실패한 `nginx:cjons-missing-v2.1` 입니다.
>
> | REVISION | 내용 |
> |---:|---|
> | ~~1~~ | 정상 이미지 — 3으로 «이동»했습니다 |
> | 2 | 실패한 이미지(`cjons-missing`) |
> | 3 | 정상 이미지 재적용 = 현재 |
>
> **롤백은 «과거로 가는 것»이 아니라 «과거의 내용으로 새로 배포하는 것»** 이라는 뜻이고,
> 그래서 롤백 자체도 하나의 배포로 기록·추적됩니다. `CHANGE-CAUSE`가 `<none>`인 것은
> `--record`(deprecated)나 `kubernetes.io/change-cause` 애노테이션을 쓰지 않아서이며 정상입니다.

## 성공 기준과 정리

`incident_ticket_template.md`에 증상/영향 → 최근 변경 → 첫 관찰 → 이벤트·로그 근거 → 원인 → 조치 → 검증 → 재발방지를 작성합니다. 원인은 반드시 증거 행과 연결되어야 합니다.

```bash
kubectl delete namespace cj-lab-trouble --ignore-not-found --wait=true --timeout=60s
```
