#!/usr/bin/env python3
"""CJONS M3 용량산정 계산기.

기본 workbook 프로필은 같은 디렉터리의 Excel 템플릿의 기본 입력·산식·결과와
일치한다. csv 프로필은 동봉된 504개 시계열에서 p95와 성장률을
직접 계산하는 심화 트랙이다. 두 프로필의 입력이 다르므로 결과도
다르며, 출력에 사용한 가정을 항상 표시한다.
"""

from __future__ import annotations

import argparse
import csv
import math
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_DATA = SCRIPT_DIR / "sample_data.csv"

WORKBOOK_DEFAULTS = {
    # CPU 기준값은 모니터링 W4 «Peak»(11.6)이다 — P95(10.1)가 아니다.
    # Memory는 P95(27.1)를 쓰는 비대칭 구성이며, 그 선택 근거를 논의하는 것이 실습의 일부다.
    "cpu_base": 11.6,
    "mem_p95": 27.1,
    "growth_factor": 1.3,
    "promo_multiplier": 1.8,
    "target_utilization": 0.65,
    "n_plus_1": 1.2,
    "disk_current": 528.0,
    "disk_daily_growth": 5.7,
    "planning_horizon_days": 90,
    "disk_safety_factor": 1.3,
    "disk_target_utilization": 0.70,
}


def load_series(path: str | Path) -> list[dict[str, datetime | float]]:
    """CSV를 검증해 timestamp 오름차순 레코드로 반환한다."""
    csv_path = Path(path)
    try:
        handle = csv_path.open(newline="", encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"입력 CSV를 열 수 없습니다: {csv_path} ({exc})") from exc

    records: list[dict[str, datetime | float]] = []
    required = {"timestamp", "cpu_used_vcpu", "mem_used_gib", "disk_used_gib"}
    with handle:
        reader = csv.DictReader(handle)
        if not reader.fieldnames or not required.issubset(reader.fieldnames):
            missing = sorted(required.difference(reader.fieldnames or []))
            raise ValueError(f"CSV 필수 컬럼이 없습니다: {', '.join(missing)}")
        for line_no, row in enumerate(reader, start=2):
            try:
                records.append(
                    {
                        "ts": datetime.strptime(row["timestamp"], "%Y-%m-%d %H:%M"),
                        "cpu": float(row["cpu_used_vcpu"]),
                        "mem": float(row["mem_used_gib"]),
                        "disk": float(row["disk_used_gib"]),
                    }
                )
            except (TypeError, ValueError) as exc:
                raise ValueError(f"CSV {line_no}행을 해석할 수 없습니다: {exc}") from exc

    if not records:
        raise ValueError(f"입력 CSV가 비어 있습니다: {csv_path}")
    records.sort(key=lambda item: item["ts"])
    timestamps = [record["ts"] for record in records]
    if len(timestamps) != len(set(timestamps)):
        raise ValueError("CSV timestamp에 중복이 있습니다.")
    return records


def percentile(values: list[float], pct: float) -> float:
    """선형 보간 백분위수. pct는 0~100 범위다."""
    if not values:
        raise ValueError("빈 리스트의 백분위수는 계산할 수 없습니다.")
    if not 0 <= pct <= 100:
        raise ValueError("pct는 0~100 범위여야 합니다.")
    ordered = sorted(values)
    rank = (len(ordered) - 1) * pct / 100.0
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (rank - lower)


def daily_p95(records: list[dict[str, datetime | float]], field: str) -> dict[str, float]:
    by_day: dict[str, list[float]] = defaultdict(list)
    for record in records:
        timestamp = record["ts"]
        if not isinstance(timestamp, datetime):
            raise ValueError("timestamp 형식이 잘못되었습니다.")
        by_day[timestamp.strftime("%Y-%m-%d")].append(float(record[field]))
    return {day: percentile(values, 95) for day, values in sorted(by_day.items())}


def weekly_growth_rate(daily_values: dict[str, float]) -> float:
    values = list(daily_values.values())
    if len(values) < 14:
        raise ValueError("2주 미만 데이터로는 주간 성장률을 계산할 수 없습니다.")
    first_average = statistics.mean(values[:7])
    last_average = statistics.mean(values[-7:])
    elapsed_weeks = (len(values) - 7) / 7.0
    if first_average <= 0 or last_average < 0:
        raise ValueError("성장률 기준값은 양수여야 합니다.")
    return (last_average / first_average) ** (1.0 / elapsed_weeks) - 1.0


def required_capacity(
    base_value: float,
    weekly_rate: float,
    horizon_weeks: float,
    target_utilization: float,
    n_plus_1: float,
    promo_multiplier: float,
) -> float:
    """기준부하 × 성장 × 피크 ÷ 목표사용률 × HA 여유."""
    if base_value < 0 or weekly_rate <= -1 or horizon_weeks < 0:
        raise ValueError("기준부하·성장률·계획기간 값을 확인하세요.")
    validate_positive("target_utilization", target_utilization, upper=1.0)
    validate_positive("n_plus_1", n_plus_1)
    validate_positive("promo_multiplier", promo_multiplier)
    projected = base_value * (1.0 + weekly_rate) ** horizon_weeks
    return projected * promo_multiplier / target_utilization * n_plus_1


def project_disk(
    records: list[dict[str, datetime | float]], planning_horizon_days: int
) -> tuple[float, float, float]:
    first = records[0]
    last = records[-1]
    first_ts, last_ts = first["ts"], last["ts"]
    if not isinstance(first_ts, datetime) or not isinstance(last_ts, datetime):
        raise ValueError("timestamp 형식이 잘못되었습니다.")
    elapsed_days = (last_ts - first_ts).total_seconds() / 86400.0
    if elapsed_days <= 0:
        raise ValueError("관측 기간은 0일보다 길어야 합니다.")
    latest = float(last["disk"])
    daily_growth = (latest - float(first["disk"])) / elapsed_days
    return latest, daily_growth, latest + daily_growth * planning_horizon_days


def validate_positive(name: str, value: float, upper: float | None = None) -> None:
    if not math.isfinite(value) or value <= 0 or (upper is not None and value > upper):
        suffix = f"~{upper}" if upper is not None else ""
        raise ValueError(f"{name}은 0보다 크고 {suffix} 범위여야 합니다: {value}")


def workbook_results(args: argparse.Namespace) -> dict[str, int]:
    validate_positive("cpu_base", args.cpu_base)
    validate_positive("mem_p95", args.mem_p95)
    validate_positive("growth_factor", args.growth_factor)
    validate_positive("promo_multiplier", args.promo_multiplier)
    validate_positive("target_utilization", args.target_utilization, upper=1.0)
    validate_positive("n_plus_1", args.n_plus_1)
    validate_positive("disk_current", args.disk_current)
    validate_positive("disk_daily_growth", args.disk_daily_growth)
    validate_positive("planning_horizon_days", float(args.planning_horizon_days))
    validate_positive("disk_safety_factor", args.disk_safety_factor)
    validate_positive("disk_target_utilization", args.disk_target_utilization, upper=1.0)

    cpu = args.cpu_base * args.growth_factor * args.promo_multiplier
    cpu = cpu / args.target_utilization * args.n_plus_1
    memory = args.mem_p95 * args.growth_factor * args.promo_multiplier
    memory = memory / args.target_utilization * args.n_plus_1
    disk = args.disk_current + args.disk_daily_growth * args.planning_horizon_days
    disk = disk * args.disk_safety_factor / args.disk_target_utilization * args.n_plus_1
    return {"cpu": math.ceil(cpu), "memory": math.ceil(memory), "disk": math.ceil(disk)}


def run_workbook(args: argparse.Namespace) -> None:
    result = workbook_results(args)
    print("PROFILE=workbook (Excel 기본값 동기화)")
    print(
        f"CPU  = ceil({args.cpu_base} × {args.growth_factor} × {args.promo_multiplier} "
        f"÷ {args.target_utilization} × {args.n_plus_1}) = {result['cpu']} vCPU"
    )
    print(
        f"MEM  = ceil({args.mem_p95} × {args.growth_factor} × {args.promo_multiplier} "
        f"÷ {args.target_utilization} × {args.n_plus_1}) = {result['memory']} GiB"
    )
    print(
        f"DISK = ceil(({args.disk_current} + {args.disk_daily_growth} × {args.planning_horizon_days}) "
        f"× {args.disk_safety_factor} ÷ {args.disk_target_utilization} × {args.n_plus_1}) "
        f"= {result['disk']} GiB"
    )


