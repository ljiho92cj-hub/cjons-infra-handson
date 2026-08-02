# M3. 용량산정 실습 — Excel·Python 검산

기본 실습은 Excel과 Python이 **같은 입력값, 같은 산식, 같은 결과**를 내는 `workbook` 프로필입니다. 그 뒤 504개 시계열에서 p95와 성장률을 직접 구하는 `csv` 심화 프로필로 확장합니다.

## 1. 기본 검산 — workbook 프로필

```bash
# 저장소 루트에서
cd m3-capacity-sizing

python3 capacity_calc.py
```

| 리소스 | 동기화된 산식 | 기본 결과 |
|---|---|---:|
| CPU | `ceil(11.6 × 1.3 × 1.8 ÷ 0.65 × 1.2)` — 기준값 11.6은 **W4 Peak**(P95 아님) | 51 vCPU |
| Memory | `ceil(27.1 × 1.3 × 1.8 ÷ 0.65 × 1.2)` | 118 GiB |
| Disk | `ceil((528 + 5.7 × 90) × 1.3 ÷ 0.70 × 1.2)` | 2,320 GiB |

Excel의 `용량산정` 시트에서 노란 가정 셀을 바꾼 뒤 Python에도 **대응하는** 옵션을 적용해 검산합니다
(성장 배수→`--growth-factor`는 **CPU·Memory에만** 작용하고, Disk에는 별도의 `--disk-safety-factor`가 대응합니다).

```bash
python3 capacity_calc.py --target-utilization 0.60
python3 capacity_calc.py --growth-factor 1.5 --promo-multiplier 1.4
# ↑ 이 명령에서 DISK가 2320으로 «그대로»인 것이 정상입니다 — Disk는 일평균 증가×기간으로
#   성장을 이미 반영하므로 성장 배수를 다시 곱하지 않습니다(엑셀도 「Disk 안전 계수」 셀이 별도).
python3 capacity_calc.py --planning-horizon-days 120
```

0·음수·사용률 100% 초과와 같은 잘못된 입력은 traceback 대신 `ERROR` 메시지와 exit 2를 반환합니다.

## 2. 시계열 심화 — csv 프로필

```bash
python3 capacity_calc.py --profile csv
```

`sample_data.csv`는 2026-05-01~21의 21일×24시간, 504개의 중복 없는 합성 레코드입니다. 코드는 **기본 CSV를 스크립트 옆에서** 찾으므로 실행 위치와 무관합니다. 직접 확인해 봅니다.

```bash
# ── 여기서만 저장소 루트로 올라갑니다 ──
cd ..
python3 m3-capacity-sizing/capacity_calc.py --profile csv

# 확인이 끝나면 모듈 디렉터리로 돌아옵니다 (§3이 여기서 실행됩니다)
cd m3-capacity-sizing
```

앞의 결과와 숫자가 같으면 「실행 위치와 무관」이 확인된 것입니다.

> **`--data` 는 이야기가 다릅니다.** 스크립트 옆에서 찾는 규칙은 **기본 CSV에만** 적용되고,
> `--data` 로 넘긴 경로는 **현재 위치 기준 상대경로 또는 절대경로**로 해석됩니다.
> 아래 두 줄을 «그대로» 실행해 성공과 실패를 나란히 보십시오 — 같은 파일을 가리키는데 결과가 갈립니다.
>
> ```bash
> python3 capacity_calc.py --profile csv --data ./sample_data.csv        # 성공: 현재 위치에 있음
> ( cd .. && python3 m3-capacity-sizing/capacity_calc.py --profile csv --data sample_data.csv )
> #                                    ↑ 실패: 루트에는 sample_data.csv 가 없다
> ```
>
> 두 번째 줄은 `ERROR: 입력 CSV를 열 수 없습니다: sample_data.csv` 로 끝나는 것이 정상입니다.
> **`--data` 를 줄 때는 «내가 지금 어디에 있는가»가 곧 기준점**이라는 뜻입니다.

