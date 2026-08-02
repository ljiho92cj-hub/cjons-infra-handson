# M8. AI Ops — AI 제안을 Kubernetes 증거로 검증하기

이 실습의 목표는 AI 도구를 설치하거나 외부 LLM에 연결하는 것이 아니라 `AI 제안 → kubectl 증거 → 사람의 판단`을 반복하는 것입니다. **API 키는 사용하지 않습니다.** K8sgpt의 외부 AI 설명 옵션도 표준 실습 범위 밖입니다.

## 두 경로, 같은 성공 기준

| 경로 | 입력 | 필요 환경 |
|---|---|---|
| A. 로컬 분석 | `k8sgpt-demo.yaml`의 재현 리소스 + K8sgpt `v0.4.36` | 실습 컨테이너에 내장된 K8sgpt, cjons-lab |
| B. 오프라인 판독 | `offline-evidence/`의 정규화된 AI/이벤트/describe 세트 | 터미널·인터넷·클러스터 불필요 |

두 경로 모두 “제안된 원인과 원문 증거가 일치하는가”를 한 문장으로 써야 완료입니다.

## 경로 A. 로컬 K8sgpt 분석

저장소 루트에서:

```bash
source 00-common/lab_env.sh
bash 00-common/check_env.sh ready
cd m8-ai-ops
```

K8sgpt는 실습 컨테이너(`cjons-lab:1.0`)에 `v0.4.36`으로 **이미 내장돼 있습니다. 따로 설치하지 않습니다.** 버전만 확인하고, 버전이 다르거나 명령이 없으면 설치에 시간을 쓰지 말고 경로 B로 전환합니다.

```bash
k8sgpt version
# validated course version: v0.4.36
```

항상 동일한 이상 상태가 나오도록 CrashLoop과 Pending Pod를 적용합니다.

```bash
kubectl apply -f k8sgpt-demo.yaml
STATE=''
for ATTEMPT in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do
  STATE="$(kubectl -n cj-lab-ai get pod ai-demo-crashloop \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  [ "$STATE" = CrashLoopBackOff ] && break
  sleep 5
done
[ "$STATE" = CrashLoopBackOff ]
kubectl -n cj-lab-ai get pod
KUBECONFIG="$CJONS_KUBECONFIG" k8sgpt analyze --namespace cj-lab-ai
```

> **접두어는 «생략 가능»합니다.** `source 00-common/lab_env.sh` 가 이 셸의 `KUBECONFIG` 를
> 실습 전용으로 export 하므로 `k8sgpt analyze --namespace cj-lab-ai` 만으로도 동작합니다.
> 위 표기는 «어느 셸에서 실행해도 안전한 명시적 형태»로 남겨둡니다.

고정 대기 대신 최대 120초 동안 **`CrashLoopBackOff` 대기 상태가 될 때까지** 기다린 뒤 분석합니다.
`restartCount > 0` 으로 기다리면 안 됩니다 — **k8sgpt 가 보는 것은 `state.waiting.reason`** 이라,
재시작은 했지만 아직 Running 인 순간에 analyze 가 걸리면 CrashLoop 을 «찾지 못한 채» 지나갑니다
(apply 직후 곧바로 analyze 하면 3건이 아니라 2건만 보고됩니다). 대기 조건은 «판정 도구가
보는 것»에 맞춥니다. 첫 백오프 창이 10초 남짓이라 체감상 잘 맞는 것처럼 보이는 것이 함정입니다.

K8sgpt 출력에서 두 Pod를 찾은 뒤 원문을 대조합니다. 파드명과 namespace를 수동 자리표로 바꾸지 않습니다.

```bash
LAB_NS=cj-lab-ai
CRASH_POD=ai-demo-crashloop
PENDING_POD=ai-demo-pending

kubectl -n "$LAB_NS" describe pod "$CRASH_POD"
kubectl -n "$LAB_NS" logs "$CRASH_POD" --previous
kubectl -n "$LAB_NS" describe pod "$PENDING_POD"
kubectl -n "$LAB_NS" get events --sort-by=.metadata.creationTimestamp
```

> **`logs --previous` 가 `unable to retrieve container logs for containerd://…` 로 실패해도 실습 실패가 아닙니다.**
> 첫 재시작 «직후» 에는 이전 컨테이너의 로그가 이미 회수됐을 수 있습니다.
> 몇 초 뒤 재실행하거나 `--previous` 를 빼고 `kubectl -n "$LAB_NS" logs "$CRASH_POD"` 로 보십시오 —
> 같은 `ERROR config file /config/app.yaml not found` 가 나옵니다.
> `describe` 의 `Last State: Terminated / Reason: Error / Exit Code: 1` 만으로도 AI 출력과의 대조는 성립합니다.

> `W0731 … v1 Endpoints is deprecated in v1.33+` 경고가 함께 뜹니다. k8sgpt가 구 API로 조회해서 나는
> **경고일 뿐 실패가 아닙니다.** 분석 결과에는 영향이 없습니다.

성공 기준:

