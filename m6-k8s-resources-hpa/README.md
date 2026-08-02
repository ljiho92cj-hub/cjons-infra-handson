# M6. Kubernetes 리소스·QoS·HPA

핵심은 `requests`(스케줄러·HPA의 기준)와 `limits`(컨테이너 상한)을 분리해 판독하는 것입니다. QoS 분류, 컨테이너 limit OOM, 노드 메모리 압박에 의한 축출은 서로 다른 현상입니다.

## 준비

```bash
source 00-common/lab_env.sh
bash 00-common/check_env.sh ready
cd m6-k8s-resources-hpa
```

`setup_cluster.sh`가 checksum을 확인한 metrics-server `v0.8.1` 매니페스트를 적용하므로 `releases/latest`나 원격 URL을 강의 중 실행하지 않습니다.

```bash
kubectl top nodes
kubectl get apiservice v1beta1.metrics.k8s.io
```

## Lab 6-1. QoS와 limit OOM을 구분

```bash
kubectl apply -f namespace.yaml -f deployment-resources.yaml -f qos-oomkill-demo.yaml
kubectl -n cj-lab-resources rollout status deployment/web-hpa --timeout=90s
kubectl -n cj-lab-resources get pod -l demo=qos \
  -o custom-columns=NAME:.metadata.name,QOS:.status.qosClass
METRICS_READY=0
for ATTEMPT in 1 2 3 4 5 6 7 8 9 10 11 12; do
  if kubectl -n cj-lab-resources top pod; then
    METRICS_READY=1
    break
  fi
  sleep 5
done
[ "$METRICS_READY" -eq 1 ]
```

Pod Ready 직후에는 metrics-server 수집 전이라 `metrics not available yet`가 잠시 나올 수 있습니다. 위 명령은 최대 60초만 재시도합니다. 예상 분류는 `Guaranteed / Burstable / BestEffort`입니다. 이 세 Pod는 노드 메모리를 압박하지 않으므로 “BestEffort가 먼저 죽는 순서”를 시연하지 않습니다. 그 순서는 노드 압박과 kubelet 축출 정책을 설명할 때만 사용합니다.

단일 컨테이너의 64MiB limit OOM을 재현합니다. 현재 이미지에 없는 tag는 당겨오지 않도록 `imagePullPolicy: Never`로 고정했습니다.

```bash
kubectl delete -f oom-stress.yaml --ignore-not-found
kubectl apply -f oom-stress.yaml
kubectl -n cj-lab-resources get pod oom-stress --watch --request-timeout=60s
# 상태가 OOMKilled/Failed로 바뀌면 Ctrl-C
kubectl -n cj-lab-resources get pod oom-stress \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}{" exit="}{.status.containerStatuses[0].state.terminated.exitCode}{"\n"}'
```

`restartPolicy: Never`이므로 `lastState`가 아니라 `state.terminated.reason=OOMKilled`, `exitCode=137`을 보는 것이 성공 기준입니다.

## Lab 6-2. HPA

HPA CPU 사용률은 `실제 CPU / requests.cpu`입니다. `web-hpa`의 request 50m와 target 20%를 함께 읽으면 기준은 Pod당 평균 10m입니다.

```bash
kubectl apply -f hpa.yaml
kubectl -n cj-lab-resources get hpa web-hpa
kubectl apply -f loadgen.yaml
kubectl -n cj-lab-resources get hpa --watch --request-timeout=240s
# replica가 증가하면 Ctrl-C
```

> `--watch`는 **리소스 타입을 하나만** 받습니다. `get hpa,pod --watch`처럼 두 타입을 묶으면
> `error: you may only specify a single resource type`으로 즉시 거부됩니다.
> HPA의 `REPLICAS` 열에 Pod 수가 그대로 보이므로 scale-out 관찰에는 `get hpa --watch`로 충분합니다.
> Pod 하나하나의 전이(Pending → ContainerCreating → Running)까지 보려면 **터미널을 하나 더 열어** 병행 관찰합니다.
> 두 번째 창은 호스트에서 새 창을 열고 `.\lab\lab.cmd`(macOS·Linux는 `bash lab/lab.sh`)를 그대로
> 다시 실행하면 붙습니다(기존 창은 죽지 않습니다). 붙은 셸에서 `source 00-common/lab_env.sh` 를
> 먼저 실행하십시오 — 자세히는 저장소 루트 `README.md` §0-4 · §0-5.
> `--watch`가 아무것도 찍지 않는 것은 정상입니다 — 이벤트를 기다리는 중입니다.
>
> ```bash
> # 터미널 B
> kubectl -n cj-lab-resources get pod -w
> ```

`TARGETS` 값이 오르고 replica가 2 이상으로 변하면 scale-out 성공입니다. 부하생성기는 CPU 100m·메모리 32Mi 상한이 있어 노트북을 무제한 사용하지 않습니다.

```bash
kubectl -n cj-lab-resources delete deployment loadgen
kubectl -n cj-lab-resources get hpa --watch --request-timeout=180s
# REPLICAS가 줄면 Ctrl-C. 아래 「얼마나 기다리나」를 먼저 읽으십시오.
```

