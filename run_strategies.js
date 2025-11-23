const fs = require('fs');
const path = require('path');
const vm = require('vm');

const START_BANKROLL = 1000;
const MAX_BET = 10000;

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
  function parseLine(line) {
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
  }
  return lines.map(parseLine);
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

function aggregateMetric(heroIdxList, values, aggregate, multiplier = 1) {
  let collected = [];
  for (const idx of heroIdxList) {
    const val = values[idx];
    if (val != null) collected.push(Number(val));
  }
  if (!collected.length) return 0;
  const sum = collected.reduce((acc, v) => acc + v, 0);
  const result = aggregate === 'avg' ? sum / collected.length : sum;
  return result * multiplier;
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

  const metricArrays = {
    gpm: csData.heroes_gpm,
    xpm: csData.heroes_xpm,
    hero_damage: csData.heroes_hero_damage,
    tower_damage: csData.heroes_tower_damage,
    damage_taken: csData.heroes_damage_taken,
    match_duration: csData.heroes_match_duration,
    teamfight: csData.heroes_teamfight_participation,
  };

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

    const gpmDelta = aggregateMetric(team1Idx, metricArrays.gpm, 'sum') - aggregateMetric(team2Idx, metricArrays.gpm, 'sum');
    const xpmDelta = aggregateMetric(team1Idx, metricArrays.xpm, 'sum') - aggregateMetric(team2Idx, metricArrays.xpm, 'sum');
    const heroDamageDelta = aggregateMetric(team1Idx, metricArrays.hero_damage, 'sum') - aggregateMetric(team2Idx, metricArrays.hero_damage, 'sum');
    const towerDamageDelta = aggregateMetric(team1Idx, metricArrays.tower_damage, 'sum') - aggregateMetric(team2Idx, metricArrays.tower_damage, 'sum');
    const damageTakenDelta = aggregateMetric(team1Idx, metricArrays.damage_taken, 'sum') - aggregateMetric(team2Idx, metricArrays.damage_taken, 'sum');
    const matchDurationDelta = aggregateMetric(team1Idx, metricArrays.match_duration, 'avg') - aggregateMetric(team2Idx, metricArrays.match_duration, 'avg');
    const teamfightDelta = aggregateMetric(team1Idx, metricArrays.teamfight, 'avg', 100) - aggregateMetric(team2Idx, metricArrays.teamfight, 'avg', 100);

    const odds1 = toFloat(row.team1_odds);
    const odds2 = toFloat(row.team2_odds);
    const winnerName = row.winner && row.winner.trim();
    const winner = winnerName === row.team1 ? 'team1' : (winnerName === row.team2 ? 'team2' : null);

    const favorite = odds1 != null && odds2 != null ? (odds1 < odds2 ? 'team1' : (odds2 < odds1 ? 'team2' : null)) : null;
    const underdog = odds1 != null && odds2 != null ? (odds1 > odds2 ? 'team1' : (odds2 > odds1 ? 'team2' : null)) : null;

    dataset.push({
      teams: { team1: row.team1, team2: row.team2 },
      heroes: { team1: team1Heroes, team2: team2Heroes },
      heroIdx: { team1: team1Idx, team2: team2Idx },
      heroAdv: { team1: team1HeroAdv, team2: team2HeroAdv },
      scores: { team1: team1Score, team2: team2Score },
      metrics: {
        wr_delta: team1Score - team2Score,
        gpm_delta: gpmDelta,
        xpm_delta: xpmDelta,
        hero_damage_delta: heroDamageDelta,
        tower_damage_delta: towerDamageDelta,
        damage_taken_delta: damageTakenDelta,
        duration_delta: matchDurationDelta,
        team_participation_delta: teamfightDelta,
      },
      odds: { team1: odds1, team2: odds2 },
      winner,
      favorite,
      underdog,
    });
  }

  return dataset;
}

const BASE_THRESHOLDS = [5,10,15,20,25,30,35,40,45,50,75,100,125,150,200,250,300,350,400];
const GPM_THRESHOLDS = [200,400,600,800,1000,1200];
const XPM_THRESHOLDS = GPM_THRESHOLDS;
const HERO_DAMAGE_THRESHOLDS = [5000,10000,15000,20000,25000];
const TOWER_THRESHOLDS = HERO_DAMAGE_THRESHOLDS;
const DAMAGE_TAKEN_THRESHOLDS = [10000,20000,30000,40000,50000];
const TEAM_PART_THRESHOLDS = [5,10,15,20,25];

