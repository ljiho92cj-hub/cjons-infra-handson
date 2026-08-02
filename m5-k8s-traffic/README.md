# M5. Kubernetes 아키텍처와 트래픽 경로

이 Lab은 공통 `cjons-lab` 클러스터만 사용합니다. `kubectl port-forward service/...`는 Service VIP·kube-proxy를 검증하지 않고 선택된 Pod로 직접 터널링하므로, 이 Lab의 트래픽 성공/실패 판정에 사용하지 않습니다. 클러스터 내 `traffic-client` Pod의 요청으로 Service 경로를 끝까지 통과합니다.

## 준비

저장소 루트에서:

```bash
source 00-common/lab_env.sh
bash 00-common/check_env.sh ready
cd m5-k8s-traffic
```

## Lab 5-1. 선언에서 Pod까지 추적

이 Lab은 **창 두 개**를 씁니다. 터미널 A를 그대로 둔 채, 호스트에서 새 창을 열고
`.\lab\lab.cmd`(macOS·Linux는 `bash lab/lab.sh`)를 **그대로 다시 실행**하면 셸이 하나 더 붙습니다.
붙은 셸에서 `source 00-common/lab_env.sh` 와 `cd m5-k8s-traffic` 을 먼저 실행하십시오.
자세히는 저장소 루트 `README.md` §0-4 · §0-5.

터미널 A — **관찰 창**. Deployment를 적용하기 **직전에** 먼저 띄웁니다.

```bash
kubectl apply -f namespace.yaml
kubectl -n cj-lab-traffic get pod -o wide --watch
```

> **`--watch`는 커서만 깜빡이고 아무것도 안 찍히는 것이 정상입니다.** 멈춘 것이 아니라 이벤트를
> 기다리는 중이고, 아직 Pod가 없어서 출력할 것이 없을 뿐입니다. **이 창은 그대로 두고**
> 터미널 B를 열어 아래를 진행하십시오. 터미널 B에서 Deployment를 적용하는 순간부터
> 이 창에 `Pending → ContainerCreating → Running` 이 흐릅니다.

> `--watch`는 **리소스 타입을 하나만** 받습니다. `get deployment,replicaset,pod --watch`처럼 두 타입을 묶으면
> `error: you may only specify a single resource type`으로 즉시 거부됩니다(`-o wide`를 붙여도 같습니다).
> 그래서 관찰 창은 **Pod 하나만** 흘려보고, 상위 리소스(Deployment·ReplicaSet)는 watch가 아니라 **조회**로 확인합니다.
> Pod를 고른 이유는 `Pending → ContainerCreating → Running` 전이가 눈에 보이는 유일한 계층이기 때문입니다.

터미널 B — **조작·확인 창**:

```bash
[ -f deployment.yaml ] || cd m5-k8s-traffic     # 새 창이라 /work 에 있어도 자리를 잡아 줍니다
kubectl apply -f deployment.yaml
kubectl -n cj-lab-traffic get deployment,replicaset,pod -o wide     # 1회 조회는 여러 타입을 묶어도 됩니다
kubectl -n cj-lab-traffic rollout status deployment/web --timeout=90s
kubectl -n cj-lab-traffic describe deployment web
kubectl -n cj-lab-traffic get events --sort-by=.metadata.creationTimestamp
```

터미널 A에서 Pod가 하나씩 살아나는 동안, 터미널 B의 조회 결과에는 그 Pod를 만든 ReplicaSet과 그 위의 Deployment가 함께 보입니다. **Pod가 갑자기 생긴 것이 아니라 계층을 타고 내려온 결과**라는 것을 두 화면으로 대조하는 것이 이 랩의 요지입니다.

`Deployment → ReplicaSet → Pod → kubelet`을 각각 누가 수렴시키는지, `Running`과 readiness `Ready`가 왜 같은 개념이 아닌지를 기록합니다. 관찰을 끝낼 때는 터미널 A에서 `Ctrl-C`를 누릅니다.

## Lab 5-2. EndpointSlice 상태와 Service VIP → Pod 요청

```bash
kubectl apply -f service.yaml -f client.yaml
kubectl -n cj-lab-traffic wait --for=condition=Ready pod/traffic-client --timeout=60s
kubectl -n cj-lab-traffic get service,endpointslice,pod -o wide
kubectl -n cj-lab-traffic exec traffic-client -- wget -T 2 -qO- http://web
```

> ⚠ 주의: 접속 확인은 반드시 wget 자체의 `-T <초>` 타임아웃을 사용합니다. busybox `timeout N wget ...` 래퍼는 시그널 전파로 traffic-client Pod 본체(sleep)를 종료시켜 Lab이 중단될 수 있습니다.

