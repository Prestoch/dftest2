const fs = require('fs');
const path = require('path');
const vm = require('vm');

const START_BANKROLL = 1000;
const MAX_BET = 10000;
const SUMMARY_FILE = path.join(__dirname, 'strategy_results_wr_combined.csv');
const LEAGUE_OUTPUT_DIR = path.join(__dirname, 'league_strategy_results');
const TARGET_LEAGUES = [
  'European Pro League 31',
  'CIS Battle 2',
  'Fissure Playground 2',
  'Dreamleague 27 Div 2 Stage 1',
  'The International 2025',
];

function loadCsData(csPath) {
  const code = fs.readFileSync(csPath, 'utf8');
  const sandbox = {};
  vm.createContext(sandbox);
  vm.runInContext(code, sandbox);
  return sandbox;
}

function normalizeName(name) {
  return name.replace(/\s+/g, ' ').trim().toLowerCase();
}

function parseCsv(content) {
  const lines = content.trim().split(/\r?\n/);
  const header = lines.shift().split(',');
  return lines.map(line => {
    const values = [];
    let current = '';
    let inQuotes = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === '"') {
        if (line[i + 1] === '"') {
          current += '"';
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch === ',' && !inQuotes) {
        values.push(current);
        current = '';
      } else {
        current += ch;
      }
    }
    values.push(current);
    const obj = {};
    header.forEach((key, idx) => {
      obj[key] = values[idx];
    });
    return obj;
  });
}

function toFloat(value) {
  if (value == null || value === '') return null;
  const num = parseFloat(value);
  return Number.isFinite(num) ? num : null;
}

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function fibGenerator() {
  const cache = [1, 1];
  return function (index) {
    while (cache.length <= index) {
      const len = cache.length;
      cache.push(cache[len - 1] + cache[len - 2]);
    }
    return cache[index];
  };
}

function computeHeroAdvantage(heroIdx, opponentIdxList, winRates) {
  let advantage = 0;
  for (const oppIdx of opponentIdxList) {
    const cell = winRates[oppIdx] && winRates[oppIdx][heroIdx];
    if (cell && cell[0] != null) {
      advantage += parseFloat(cell[0]) * -1;
    }
  }
  return advantage;
}

function buildMatchDataset(csData, matches) {
  const heroes = csData.heroes;
  const heroMap = new Map();
  heroes.forEach((name, idx) => heroMap.set(normalizeName(name), idx));

  const dataset = [];

  for (const row of matches) {
    const team1Heroes = (row.team1_heroes || '').split('|').map(h => h.trim()).filter(Boolean);
    const team2Heroes = (row.team2_heroes || '').split('|').map(h => h.trim()).filter(Boolean);
    if (team1Heroes.length !== 5 || team2Heroes.length !== 5) continue;

    const team1Idx = [];
    const team2Idx = [];
    let missingHero = false;

    for (const hero of team1Heroes) {
      const idx = heroMap.get(normalizeName(hero));
      if (idx == null) { missingHero = true; break; }
      team1Idx.push(idx);
    }
    if (missingHero) continue;

    for (const hero of team2Heroes) {
      const idx = heroMap.get(normalizeName(hero));
      if (idx == null) { missingHero = true; break; }
      team2Idx.push(idx);
    }
    if (missingHero) continue;

    const heroWr = csData.heroes_wr.map(Number);
    const winRates = csData.win_rates;

    const team1HeroAdv = [];
    const team2HeroAdv = [];
    let team1Score = 0;
    let team2Score = 0;

    for (const idx of team1Idx) {
      const adv = computeHeroAdvantage(idx, team2Idx, winRates);
      team1HeroAdv.push(adv);
      team1Score += heroWr[idx] + adv;
    }
    for (const idx of team2Idx) {
      const adv = computeHeroAdvantage(idx, team1Idx, winRates);
      team2HeroAdv.push(adv);
      team2Score += heroWr[idx] + adv;
    }

    const odds1 = toFloat(row.team1_odds);
    const odds2 = toFloat(row.team2_odds);
    const winnerName = row.winner && row.winner.trim();
    const winner = winnerName === row.team1 ? 'team1' : (winnerName === row.team2 ? 'team2' : null);
    const favorite = odds1 != null && odds2 != null ? (odds1 < odds2 ? 'team1' : (odds2 < odds1 ? 'team2' : null)) : null;
    const underdog = odds1 != null && odds2 != null ? (odds1 > odds2 ? 'team1' : (odds2 > odds1 ? 'team2' : null)) : null;

    dataset.push({
      league: row.championship,
      heroAdv: { team1: team1HeroAdv, team2: team2HeroAdv },
      metrics: { wr_delta: team1Score - team2Score },
      odds: { team1: odds1, team2: odds2 },
      winner,
      favorite,
      underdog,
    });
  }

  return dataset;
}

