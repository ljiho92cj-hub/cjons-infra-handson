# M5 트래픽 경로·컨트롤 상태 기록

## 실제 패킷 경로

`traffic-client Pod → Service ClusterIP:80 → 노드 kube-proxy/iptables DNAT → backend PodIP:80 → nginx container`

- Service ClusterIP:
- client Pod가 실행된 노드:
- 성공/실패 요청 결과:

## 규칙을 만드는 컨트롤 상태

`Service selector → Pod labels 매칭 → EndpointSlice backend 목록 → kube-proxy 전송 규칙`

EndpointSlice는 패킷 hop이 아니라 규칙 구성의 입력 상태입니다.

- Service selector:
- Pod labels:
- EndpointSlice endpoints:
- 정상 selector와 장애 selector의 차이:
- 이 증거로 내린 판단 1문장:
