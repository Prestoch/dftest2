#!/usr/bin/env python3
"""
Generate the Dotabuff counter picker matrix (cs.json) from match data.

The script ingests:
  * A newline-delimited JSON file of matches (2023_2025_matches.json)
  * A hero id -> matrix index mapping (hero_id_map.json)
  * A template file that contains the canonical hero ordering/backgrounds (cs_original.json)

It outputs:
  * cs.json which mirrors the structure expected by index.html / dotabuffcp.js
    and includes additional hero metric arrays (gpm/xpm/etc).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import sys
from pathlib import Path
from typing import Dict, List, Optional, Tuple


METRIC_FIELDS = {
    "gpm": "heroes_gpm",
    "xpm": "heroes_xpm",
    "hero_damage": "heroes_hero_damage",
    "tower_damage": "heroes_tower_damage",
    "damage_taken": "heroes_damage_taken",
    "teamfight_participation": "heroes_teamfight_participation",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build cs.json style matrix from matches.")
    parser.add_argument(
        "--matches",
        default="2023_2025_matches.json",
        help="Path to newline-delimited JSON matches file.",
    )
    parser.add_argument(
        "--hero-map",
        default="hero_id_map.json",
        help="Path to hero ID -> matrix index mapping JSON.",
    )
    parser.add_argument(
        "--template",
        default="cs_original.json",
        help="Path to template file that holds hero ordering/backgrounds.",
    )
    parser.add_argument(
        "--output",
        default="cs.json",
        help="Destination file for the generated matrix.",
    )
    parser.add_argument(
        "--min-sample",
        type=int,
        default=5,
        help="Minimum vs-hero sample size required to keep a winrate entry.",
    )
    return parser.parse_args()


def extract_js_array(content: str, var_name: str) -> List:
    """
    Extracts the JSON array assigned to `var_name` inside a JS snippet.

    This function looks for `<var_name> = [` and then captures until the matching
    closing bracket. It assumes well-formed arrays with double-quoted strings.
    """
    marker = f"{var_name} ="
    start_idx = content.find(marker)
    if start_idx == -1:
        raise ValueError(f"Could not locate '{var_name}' in template.")

    array_start = content.find("[", start_idx)
    if array_start == -1:
        raise ValueError(f"Could not find '[' for {var_name}.")

    depth = 0
    array_end = None
    for i in range(array_start, len(content)):
        ch = content[i]
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
            if depth == 0:
                array_end = i + 1
                break

    if array_end is None:
        raise ValueError(f"Could not find matching ']' for {var_name}.")

    array_str = content[array_start:array_end]
    return json.loads(array_str)


def load_hero_metadata(template_path: Path) -> Tuple[List[str], List[str]]:
    """Return (heroes, heroes_bg) arrays from the template file."""
    content = template_path.read_text(encoding="utf-8")
    heroes = extract_js_array(content, "heroes")
    heroes_bg = extract_js_array(content, "heroes_bg")

    if len(heroes) != len(heroes_bg):
        raise ValueError("heroes and heroes_bg arrays differ in length.")

    return heroes, heroes_bg


def safe_float(value: Optional[float]) -> Optional[float]:
    if value is None:
        return None
    try:
        num = float(value)
    except (TypeError, ValueError):
        return None
    if math.isnan(num) or math.isinf(num):
        return None
    return num


def process_matches(
    matches_path: Path,
    hero_map: Dict[int, int],
    num_heroes: int,
) -> Tuple[
    List[int],
    List[int],
    Dict[str, List[float]],
    Dict[str, List[int]],
    List[float],
    List[int],
    List[List[int]],
    List[List[int]],
]:
    """Iterate through matches and accumulate hero/pair statistics."""
    hero_matches = [0] * num_heroes
    hero_wins = [0] * num_heroes
    duration_sum = [0.0] * num_heroes
    duration_count = [0] * num_heroes

    metric_sums = {metric: [0.0] * num_heroes for metric in METRIC_FIELDS}
    metric_counts = {metric: [0] * num_heroes for metric in METRIC_FIELDS}

    pair_matches = [[0] * num_heroes for _ in range(num_heroes)]
    pair_wins = [[0] * num_heroes for _ in range(num_heroes)]

    total_matches = 0
    skipped_matches = 0

    with matches_path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            match = json.loads(line)
            total_matches += 1

            radiant_team = match.get("radiant_team")
            dire_team = match.get("dire_team")
            winner_team = match.get("winner")
            players = match.get("players") or []

            if not radiant_team or not dire_team or not winner_team or len(players) < 2:
                skipped_matches += 1
                continue

            if winner_team == radiant_team:
                winner_side = "radiant"
            elif winner_team == dire_team:
                winner_side = "dire"
            else:
                skipped_matches += 1
                continue

            duration = safe_float(match.get("duration_minutes"))

            sides = {"radiant": [], "dire": []}
            for player in players:
                hero_id = player.get("hero_id")
                if hero_id is None:
                    continue
                idx = hero_map.get(int(hero_id))
                if idx is None:
                    continue

                team_name = player.get("player_team")
                if team_name == radiant_team:
                    side = "radiant"
                elif team_name == dire_team:
                    side = "dire"
                else:
                    continue

                sides[side].append((idx, player))

            if not sides["radiant"] or not sides["dire"]:
                skipped_matches += 1
                continue

            for side_name, hero_list in sides.items():
                is_win = side_name == winner_side
                for hero_idx, player in hero_list:
                    hero_matches[hero_idx] += 1
                    if is_win:
                        hero_wins[hero_idx] += 1

                    if duration is not None:
                        duration_sum[hero_idx] += duration
                        duration_count[hero_idx] += 1

                    for metric_key in METRIC_FIELDS:
                        value = safe_float(player.get(metric_key))
                        if value is None:
                            continue
                        metric_sums[metric_key][hero_idx] += value
                        metric_counts[metric_key][hero_idx] += 1

            for rad_idx, _ in sides["radiant"]:
                for dire_idx, _ in sides["dire"]:
                    pair_matches[rad_idx][dire_idx] += 1
                    if winner_side == "radiant":
                        pair_wins[rad_idx][dire_idx] += 1

                    pair_matches[dire_idx][rad_idx] += 1
                    if winner_side == "dire":
                        pair_wins[dire_idx][rad_idx] += 1

    print(f"Processed matches: {total_matches - skipped_matches}/{total_matches} (skipped {skipped_matches})")
    return (
        hero_matches,
        hero_wins,
        metric_sums,
        metric_counts,
        duration_sum,
        duration_count,
        pair_matches,
        pair_wins,
    )


def build_hero_metric_array(sums: List[float], counts: List[int], decimals: int = 2) -> List[float]:
    result = []
    for total, count in zip(sums, counts):
        if count:
            value = total / count
            result.append(round(value, decimals))
        else:
            result.append(0.0)
    return result


def build_hero_duration_array(duration_sum: List[float], duration_count: List[int]) -> List[float]:
    durations = []
    for total, count in zip(duration_sum, duration_count):
        if count:
            durations.append(round(total / count, 2))
        else:
            durations.append(0.0)
    return durations


def build_heroes_wr(hero_matches: List[int], hero_wins: List[int]) -> List[str]:
    wr = []
    for wins, matches in zip(hero_wins, hero_matches):
        if matches:
            pct = wins / matches * 100.0
        else:
            pct = 0.0
        wr.append(f"{pct:.2f}")
    return wr


def build_win_rates(
    pair_matches: List[List[int]],
    pair_wins: List[List[int]],
    min_sample: int,
) -> List[List[Optional[List]]]:
    matrix: List[List[Optional[List]]] = []
    size = len(pair_matches)
    for i in range(size):
        row: List[Optional[List]] = []
        for j in range(size):
            if i == j:
                row.append(None)
                continue

            matches = pair_matches[i][j]
            if matches < min_sample:
                row.append(None)
                continue

            wins = pair_wins[i][j]
            win_rate = wins / matches * 100.0
            advantage = win_rate - 50.0
            row.append(
                [
                    f"{advantage:.4f}",
                    f"{win_rate:.4f}",
                    matches,
                ]
            )
        matrix.append(row)
    return matrix


def write_output(
    output_path: Path,
    heroes: List[str],
    heroes_bg: List[str],
    heroes_wr: List[str],
    additional_arrays: Dict[str, List[float]],
    win_rates: List[List[Optional[List]]],
    update_time: str,
) -> None:
    lines = []
    lines.append(f"var heroes = {json.dumps(heroes, ensure_ascii=False)};")
    lines.append(f"var heroes_bg = {json.dumps(heroes_bg, ensure_ascii=False)};")
    lines.append(f"var heroes_wr = {json.dumps(heroes_wr)};")

    for js_key, values in additional_arrays.items():
        lines.append(f"var {js_key} = {json.dumps(values)};")

    lines.append(f"var win_rates = {json.dumps(win_rates, separators=(',', ':'))};")
    lines.append(f'var update_time = "{update_time}";')

    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote matrix to {output_path}")


def main() -> None:
    args = parse_args()

    matches_path = Path(args.matches)
    hero_map_path = Path(args.hero_map)
    template_path = Path(args.template)
    output_path = Path(args.output)

    if not matches_path.exists():
        sys.exit(f"Matches file not found: {matches_path}")
    if not hero_map_path.exists():
        sys.exit(f"Hero map file not found: {hero_map_path}")
    if not template_path.exists():
        sys.exit(f"Template file not found: {template_path}")

    heroes, heroes_bg = load_hero_metadata(template_path)

    hero_map_raw = json.loads(hero_map_path.read_text(encoding="utf-8"))
    hero_map = {int(k): int(v) for k, v in hero_map_raw.items()}

    num_heroes = len(heroes)
    if set(hero_map.values()) != set(range(num_heroes)):
        missing = set(range(num_heroes)) - set(hero_map.values())
        raise ValueError(f"Hero map does not cover all hero slots. Missing indexes: {sorted(missing)}")

    (
        hero_matches,
        hero_wins,
        metric_sums,
        metric_counts,
        duration_sum,
        duration_count,
        pair_matches,
        pair_wins,
    ) = process_matches(matches_path, hero_map, num_heroes)

    heroes_wr = build_heroes_wr(hero_matches, hero_wins)

    additional_arrays: Dict[str, List[float]] = {}
    for metric_key, js_key in METRIC_FIELDS.items():
        additional_arrays[js_key] = build_hero_metric_array(
            metric_sums[metric_key],
            metric_counts[metric_key],
            decimals=2,
        )

    additional_arrays["heroes_match_duration"] = build_hero_duration_array(duration_sum, duration_count)

    win_rates = build_win_rates(pair_matches, pair_wins, args.min_sample)

    update_time = dt.date.today().isoformat()

    write_output(
        output_path,
        heroes,
        heroes_bg,
        heroes_wr,
        additional_arrays,
        win_rates,
        update_time,
    )


if __name__ == "__main__":
    main()