const WR_THRESHOLDS = [5,10,15,20,25,30,35,40,45,50,75,100,125,150,200,250,300,350,400];

const METRIC_CONFIG = [
  { key: 'wr_delta', label: 'WR_DELTA', thresholds: WR_THRESHOLDS },
];

function heroFilterCheck(match, predicted, requirement) {
  if (!requirement) return true;
  const other = predicted === 'team1' ? 'team2' : 'team1';
  const needed = requirement === '4+4' ? 4 : 5;
  const positiveCount = match.heroAdv[predicted].filter(v => v > 0).length;
  const negativeCount = match.heroAdv[other].filter(v => v < 0).length;
  return positiveCount >= needed && negativeCount >= needed;
}

function getStake(state, strategy) {
  let stake = 0;
  switch (strategy.type) {
    case 'flat':
      stake = strategy.amount;
      break;
    case 'flat_pct_initial':
      stake = strategy.initial * strategy.pct;
      break;
    case 'bankroll_pct':
      stake = state.bankroll * strategy.pct;
      break;
    case 'fibonacci':
      stake = strategy.unit * strategy.fib(state.fibIndex);
      break;
    default:
      stake = 0;
  }
  if (stake > MAX_BET) stake = MAX_BET;
  return stake;
}

function updateStakeState(state, strategy, isWin) {
  if (strategy.type !== 'fibonacci') return;
  if (isWin) {
    state.fibIndex = Math.max(state.fibIndex - 2, 0);
  } else {
    state.fibIndex += 1;
  }
}

function simulateThreshold(matches, metricKey, threshold, scenario) {
  const state = {
    bankroll: START_BANKROLL,
    fibIndex: 0,
    peak: START_BANKROLL,
    maxDrawdown: 0,
    totalStaked: 0,
    maxStake: 0,
  };
  const stats = { bets: 0, wins: 0, losses: 0 };
  const fibFn = scenario.strategy.type.startsWith('fibonacci') ? fibGenerator() : null;

  const strategyConfig = (() => {
    const type = scenario.strategy.type;
    if (type === 'flat') {
      return { type: 'flat', amount: scenario.strategy.amount };
    } else if (type === 'flat_pct_initial') {
      return { type: 'flat_pct_initial', pct: scenario.strategy.pct, initial: START_BANKROLL };
    } else if (type === 'bankroll_pct') {
      return { type: 'bankroll_pct', pct: scenario.strategy.pct };
    } else if (type === 'fibonacci') {
      return { type: 'fibonacci', unit: scenario.strategy.unit, fib: fibFn };
    }
    return { type: 'flat', amount: 0 };
  })();

  for (const match of matches) {
    if (!match.winner) continue;
    const metricValue = match.metrics[metricKey];
    if (metricValue == null || metricValue === 0) continue;
    const absValue = Math.abs(metricValue);
    if (absValue < threshold) continue;

    const predicted = metricValue > 0 ? 'team1' : 'team2';

    const odds = match.odds[predicted];
    if (odds == null) continue;

    if (scenario.filters.requireUnderdog && match.underdog !== predicted) continue;
    if (scenario.filters.requireFavorite && match.favorite !== predicted) continue;
    if (!heroFilterCheck(match, predicted, scenario.filters.heroRequirement)) continue;

    const stake = getStake(state, strategyConfig);
    if (stake <= 0) continue;

    stats.bets += 1;
    state.totalStaked += stake;
    if (stake > state.maxStake) state.maxStake = stake;

    const isWin = match.winner === predicted;
    if (isWin) {
      stats.wins += 1;
      const profit = stake * (odds - 1);
      state.bankroll += profit;
      updateStakeState(state, strategyConfig, true);
    } else {
      stats.losses += 1;
      state.bankroll -= stake;
      updateStakeState(state, strategyConfig, false);
    }

    if (state.bankroll > state.peak) {
      state.peak = state.bankroll;
    }
    const drawdown = state.peak - state.bankroll;
    if (drawdown > state.maxDrawdown) state.maxDrawdown = drawdown;

    // bankroll can go negative now; keep betting
  }

  const profit = state.bankroll - START_BANKROLL;
  const roi = state.totalStaked ? profit / state.totalStaked : 0;

  return {
    delta_threshold: threshold,
    bets: stats.bets,
    wins: stats.wins,
    losses: stats.losses,
    final_bank: state.bankroll,
    profit,
    total_staked: state.totalStaked,
    roi,
    max_stake: state.maxStake,
    max_drawdown: state.maxDrawdown,
  };
}