- CrashLoop: 재시작/BackOff + `exit 1` + 직전 설정 파일 로그를 연결했다.
- Pending: `requests.cpu=100` + `FailedScheduling/Insufficient cpu`를 연결했다.
- **세 번째 항목(`kube-root-ca.crt` ConfigMap)을 «조치 대상 아님»으로 판정하고 그 근거를 썼다.**
- AI 출력에 없는 사실은 추가로 단정하지 않았다.

### 중요 — 출력은 2건이 아니라 3건입니다

**`--namespace cj-lab-ai` 로 범위를 좁힌 결과가 3건**입니다. 위 두 파드 외에 `ConfigMap cj-lab-ai/kube-root-ca.crt is not used by any pods`도 `Error`로 보고합니다.
이 ConfigMap은 **쿠버네티스가 모든 namespace에 자동 생성**하는 오브젝트(파드가 API 서버 인증서를 신뢰하는 데 사용)라 **지워도 다시 생깁니다 — 조치 대상이 아닙니다.**

> **이 모듈의 핵심**: 도구가 `Error`라고 부른 것 중 실제 조치 대상을 사람이 골라내는 것.
> 세 건 중 둘만 조치 대상입니다. 이 판별을 못 하면 자동화는 «노이즈 자동화»가 됩니다.

각 항목에 대해 «조치한다 / 조치하지 않는다»와 근거를 한 문장씩 쓰십시오. **조치하지 않기로 한 판단에도 근거가 필요합니다.**

> **`--namespace` 를 빼면 어떻게 되는가 — 한 번은 직접 보십시오.**
>
> **건수를 먼저 세고** 앞부분만 봅니다. 그냥 `head` 로 자르면 「이게 전부인가」로 잘못 판단합니다.
>
> ```bash
> KUBECONFIG="$CJONS_KUBECONFIG" k8sgpt analyze > /tmp/k8sgpt-all.txt
> grep -c '^[0-9]\+: ' /tmp/k8sgpt-all.txt     # 전체 몇 건인가
> head -40 /tmp/k8sgpt-all.txt                 # 앞부분만
> ```
>
> 클러스터 전체를 훑어 **13건 안팎**이 나옵니다. 늘어난 항목은 거의 전부
> `kube-system`·`kube-public`·`default`·`kube-node-lease`·`local-path-storage` 의 `kube-root-ca.crt` 류이고,
> **하나도 조치 대상이 아닙니다.** 앞 모듈 네임스페이스를 정리하지 않았다면 **더 늘어납니다**
> (예: 앞 모듈의 `cj-lab-traffic` 네임스페이스가 남아 있으면 14건, 정리하면 13건).
>
> 조치 대상 2건은 그대로인데 **잡음만 11건이 늘었습니다.** 범위를 좁히지 않은 자동 분석이
> 어떻게 «노이즈 자동화»가 되는지, 그리고 **운영에서 알림 범위 설계가 왜 도구 선택보다 중요한지**를
> 보여주는 장면입니다. 3건 판별을 끝낸 뒤 대조용으로 돌려 보십시오.
>
> **건수가 «환경에 따라 달라진다»는 것 자체가 관찰 대상입니다.** 같은 도구·같은 명령인데
> 클러스터에 무엇이 남아 있느냐로 결과가 바뀝니다. 알림 기준을 「Error 개수」로 잡으면
> 안 되는 이유가 이것입니다.

```bash
kubectl delete namespace cj-lab-ai --ignore-not-found --wait=true --timeout=60s
```

## 경로 B. 오프라인 증거 패키지

`offline-evidence/README.md`를 열고 다음 순서로 나란히 읽습니다.

1. `k8sgpt-analyze.txt`: 도구가 제시한 특이 리소스와 가설
2. `kubectl-describe-crashloop.txt`: CrashLoop의 state, exit code, BackOff
3. `kubectl-events.txt`: CrashLoop BackOff와 Pending FailedScheduling 원문

캡처는 동적인 시간·IP·노드명을 제거한 교육용 정규화 텍스트입니다. 원인 판독에 필요한 필드는 보존했습니다.

## 운영 자동화 워크숍

1. `redaction_checklist.md`로 실습 입력이 합성 데이터임을 확인합니다.
2. `sample_alerts.json` + `sample_logs.txt`를 시간순으로 정렬하고 `prompt_templates.md`의 근거 형식으로 가설을 씁니다.
3. `automation_design_canvas.md`에 알람→진단→요약→승인→조치→회고 여섯 단계를 설계합니다.
4. `incident_report_template.md`에 확정 원인과 미확인 가설을 구분해 남깁니다.

## 보안 가드레일

- 실습에서 인증 명령이나 API 키 입력을 요구하지 않습니다.
- 키를 CLI 인자로 넘기면 shell history와 process list에 남을 수 있으므로 금지합니다.
- 실제 회사명·서버명·고객정보·내부 IP·인증정보를 외부 AI에 입력하지 않습니다.
- AI 출력은 실행 전 사람이 원문 증거와 롤백 경로를 검증합니다.