> **얼마나 기다리나 — 1분 30초 안팎입니다. 그 전에 끊으면 관찰에 실패합니다.**
>
> loadgen을 지워도 `TARGETS`는 곧바로 떨어지지 않고, 떨어진 뒤에도 `REPLICAS`는 바로 줄지 않습니다.
> 두 지연이 순서대로 겹칩니다. 아래 경과 시간은 **loadgen 삭제 시점 기준**입니다.
>
> | 경과 | `TARGETS` | `REPLICAS` | 무슨 일이 일어나는 중인가 |
> |---:|---|:---:|---|
> | ~35초 | `20%/20%` | 3 | 아직 **부하 시절의 측정치**입니다. metrics가 늦게 따라옵니다 |
> | ~50초 | `9%/20%` | 3 | CPU는 떨어졌지만 **안정화 창이 최근 30초의 «최대»를 유지**합니다 |
> | ~65초 | `2%/20%` | 3 | 여기서부터 **30초**를 더 세십시오 |
> | ~1분 30초 | `2%/20%` | **1** | scale-in. `minReplicas`까지 한 번에 내려갑니다 |
>
> 놓치기 쉬운 지점은 **~50초**입니다. CPU가 9%까지 떨어졌는데도 `REPLICAS`가 3 그대로라
> 「안 되는구나」 하고 끊게 됩니다. 그때가 **안정화 창이 일하고 있는 중**입니다 —
> 창 안에 아직 `20%`(요구치 3) 샘플이 남아 있어 HPA가 그 최대값을 존중하는 것입니다.
> 진동(flapping)을 막으려고 일부러 둔 지연이며, **이 지연을 보는 것이 이 랩의 관찰 대상입니다.**
>
> `hpa.yaml`의 `stabilizationWindowSeconds`는 **실습 관찰용 30초**입니다.
> 쿠버네티스 기본값은 **300초**이고 운영에서는 60~300초를 씁니다 — 그대로 가져가지 마십시오.
> 60초로 두면 scale-in까지 2분 남짓 걸려 도중에 포기하기 쉽기 때문에 낮춘 값입니다.

> **왜 3 → 2가 아니라 3 → 1로 한 번에 내려가는가**
>
> HPA의 목표 replica는 `ceil(현재 replica × 현재 사용률 ÷ target)` 입니다.
>
> | 사용률 | 계산 | 목표 replica |
> |---:|---|:---:|
> | 20% | `ceil(3 × 20 ÷ 20)` | 3 — 그대로 |
> | 19% | `ceil(3 × 19 ÷ 20) = ceil(2.85)` | 3 — **여전히 그대로** |
> | 9% | `ceil(3 × 9 ÷ 20) = ceil(1.35)` | 2 |
> | 2% | `ceil(3 × 2 ÷ 20) = ceil(0.3)` | 1 — `minReplicas` |
>
> 「조금 떨어졌는데 왜 그대로인가」의 답이 이 **올림**에 있습니다. 3에서 2로 내려가려면
> 사용률이 **target의 2/3(약 13%) 아래**로 가야 합니다 — scale-out 때와 같은 식입니다.
>
> 부하가 걸린 동안 `TARGETS`가 `20%/20%`에 오래 머무는 것도 같은 이유입니다.
> replica 3개가 target에 정확히 수렴한 상태라 **더 늘릴 이유도, 줄일 이유도 없습니다.**

HPA가 움직이지 않으면 `kubectl top pod` → target 컨테이너의 CPU request → HPA target → 실제 요청 유입 순으로 판독합니다.

### 심화 참고 — CPU·메모리로 부족할 때 (읽기만 합니다)

큐 길이나 초당 요청 수처럼 **애플리케이션 지표로 스케일해야 하는 워크로드**가 있습니다.
`autoscaling/v2`의 `Pods`/`Object`/`External` 메트릭 타입이 그 경로인데, K8s가 그 값을 직접
수집하지는 않으므로 **메트릭 어댑터**가 Prometheus 같은 저장소의 값을 K8s API 형태로 바꿔줘야 합니다.

`bonus/prometheus-adapter-configmap-example.yaml` 이 그 어댑터 설정의 참고 예시입니다.
**적용하지 마십시오** — Helm values 형식이 아니고, Prometheus와 `prometheus-adapter`가 이미 있어야
의미가 생깁니다. 파일을 열어 **세 줄기만** 읽으면 충분합니다.

| 항목 | 무엇을 정하는가 |
|---|---|
| `seriesQuery` | Prometheus에서 **어떤 raw 메트릭을 가져올 것인가** |
| `resources` | 그 메트릭을 **어떤 K8s 리소스(namespace/pod 등)에 매핑**할 것인가 |
| `metricsQuery` | raw 값을 **실제 사용률로 만드는 PromQL 템플릿** |

어댑터가 붙으면 API 서버에 `custom.metrics.k8s.io`·`external.metrics.k8s.io` 가 등록됩니다.
**이 랩의 클러스터에는 어댑터가 없으므로 아래 명령은 비어 있는 것이 정상입니다** — 「무엇을 확인하면
되는지」를 알아두는 용도입니다.

```bash
kubectl get apiservices | grep metrics.k8s.io      # v1beta1.metrics.k8s.io 만 보이면 정상
```

기억할 것은 하나입니다 — CPU·메모리로 부족하면 확장 경로가 있고, 그 경로는 항상
**「메트릭 저장소 → 어댑터 → K8s API → HPA」** 라는 같은 파이프라인을 탑니다.

## 정리

```bash
kubectl delete namespace cj-lab-resources --ignore-not-found --wait=true --timeout=60s
```