function runScenario(matches, scenario) {
  const rows = [];
  for (const metricSpec of METRIC_CONFIG) {
    for (const threshold of metricSpec.thresholds) {
      const result = simulateThreshold(matches, metricSpec.key, threshold, scenario);
      rows.push({
        strategy_group: scenario.meta.strategy_group,
        hero_filter: scenario.meta.hero_filter,
        odds_condition: scenario.meta.odds_condition,
        metric: metricSpec.label,
        delta_threshold: result.delta_threshold,
        bets: result.bets,
        wins: result.wins,
        losses: result.losses,
        final_bank: result.final_bank,
        profit: result.profit,
        total_staked: result.total_staked,
        roi: result.roi,
        max_stake: result.max_stake,
        max_drawdown: result.max_drawdown,
      });
    }
  }
  return rows;
}

function buildScenarios() {
  const baseFilters = [
    { suffix: 'all', filters: {} },
    { suffix: 'underdogs', filters: { requireUnderdog: true } },
    { suffix: 'favorites', filters: { requireFavorite: true } },
  ];

  function normalizeFilters(filters = {}) {
    return Object.assign({ requireUnderdog: false, requireFavorite: false, heroRequirement: null }, filters);
  }

  function heroFilterLabel(filters) {
    if (filters.heroRequirement === '4+4') return '4+4';
    if (filters.heroRequirement === '5+5') return '5+5';
    return 'none';
  }

  function oddsConditionLabel(filters) {
    if (filters.requireUnderdog) return 'underdog';
    if (filters.requireFavorite) return 'favorite';
    return 'any';
  }

  function scenario(id, strategyGroup, strategy, filters = {}) {
    const normalized = normalizeFilters(filters);
    return {
      id,
      strategy,
      filters: normalized,
      meta: {
        strategy_group: strategyGroup,
        hero_filter: heroFilterLabel(normalized),
        odds_condition: oddsConditionLabel(normalized),
      },
    };
  }

  const list = [];

  // 1-3 Flat $100 base
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 1).padStart(2, '0')}_flat100_${entry.suffix}`,
      'Flat100',
      { type: 'flat', amount: 100 },
      entry.filters
    ));
  });

  // 4-6 5% bankroll per bet
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 4).padStart(2, '0')}_pct5_${entry.suffix}`,
      'Bankroll5pct',
      { type: 'bankroll_pct', pct: 0.05 },
      entry.filters
    ));
  });

  // 7-9 Flat $100 with 4+4 hero filter
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 7).padStart(2, '0')}_flat100_4p_${entry.suffix}`,
      'Flat100',
      { type: 'flat', amount: 100 },
      Object.assign({}, entry.filters, { heroRequirement: '4+4' })
    ));
  });

  // 10-12 Flat 5% initial with 4+4
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 10).padStart(2, '0')}_flat5pct_4p_${entry.suffix}`,
      'Flat5PctInitial',
      { type: 'flat_pct_initial', pct: 0.05 },
      Object.assign({}, entry.filters, { heroRequirement: '4+4' })
    ));
  });

  // 13-15 Flat $100 with 5+5
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 13).padStart(2, '0')}_flat100_5p_${entry.suffix}`,
      'Flat100',
      { type: 'flat', amount: 100 },
      Object.assign({}, entry.filters, { heroRequirement: '5+5' })
    ));
  });

  // 16-18 Flat 5% initial with 5+5
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 16).padStart(2, '0')}_flat5pct_5p_${entry.suffix}`,
      'Flat5PctInitial',
      { type: 'flat_pct_initial', pct: 0.05 },
      Object.assign({}, entry.filters, { heroRequirement: '5+5' })
    ));
  });

  // Fibonacci $1 unit (19-27)
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 19).padStart(2, '0')}_fib1_${entry.suffix}`,
      'Fibonacci_$1',
      { type: 'fibonacci', unit: 1 },
      entry.filters
    ));
  });
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 22).padStart(2, '0')}_fib1_4p_${entry.suffix}`,
      'Fibonacci_$1',
      { type: 'fibonacci', unit: 1 },
      Object.assign({}, entry.filters, { heroRequirement: '4+4' })
    ));
  });
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 25).padStart(2, '0')}_fib1_5p_${entry.suffix}`,
      'Fibonacci_$1',
      { type: 'fibonacci', unit: 1 },
      Object.assign({}, entry.filters, { heroRequirement: '5+5' })
    ));
  });

  // Fibonacci $5 unit (28-36)
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 28).padStart(2, '0')}_fib5_${entry.suffix}`,
      'Fibonacci_$5',
      { type: 'fibonacci', unit: 5 },
      entry.filters
    ));
  });
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 31).padStart(2, '0')}_fib5_4p_${entry.suffix}`,
      'Fibonacci_$5',
      { type: 'fibonacci', unit: 5 },
      Object.assign({}, entry.filters, { heroRequirement: '4+4' })
    ));
  });
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(
      `scenario_${String(idx + 34).padStart(2, '0')}_fib5_5p_${entry.suffix}`,
      'Fibonacci_$5',
      { type: 'fibonacci', unit: 5 },
      Object.assign({}, entry.filters, { heroRequirement: '5+5' })
    ));
  });

  return list;
}

function formatRows(rows) {
  const roundIntStr = val => Math.round(val || 0).toString();
  const roundFixed = (val, digits) => {
    const factor = Math.pow(10, digits);
    return (Math.round((val || 0) * factor) / factor).toFixed(digits);
  };

  return rows.map(row => {
    const bets = row.bets || 0;
    const wins = row.wins || 0;
    const winPct = bets ? (wins / bets) * 100 : 0;
    return {
      strategy_group: row.strategy_group,
      hero_filter: row.hero_filter,
      odds_condition: row.odds_condition,
      metric: row.metric,
      delta_threshold: row.delta_threshold,
      bets: roundIntStr(bets),
      wins: roundIntStr(wins),
      losses: roundIntStr(row.losses || 0),
      win_pct: roundFixed(winPct, 2),
      final_bank: roundIntStr(row.final_bank),
      profit: roundIntStr(row.profit),
      total_staked: roundIntStr(row.total_staked),
      roi: roundFixed(row.roi || 0, 4),
      max_drawdown: roundIntStr(row.max_drawdown),
      max_stake: roundIntStr(row.max_stake),
    };
  });
}

function writeSummaryCsv(rows, outputPath) {
  const header = [
    'strategy_group',
    'hero_filter',
    'odds_condition',
    'metric',
    'delta_threshold',
    'bets',
    'wins',
    'losses',
    'win_pct',
    'final_bank',
    'profit',
    'total_staked',
    'roi',
    'max_drawdown',
    'max_stake',
  ];
  const formatted = formatRows(rows);
  const lines = [header.join(',')];
  formatted.forEach(row => {
    lines.push(header.map(key => row[key]).join(','));
  });
  fs.writeFileSync(outputPath, lines.join('\n'), 'utf8');
}

function slugify(name) {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
}

function runSuite(matches, scenarios, outputPath) {
  const allRows = [];
  for (const scenario of scenarios) {
    console.log(`Running ${scenario.id}`);
    const rows = runScenario(matches, scenario);
    allRows.push(...rows);
  }
  writeSummaryCsv(allRows, outputPath);
}

function main() {
  const csData = loadCsData(path.join(__dirname, 'cs.json'));
  const matches = parseCsv(fs.readFileSync(path.join(__dirname, 'hawk_matches_merged.csv'), 'utf8'));
  const dataset = buildMatchDataset(csData, matches);
  const scenarios = buildScenarios();

  console.log(`Total matches usable: ${dataset.length}`);
  runSuite(dataset, scenarios, SUMMARY_FILE);

  TARGET_LEAGUES.forEach(leagueName => {
    const leagueMatches = dataset.filter(match => match.league === leagueName);
    const slug = slugify(leagueName);
    const leagueDir = path.join(LEAGUE_OUTPUT_DIR, slug);
    ensureDir(leagueDir);
    console.log(`Running league suite for ${leagueName} (${leagueMatches.length} matches)`);
    runSuite(leagueMatches, scenarios, path.join(leagueDir, 'wr.csv'));
  });
}

main();
