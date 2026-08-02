# M4. HA 설계와 etcd quorum

HA를 `감지 → 중재 → 격리 → 전환 → 롤백`으로 분해하고, etcd 3노드에서 3/3→2/3→1/3으로 변할 때 쓰기 결과를 관찰합니다. 호스트 포트를 열지 않고 Docker Compose 네트워크 안에서만 통신합니다.

## 준비

```bash
# 저장소 루트에서
bash 00-common/check_env.sh assets
cd m4-ha-design

# 전용 project 이름으로 시작
docker compose -p cjons-m4 up -d --wait --wait-timeout 90
docker compose -p cjons-m4 ps
```

`etcd1`, `etcd2`, `etcd3`가 모두 `healthy`여야 진행합니다. 이미지는 `gcr.io/etcd-development/etcd:v3.6.11`로 고정돼 있고 `pull_policy: never`이므로 미리 받아 둔 로컬 이미지만 사용합니다(없으면 `bash 00-common/prefetch_assets.sh`를 먼저 실행하십시오).

## 1. 3/3 노드 — quorum 보유

```bash
docker compose -p cjons-m4 exec etcd1 etcdctl \
  --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 \
  --command-timeout=3s put foo bar
docker compose -p cjons-m4 exec etcd1 etcdctl \
  --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379 \
  --command-timeout=3s get foo
```

## 2. 2/3 노드 — quorum 유지

```bash
docker compose -p cjons-m4 stop etcd3
docker compose -p cjons-m4 exec etcd1 etcdctl \
  --endpoints=http://etcd1:2379,http://etcd2:2379 \
  --command-timeout=3s put foo baz
```

노드 1개가 사라져도 2/3 과반수가 있어 쓰기가 성공합니다.

## 3. 1/3 노드 — quorum 상실

```bash
docker compose -p cjons-m4 stop etcd2
docker compose -p cjons-m4 exec etcd1 etcdctl \
  --endpoints=http://etcd1:2379 \
  --dial-timeout=2s --command-timeout=3s put foo qux
```

timeout/오류로 종료되는 것이 성공 결과입니다. 과반수를 잃은 클러스터가 스플릿 브레인으로 틀린 쓰기를 하기보다 쓰기를 거부하는 것입니다.

**다만 에러 메시지는 「거부했다」는 «점검사항»일 뿐입니다.** 정말 반영되지 않았는지는 §4에서 데이터로 확인합니다.

## 4. 복구·검증

복구 직후 **먼저 읽습니다.** 새로 쓰기 전에 읽어야 `qux`가 정말 버려졌는지 볼 수 있습니다.

```bash
docker compose -p cjons-m4 start etcd2
sleep 5

# ① 먼저 읽는다 — quorum 상실 중 시도한 qux 가 남았는지 확인
docker compose -p cjons-m4 exec etcd1 etcdctl \
  --endpoints=http://etcd1:2379,http://etcd2:2379 \
  --command-timeout=3s get foo
```

> **①에서는 `baz` 또는 `qux` 가 나옵니다 — 둘 다 정상 관찰입니다.** 어느 쪽이 나오는지는 실행마다 달라집니다.
>
> | 값 | 무슨 일이 있었나 | 교훈 |
> |---|---|---|
> | `baz` | 1/3 시점의 `put foo qux` 제안이 리더 로그에 닿지 못하고 **유실** — 거부가 데이터로 증명 | 과반 없는 쓰기는 남지 않는다 |
> | `qux` | 제안이 (당시 리더였던) 노드의 raft 로그에 **적재만** 돼 있다가, quorum 복귀 «후»에 커밋 | **클라이언트 타임아웃은 실패 확정이 아니라 «결과 불명»** — 에러를 받았어도 적용됐을 수 있다 |
>
> 어느 쪽이든 불변인 것: **커밋은 quorum이 있는 동안에만 일어났습니다.** 상실 «중»에 커밋된 것이 아니므로
> 「과반수 없이 커밋하지 않는다」와 스플릿 브레인 방지는 그대로 성립합니다(분리된 «다른 쪽»이 애초에 없습니다).
>
> `qux`가 나왔다면 한 단계 깊은 실무 교훈까지 얻은 것입니다 — **타임아웃 후의 재시도는 멱등해야 하고,
> 성공 여부의 최종 판정은 에러 메시지가 아니라 읽기로 합니다.** 이 모듈에서 다루는 fencing의
> 「확실하지 않으면 확실하게」와 같은 철학입니다.

그 다음 새로 쓰고, 쓰기가 다시 되는지 확인합니다.

```bash
# ② 복구 후 새 쓰기
docker compose -p cjons-m4 exec etcd1 etcdctl \
  --endpoints=http://etcd1:2379,http://etcd2:2379 \
  --command-timeout=3s put foo recovered
docker compose -p cjons-m4 exec etcd1 etcdctl \
  --endpoints=http://etcd1:2379,http://etcd2:2379 \
  --command-timeout=3s get foo
```

`bar → baz → (qux — 거부 또는 지연 커밋) → recovered` 네 단계가 **저장된 값의 이력**으로 남습니다. 증설·장애 보고서에 「쓰기가 거부됐다」를 쓸 때 근거로 삼을 수 있는 형태가 이것입니다.

## 정리와 설계 워크숍

```bash
docker compose -p cjons-m4 down -v --remove-orphans
```

`-v`로 실습 볼륨을 지워야 다음에 다시 실행할 때 같은 초기 상태에서 시작합니다. 시간이 부족하면 1/3 실패 증거만 관찰해도 됩니다. 그 뒤 `ha_design_canvas.md`에 시나리오 카드 1개의 감지·격리·전환·롤백 조건을 작성합니다.