def run_csv(args: argparse.Namespace) -> None:
    data_path = Path(args.data).expanduser() if args.data else DEFAULT_DATA
    records = load_series(data_path)
    horizon_weeks = args.planning_horizon_days / 7.0
    cpu_by_day = daily_p95(records, "cpu")
    mem_by_day = daily_p95(records, "mem")
    cpu_base = list(cpu_by_day.values())[-1]
    mem_base = list(mem_by_day.values())[-1]
    cpu_growth = weekly_growth_rate(cpu_by_day)
    mem_growth = weekly_growth_rate(mem_by_day)
    cpu_required = required_capacity(
        cpu_base, cpu_growth, horizon_weeks, args.target_utilization,
        args.n_plus_1, args.csv_promo_multiplier,
    )
    mem_required = required_capacity(
        mem_base, mem_growth, horizon_weeks, args.target_utilization,
        args.n_plus_1, args.csv_promo_multiplier,
    )
    disk_latest, disk_growth, disk_projected = project_disk(records, args.planning_horizon_days)
    disk_required = disk_projected / args.disk_target_utilization * args.n_plus_1

    first_ts, last_ts = records[0]["ts"], records[-1]["ts"]
    print(f"PROFILE=csv (input={data_path})")
    print(f"관측: {first_ts} ~ {last_ts}, {len(records)} samples")
    print(f"CPU : p95={cpu_base:.2f}, weekly_growth={cpu_growth:.2%}, required={cpu_required:.1f} vCPU")
    print(f"MEM : p95={mem_base:.2f}, weekly_growth={mem_growth:.2%}, required={mem_required:.1f} GiB")
    print(
        f"DISK: latest={disk_latest:.1f}, daily_growth={disk_growth:.2f}, "
        f"projected={disk_projected:.1f}, required={disk_required:.1f} GiB"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="M3 용량산정 계산기")
    parser.add_argument("--profile", choices=("workbook", "csv"), default="workbook")
    parser.add_argument("--data", help="csv 프로필 입력. 생략하면 스크립트 옆 sample_data.csv")
    parser.add_argument("--cpu-base", "--cpu-p95", dest="cpu_base", type=float,
                        default=WORKBOOK_DEFAULTS["cpu_base"])
    parser.add_argument("--mem-p95", type=float, default=WORKBOOK_DEFAULTS["mem_p95"])
    parser.add_argument("--growth-factor", type=float, default=WORKBOOK_DEFAULTS["growth_factor"])
    parser.add_argument("--promo-multiplier", type=float, default=WORKBOOK_DEFAULTS["promo_multiplier"])
    parser.add_argument("--target-utilization", type=float, default=WORKBOOK_DEFAULTS["target_utilization"])
    parser.add_argument("--n-plus-1", type=float, default=WORKBOOK_DEFAULTS["n_plus_1"])
    parser.add_argument("--disk-current", type=float, default=WORKBOOK_DEFAULTS["disk_current"])
    parser.add_argument("--disk-daily-growth", type=float, default=WORKBOOK_DEFAULTS["disk_daily_growth"])
    parser.add_argument(
        "--planning-horizon-days", type=int,
        default=WORKBOOK_DEFAULTS["planning_horizon_days"],
    )
    parser.add_argument("--disk-safety-factor", type=float, default=WORKBOOK_DEFAULTS["disk_safety_factor"])
    parser.add_argument(
        "--disk-target-utilization", type=float,
        default=WORKBOOK_DEFAULTS["disk_target_utilization"],
    )
    parser.add_argument(
        "--csv-promo-multiplier", type=float, default=1.3,
        help="csv 프로필의 이벤트 피크 배수",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.profile == "workbook":
            run_workbook(args)
        else:
            validate_positive("csv_promo_multiplier", args.csv_promo_multiplier)
            validate_positive("planning_horizon_days", float(args.planning_horizon_days))
            validate_positive("target_utilization", args.target_utilization, upper=1.0)
            validate_positive("n_plus_1", args.n_plus_1)
            validate_positive("disk_target_utilization", args.disk_target_utilization, upper=1.0)
            run_csv(args)
    except ValueError as exc:
        print(f"ERROR: {exc}")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