const METRIC_CONFIG = [
  { key: 'wr_delta', label: 'WR_DELTA', thresholds: BASE_THRESHOLDS },
  { key: 'gpm_delta', label: 'GPM', thresholds: GPM_THRESHOLDS },
  { key: 'xpm_delta', label: 'XPM', thresholds: XPM_THRESHOLDS },
  { key: 'hero_damage_delta', label: 'HERO_DAMAGE', thresholds: HERO_DAMAGE_THRESHOLDS },
  { key: 'tower_damage_delta', label: 'TOWER_DAMAGE', thresholds: TOWER_THRESHOLDS },
  { key: 'damage_taken_delta', label: 'DAMAGE_TAKEN', thresholds: DAMAGE_TAKEN_THRESHOLDS },
  { key: 'team_participation_delta', label: 'TEAM_PARTICIPATION', thresholds: TEAM_PART_THRESHOLDS },
];

function heroFilterCheck(match, predicted, requirement) {
  if (!requirement) return true;
  const other = predicted === 'team1' ? 'team2' : 'team1';
  const needed = requirement === '4+4' ? 4 : 5;
  const predictedAdv = match.heroAdv[predicted];
  const otherAdv = match.heroAdv[other];
  const positiveCount = predictedAdv.filter(v => v > 0).length;
  const negativeCount = otherAdv.filter(v => v < 0).length;
  return positiveCount >= needed && negativeCount >= needed;
}

function getStake(state, strategy, odds) {
  if (state.bankroll <= 0) return 0;
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
  if (stake > state.bankroll) stake = state.bankroll;
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
  const stats = { bets: 0, wins: 0, losses: 0, pushes: 0 };
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
    const opponent = predicted === 'team1' ? 'team2' : 'team1';

    const odds = match.odds[predicted];
    const oppOdds = match.odds[opponent];
    if (odds == null || oppOdds == null) continue;

    if (scenario.filters.requireUnderdog && match.underdog !== predicted) continue;
    if (scenario.filters.requireFavorite && match.favorite !== predicted) continue;
    if (!heroFilterCheck(match, predicted, scenario.filters.heroRequirement)) continue;

    const stake = getStake(state, strategyConfig, odds);
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
      if (state.bankroll < 0) state.bankroll = 0;
      updateStakeState(state, strategyConfig, false);
    }

    if (state.bankroll > state.peak) {
      state.peak = state.bankroll;
    }
    const drawdown = state.peak - state.bankroll;
    if (drawdown > state.maxDrawdown) state.maxDrawdown = drawdown;

    if (state.bankroll <= 0) break;
  }

  const profit = state.bankroll - START_BANKROLL;
  const roi = stats.bets ? profit / state.totalStaked : 0;

  return {
    metric: metricKey,
    threshold,
    bets: stats.bets,
    wins: stats.wins,
    losses: stats.losses,
    final_bankroll: state.bankroll.toFixed(2),
    profit: profit.toFixed(2),
    total_staked: state.totalStaked.toFixed(2),
    roi: roi.toFixed(4),
    max_stake: state.maxStake.toFixed(2),
    max_drawdown: state.maxDrawdown.toFixed(2),
  };
}

function runScenario(matches, scenario, outputDir) {
  const rows = [];
  for (const metricSpec of METRIC_CONFIG) {
    for (const threshold of metricSpec.thresholds) {
      const result = simulateThreshold(matches, metricSpec.key, threshold, scenario);
      result.metric = metricSpec.label;
      rows.push(result);
    }
  }

  const headers = Object.keys(rows[0] || { metric: '', threshold: '', bets: '', wins: '', losses: '', final_bankroll: '', profit: '', total_staked: '', roi: '', max_stake: '', max_drawdown: '' });
  const csvLines = [headers.join(',')];
  for (const row of rows) {
    csvLines.push(headers.map(h => row[h]).join(','));
  }
  const fileName = `${scenario.id}.csv`;
  fs.writeFileSync(path.join(outputDir, fileName), csvLines.join('\n'), 'utf8');
}

