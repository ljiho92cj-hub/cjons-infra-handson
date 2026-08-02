# M8 오프라인 증거 매핑

이 폴더는 `k8sgpt-demo.yaml`의 CrashLoop/Pending 상태에서 진단에 필요한 필드만 보존하고 동적인 시간·IP·노드명을 제거한 교육용 정규화 캡처입니다. 실제 운영 데이터는 포함하지 않습니다.

| # | 도구 제안 | 원문 근거 | 판독 | 조치 대상? |
|---|---|---|---|---|
| 1 | `ai-demo-crashloop` 재시작/BackOff | `kubectl-describe-crashloop.txt`의 Terminated `Exit Code: 1`, Events `BackOff`; 이전 로그의 config missing | 애플리케이션 시작 설정 오류 가설이 증거와 일치 | **예** |
| 2 | `ai-demo-pending` 스케줄 불가 | `kubectl-events.txt`의 `FailedScheduling`, `Insufficient cpu`; 매니페스트 request 100 CPU | 노드 장애가 아니라 비정상적인 request가 직접 원인 | **예** |
| 3 | `kube-root-ca.crt` ConfigMap 미사용 | **별도 원문 근거 없음.** 이 ConfigMap은 Kubernetes가 **모든 namespace에 자동 생성**하는 오브젝트다(파드가 API 서버 인증서를 신뢰하는 데 사용) | 도구는 `Error`로 보고했지만 «삭제 대상»이 아니다. 지워도 다시 생성된다 | **아니오** |

## 이 폴더의 핵심 훈련

**도구가 `Error`라고 부른 것 중 실제로 조치할 것은 무엇인가.**

세 건 중 조치 대상은 두 건입니다. 3번을 걸러내지 못하면 AI 보조 운영은 «노이즈 자동화»가 됩니다.
운영 파이프라인에 넣는다면 3번 같은 항목은 **억제(suppress) 규칙**으로 관리해야 합니다.

사용 절차:

1. `k8sgpt-analyze.txt`만 읽고 **세 건 각각에 대해** 가설을 쓴다.
2. 나머지 두 파일로 각 가설을 지지/반박한다. **뒷받침할 원문이 아예 없는 항목이 있다는 사실 자체가 신호다.**
3. 각 건에 «조치한다 / 조치하지 않는다»와 근거를 한 문장씩 쓴다.
4. 근거가 없는 설명은 "미확인"으로 남긴다. **조치하지 않기로 한 판단에도 근거를 남긴다.**
