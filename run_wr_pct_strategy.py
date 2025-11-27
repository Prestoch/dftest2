import json
import csv
import argparse
from collections import defaultdict
from pathlib import Path

START_BANKROLL = 1000
MAX_BET = 10000
PERCENTS = [0.10, 0.20, 0.30, 0.40, 0.50]
ODDS_CAPS = [1.9, 1.8, 1.7, 1.6, 1.5, 1.4, 1.3, 1.2]
DELTA_THRESHOLDS = [50, 100, 150, 200, 250, 300, 350, 400]


def normalize_name(name: str) -> str:
    return name.replace("\u00a0", " ").strip().lower()


def safe_float(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def load_cs_data(cs_path: Path):
    sandbox = {}
    code = cs_path.read_text(encoding="utf-8").replace("var ", "").replace("null", "None")
    exec(code, sandbox)
    return sandbox


def build_match_dataset(cs_data, matches_path: Path):
    heroes = cs_data["heroes"]
    hero_wr = [float(x) for x in cs_data["heroes_wr"]]
    win_rates = cs_data["win_rates"]
    hero_index = {normalize_name(name): idx for idx, name in enumerate(heroes)}

    dataset = []
    with matches_path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            team1_list = [h.strip() for h in (row.get("team1_heroes") or "").split("|") if h.strip()]
            team2_list = [h.strip() for h in (row.get("team2_heroes") or "").split("|") if h.strip()]
            if len(team1_list) != 5 or len(team2_list) != 5:
                continue

            missing = False
            team1_idx = []
            team2_idx = []
            for hero in team1_list:
                idx = hero_index.get(normalize_name(hero))
                if idx is None:
                    missing = True
                    break
                team1_idx.append(idx)
            if missing:
                continue
            for hero in team2_list:
                idx = hero_index.get(normalize_name(hero))
                if idx is None:
                    missing = True
                    break
                team2_idx.append(idx)
            if missing:
                continue

            def hero_adv(hero_idx, opp_list):
                total = 0.0
                for opp_idx in opp_list:
                    cell = win_rates[opp_idx]
                    if cell and cell[hero_idx]:
                        adv = cell[hero_idx][0]
                        total += float(adv) if adv is not None else 0.0
                return total * -1

            team1_score = sum(hero_wr[idx] + hero_adv(idx, team2_idx) for idx in team1_idx)
            team2_score = sum(hero_wr[idx] + hero_adv(idx, team1_idx) for idx in team2_idx)

            odds1 = safe_float(row.get("team1_odds"))
            odds2 = safe_float(row.get("team2_odds"))
            winner_name = row.get("winner")
            winner = None
            if winner_name == row.get("team1"):
                winner = "team1"
            elif winner_name == row.get("team2"):
                winner = "team2"

            if winner is None or odds1 is None or odds2 is None:
                continue

            dataset.append({
                "delta": team1_score - team2_score,
                "odds_team1": odds1,
                "odds_team2": odds2,
                "winner": winner,
            })

    return dataset


def simulate(dataset, pct, odds_cap):
    results = []
    for threshold in DELTA_THRESHOLDS:
        bankroll = START_BANKROLL
        total_staked = 0.0
        max_stake = 0.0
        peak = START_BANKROLL
        max_drawdown = 0.0
        bets = wins = losses = 0

        for match in dataset:
            delta = match["delta"]
            if abs(delta) < threshold:
                continue

            predicted = "team1" if delta > 0 else "team2"
            odds = match["odds_team1"] if predicted == "team1" else match["odds_team2"]
            if odds >= odds_cap:
                continue

            stake = bankroll * pct
            if stake > MAX_BET:
                stake = MAX_BET
            if stake <= 0:
                continue

            bets += 1
            total_staked += stake
            max_stake = max(max_stake, stake)

            if match["winner"] == predicted:
                wins += 1
                bankroll += stake * (odds - 1)
            else:
                losses += 1
                bankroll -= stake

            peak = max(peak, bankroll)
            max_drawdown = max(max_drawdown, peak - bankroll)

        profit = bankroll - START_BANKROLL
        roi = (profit / total_staked) if total_staked else 0.0

        results.append({
            "strategy_group": f"Pct{int(pct*100)}",
            "hero_filter": "none",
            "odds_condition": f"<{odds_cap}",
            "metric": "WR_DELTA",
            "delta_threshold": threshold,
            "bets": int(round(bets)),
            "wins": int(round(wins)),
            "losses": int(round(losses)),
            "win_pct": round((wins / bets * 100) if bets else 0.0, 2),
            "final_bank": int(round(bankroll)),
            "profit": int(round(profit)),
            "total_staked": int(round(total_staked)),
            "roi": round(roi, 4),
            "max_drawdown": int(round(max_drawdown)),
            "max_stake": int(round(max_stake)),
        })
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cs", default="cs.json")
    parser.add_argument("--matches", default="hawk_matches_merged.csv")
    parser.add_argument("--pct-output", default="strategy_results_wr_pct_full.csv")
    parser.add_argument("--martingale-output", default="strategy_results_wr_martingale.csv")
    args = parser.parse_args()

    cs_data = load_cs_data(Path(args.cs))
    dataset = build_match_dataset(cs_data, Path(args.matches))

    # Percentage-based strategies
    pct_rows = []
    for pct in PERCENTS:
        for odds_cap in ODDS_CAPS:
            pct_rows.extend(simulate(dataset, pct, odds_cap))
    headers = [
        "strategy_group","hero_filter","odds_condition","metric","delta_threshold",
        "bets","wins","losses","win_pct","final_bank","profit",
        "total_staked","roi","max_drawdown","max_stake"
    ]
    with Path(args.pct_output).open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=headers)
        writer.writeheader()
        writer.writerows(pct_rows)

    # Prepare trade sequences for martingale simulation
    trade_map = defaultdict(list)
    for match in dataset:
        delta = match["delta"]
        if delta == 0:
            continue
        predicted = "team1" if delta > 0 else "team2"
        odds = match["odds_team1"] if predicted == "team1" else match["odds_team2"]
        result = (match["winner"] == predicted)
        abs_delta = abs(delta)
        for threshold in DELTA_THRESHOLDS:
            if abs_delta < threshold:
                continue
            for cap in ODDS_CAPS:
                if odds < cap:
                    trade_map[(cap, threshold)].append((result, odds))

    # Martingale analysis (double after loss)
    martingale_rows = []
    for cap in ODDS_CAPS:
        for thresh in DELTA_THRESHOLDS:
            trades = trade_map[(cap, thresh)]
            if not trades:
                martingale_rows.append({
                    "odds_cap": cap,
                    "delta_threshold": thresh,
                    "total_trades": 0,
                    "wins": 0,
                    "losses": 0,
                    "max_losing_streak": 0,
                    "base_bet": 0,
                    "final_bank": START_BANKROLL,
                    "bankrupt": 0,
                })
                continue

            current = 0
            max_streak = 0
            wins = losses = 0
            for result, _ in trades:
                if result:
                    wins += 1
                    current = 0
                else:
                    losses += 1
                    current += 1
                    max_streak = max(max_streak, current)

            required_bank = (2 ** (max_streak + 1) - 1) if max_streak >= 0 else 1
            base_bet = START_BANKROLL // required_bank if required_bank else START_BANKROLL
            if base_bet < 1:
                martingale_rows.append({
                    "odds_cap": cap,
                    "delta_threshold": thresh,
                    "total_trades": len(trades),
                    "wins": wins,
                    "losses": losses,
                    "max_losing_streak": max_streak,
                    "base_bet": 0,
                    "final_bank": START_BANKROLL,
                    "bankrupt": 1,
                })
                continue

            bank = START_BANKROLL
            streak = 0
            stake = base_bet
            bankrupt = 0
            for result, odds in trades:
                if stake > bank or stake <= 0:
                    bankrupt = 1
                    break
                if result:
                    bank += stake * (odds - 1)
                    streak = 0
                    stake = base_bet
                else:
                    bank -= stake
                    streak += 1
                    next_stake = base_bet * (2 ** streak)
                    stake = next_stake
                    if bank <= 0:
                        bank = 0
                        bankrupt = 1
                        break

            martingale_rows.append({
                "odds_cap": cap,
                "delta_threshold": thresh,
                "total_trades": len(trades),
                "wins": wins,
                "losses": losses,
                "max_losing_streak": max_streak,
                "base_bet": base_bet,
                "final_bank": max(bank, 0),
                "bankrupt": bankrupt,
            })

    mart_headers = [
        "odds_cap","delta_threshold","total_trades","wins","losses",
        "max_losing_streak","base_bet","final_bank","bankrupt"
    ]
    with Path(args.martingale_output).open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=mart_headers)
        writer.writeheader()
        writer.writerows(martingale_rows)


if __name__ == "__main__":
    main()