function buildScenarios() {
  function scenario(id, strategy, filters = {}) {
    return { id, strategy, filters: Object.assign({ requireUnderdog: false, requireFavorite: false, heroRequirement: null }, filters) };
  }

  const list = [];

  const baseFilters = [
    { suffix: 'all', filters: {} },
    { suffix: 'underdogs', filters: { requireUnderdog: true } },
    { suffix: 'favorites', filters: { requireFavorite: true } },
  ];

  const heroFilters = [
    { tag: '4p_vs_4n', requirement: '4+4' },
    { tag: '5p_vs_5n', requirement: '5+5' },
  ];

  // 1-3 Flat $100 base
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 1).padStart(2, '0')}_flat100_${entry.suffix}`, { type: 'flat', amount: 100 }, entry.filters));
  });

  // 4-6 5% bankroll per bet
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 4).padStart(2, '0')}_pct5_${entry.suffix}`, { type: 'bankroll_pct', pct: 0.05 }, entry.filters));
  });

  // 7-9 Flat $100 with 4+4 hero filter
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 7).padStart(2, '0')}_flat100_4p_${entry.suffix}`, { type: 'flat', amount: 100 }, Object.assign({}, entry.filters, { heroRequirement: '4+4' })));
  });

  // 10-12 Flat 5% initial (i.e., $50) with 4+4
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 10).padStart(2, '0')}_flat5pct_4p_${entry.suffix}`, { type: 'flat_pct_initial', pct: 0.05 }, Object.assign({}, entry.filters, { heroRequirement: '4+4' })));
  });

  // 13-15 Flat $100 with 5+5
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 13).padStart(2, '0')}_flat100_5p_${entry.suffix}`, { type: 'flat', amount: 100 }, Object.assign({}, entry.filters, { heroRequirement: '5+5' })));
  });

  // 16-18 Flat 5% initial with 5+5
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 16).padStart(2, '0')}_flat5pct_5p_${entry.suffix}`, { type: 'flat_pct_initial', pct: 0.05 }, Object.assign({}, entry.filters, { heroRequirement: '5+5' })));
  });

  // Fibonacci 1$ unit scenarios (19-27)
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 19).padStart(2, '0')}_fib1_${entry.suffix}`, { type: 'fibonacci', unit: 1 }, entry.filters));
  });

  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 22).padStart(2, '0')}_fib1_4p_${entry.suffix}`, { type: 'fibonacci', unit: 1 }, Object.assign({}, entry.filters, { heroRequirement: '4+4' })));
  });

  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 25).padStart(2, '0')}_fib1_5p_${entry.suffix}`, { type: 'fibonacci', unit: 1 }, Object.assign({}, entry.filters, { heroRequirement: '5+5' })));
  });

  // Fibonacci $5 unit (28-36)
  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 28).padStart(2, '0')}_fib5_${entry.suffix}`, { type: 'fibonacci', unit: 5 }, entry.filters));
  });

  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 31).padStart(2, '0')}_fib5_4p_${entry.suffix}`, { type: 'fibonacci', unit: 5 }, Object.assign({}, entry.filters, { heroRequirement: '4+4' })));
  });

  baseFilters.forEach((entry, idx) => {
    list.push(scenario(`scenario_${String(idx + 34).padStart(2, '0')}_fib5_5p_${entry.suffix}`, { type: 'fibonacci', unit: 5 }, Object.assign({}, entry.filters, { heroRequirement: '5+5' })));
  });

  return list;
}

function main() {
  const csData = loadCsData(path.join(__dirname, 'cs.json'));
  const matches = parseCsv(fs.readFileSync(path.join(__dirname, 'hawk_matches_merged.csv'), 'utf8'));
  const dataset = buildMatchDataset(csData, matches);
  const scenarios = buildScenarios();
  const outputDir = path.join(__dirname, 'strategy_results');
  ensureDir(outputDir);
  console.log(`Total matches usable: ${dataset.length}`);
  for (const scenario of scenarios) {
    console.log(`Running ${scenario.id}`);
    runScenario(dataset, scenario, outputDir);
  }
}

main();