`csv` 프로필은 데이터에서 최신 일별 p95·첫 주/마지막 주 성장률·디스크 일평균 증가를 다시 계산하므로 workbook 프로필과 숫자가 다른 것이 정상입니다. 결과만 비교하지 말고 입력 출처와 가정을 함께 적습니다.

## 3. 자동 검산

```bash
# 모듈 디렉터리(m3-capacity-sizing)에서 실행합니다
python3 -m unittest discover -s tests -v
```

테스트는 workbook 기본값 51/118/2320, 실행 경로와 무관한 CSV 로딩, 504행·중복 timestamp, 잘못된 사용률의 실패 처리를 확인합니다.

> `Start directory is not importable: 'tests'` 또는 `NO TESTS RAN` 이 나오면 저장소 루트에 있는 것입니다
> (메시지는 Python 버전에 따라 다릅니다). `-s tests` 는 **현재 위치 기준**이므로
> `cd m3-capacity-sizing` 후 다시 실행하십시오.

### 3-1. 테스트를 «읽는» 5분 (선택)

`tests/test_capacity_calc.py` 는 검사 도구이기 전에 **이 실습의 가정이 코드로 못박힌 자리**입니다.
용량산정에서 다투게 되는 것은 대개 계산식이 아니라 **가정**이고, 그 가정이 어디에 적혀 있는지가 실무의 절반입니다.

| 테스트 | 못박고 있는 것 |
|---|---|
| `test_workbook_golden_results` | Excel과 Python이 **51 / 118 / 2320** 으로 같아야 한다 — §1의 정답값 |
| `test_default_csv_is_script_relative_and_valid` | 기본 CSV는 «스크립트 옆», 504행·timestamp 중복 없음 |
| `test_cli_works_outside_module_directory` | 어느 디렉터리에서 실행해도 결과가 같아야 한다 (§2에서 확인한 사항) |
| `test_zero_target_utilization_is_rejected` | 사용률 0은 traceback이 아니라 **exit 2 + `ERROR:`** 로 거부 |
| `test_percentile_boundaries` | p95 계산의 경계(0·100번째 백분위) |

**가정을 바꾸면 테스트가 깨지는지** 직접 보십시오. 원본을 건드리지 않도록 사본에서 실험합니다.

```bash
rm -rf /tmp/m3-try && cp -r . /tmp/m3-try && cd /tmp/m3-try

# 목표 사용률의 «기본값»을 0.65 → 0.60 으로 바꾼다
sed -i 's/"target_utilization": 0.65/"target_utilization": 0.60/' capacity_calc.py
python3 -m unittest discover -s tests

cd - >/dev/null && rm -rf /tmp/m3-try     # 실험 종료 — 원본은 그대로
```

이렇게 실패합니다.

```
AssertionError: {'cpu': 55, 'memory': 127, 'disk': 2320} != {'cpu': 51, 'memory': 118, 'disk': 2320}
FAILED (failures=1)
```

**55 / 127 은 §1에서 `--target-utilization 0.60` 으로 이미 본 숫자**입니다. 숫자는 같은데 의미가 다릅니다 —
옵션으로 준 0.60은 «이번 한 번의 탐색»이고, 기본값을 고친 0.60은 «가정 자체의 변경»입니다.
**테스트는 후자만 잡습니다.** 팀이 합의한 가정을 누군가 조용히 바꾸는 것을 막는 장치가 이것입니다.

> **실무 연결**: 증설 근거 문서에 「목표 사용률 65%」라고 쓰는 것만으로는 부족합니다.
> 그 값이 **어디에 적혀 있고, 바뀌면 무엇이 깨지는지**까지 있어야 6개월 뒤에 같은 결론이 재현됩니다.

## 성공 기준

- p95, 성장/이벤트 배수, 목표 사용률, N+1이 각각 어디에 들어가는지 설명했다.
- Excel과 Python 기본 결과가 51/118/2320으로 일치함을 검산했다.
- `숫자 → 시점 → 조치`로 이어지는 3줄 증설 권고를 작성했다.
- (선택) 가정이 코드의 어디에 못박혀 있는지 짚고, 그 값을 바꾸면 무엇이 깨지는지 확인했다.