nginx HTML이 보이면 클러스터 내 실제 Service 경로가 성공한 것입니다. EndpointSlice는 패킷이 거치는 hop이 아니라 Service selector가 만든 backend 상태이며, kube-proxy가 노드 전송 규칙을 만드는 입력입니다. 이제 요청을 보낸 Pod의 노드와 Service IP를 명령으로 구합니다. 직접 바꾸어 넣는 자리표는 없습니다.

> **셸 변수는 창을 넘어가지 않습니다.** 아래 블록은 증거를 확인할 창, 즉 **터미널 B에서** 실행하십시오.
> 터미널 A에서만 설정하면 터미널 B의 `$CLIENT_NODE` 가 비어 `docker exec` 가 인자 부족으로 실패합니다.

```bash
CLIENT_NODE="$(kubectl -n cj-lab-traffic get pod traffic-client -o jsonpath='{.spec.nodeName}')"
SERVICE_IP="$(kubectl -n cj-lab-traffic get service web -o jsonpath='{.spec.clusterIP}')"
printf 'client_node=%s service_ip=%s\n' "$CLIENT_NODE" "$SERVICE_IP"
```

터미널 A에서 짧은 요청을 반복하고:

```bash
kubectl -n cj-lab-traffic exec traffic-client -- sh -c \
  'i=0; while [ "$i" -lt 200 ]; do wget -T 1 -qO /dev/null http://web || true; i=$((i+1)); sleep 0.1; done'
```

터미널 B에서 같은 노드의 iptables/conntrack을 보조 증거로 확인합니다.

```bash
docker exec "$CLIENT_NODE" iptables-save -t nat | grep -F "$SERVICE_IP" || true

# 세션 «건수»를 먼저 보고, 표본 5건만 펼칩니다(200요청이면 수백 행이 쏟아집니다)
docker exec "$CLIENT_NODE" conntrack -L -p tcp 2>/dev/null | grep -cF "$SERVICE_IP" || true
docker exec "$CLIENT_NODE" conntrack -L -p tcp 2>/dev/null | grep -F "$SERVICE_IP" | head -5 || true
```

**읽는 법**: conntrack 한 줄에 `dst=<Service IP>` 로 나간 요청과 `src=<Pod IP>` 로 돌아온 응답이 함께 적혀 있습니다.
**같은 Service IP에 대해 `src=` 가 두 종류(worker의 Pod IP·worker2의 Pod IP)로 나오면**, VIP가 hop이 아니라
**DNAT 규칙이고 요청이 실제로 두 Pod에 갈라져 꽂혔다**는 증거입니다. 이 Lab의 결론이 이 한 화면에 있습니다.

> **창을 두 개 못 열었어도 됩니다.** conntrack 항목은 `TIME_WAIT` 로 60초 남짓 남으므로,
> 같은 창에서 요청 루프를 끝낸 «직후» 위 명령을 실행해도 동일한 증거가 보입니다.

Docker Desktop/kind 노드 구성에 따라 conntrack 행은 짧게 사라질 수 있습니다. 필수 성공 기준은 Service IP 요청과 EndpointSlice이고, 노드 규칙은 보이면 좋은 보조 증거입니다. 보이지 않아도 이 Lab은 통과입니다.

> 노드 수는 프로필에 따라 다릅니다 — `std`는 3노드(worker 2), `low`는 2노드(worker 1)입니다.
> `low`에서는 `web` replica 2개와 `traffic-client`가 모두 같은 worker에 올라가므로 **다중 worker 분산 관찰만 축소**되고,
> Service VIP → EndpointSlice → kube-proxy 규칙이라는 이 Lab의 판독 순서는 그대로 성립합니다.

## Lab 5-3. selector 장애 주입·복구

```bash
kubectl apply -f broken-service.yaml
kubectl -n cj-lab-traffic get service web -o jsonpath='{.spec.selector}'; echo
kubectl -n cj-lab-traffic get endpointslice -l kubernetes.io/service-name=web -o wide

# 새 Service 요청이 실패하면 정상
kubectl -n cj-lab-traffic exec traffic-client -- wget -T 2 -qO- http://web
```

실패 원인을 `Service selector(app=web-typo)`와 `Pod label(app=web)`의 불일치로 설명한 뒤 복구합니다.

```bash
kubectl apply -f service.yaml
kubectl -n cj-lab-traffic get endpointslice -l kubernetes.io/service-name=web -o wide
kubectl -n cj-lab-traffic exec traffic-client -- wget -T 2 -qO- http://web
```

## 성공 기준과 정리

- 컨트롤 루프와 데이터 플레인 트래픽을 구분했다.
- EndpointSlice가 빈 상태와 selector/label 불일치를 함께 증거로 남겼다.
- port-forward 성공을 Service VIP 성공으로 판별하지 않았다.

```bash
kubectl delete namespace cj-lab-traffic --ignore-not-found --wait=true --timeout=60s
```
