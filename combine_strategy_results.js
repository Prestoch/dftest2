const fs = require('fs');
const path = require('path');

const INPUT_DIR = path.join(__dirname, 'strategy_results');
const OUTPUT_FILE = path.join(__dirname, 'strategy_results_combined.csv');

function parseScenarioMeta(fileName) {
  const name = path.basename(fileName, '.csv');
  const parts = name.split('_').slice(2); // drop "scenario" and number
  const meta = {
    strategy_group: '',
    hero_filter: 'none',
    odds_condition: 'any',
  };

  if (!parts.length) return meta;
  const strategyToken = parts[0];
  switch (strategyToken) {
    case 'flat100':
      meta.strategy_group = 'Flat100';
      break;
    case 'pct5':
      meta.strategy_group = 'Bankroll5pct';
      break;
    case 'flat5pct':
      meta.strategy_group = 'Flat5PctInitial';
      break;
    case 'fib1':
      meta.strategy_group = 'Fibonacci_$1';
      break;
    case 'fib5':
      meta.strategy_group = 'Fibonacci_$5';
      break;
    default:
      meta.strategy_group = strategyToken;
  }

  const remaining = parts.slice(1);
  for (const token of remaining) {
    if (token === '4p') meta.hero_filter = '4+4';
    else if (token === '5p') meta.hero_filter = '5+5';
    else if (token === 'all') meta.odds_condition = 'any';
    else if (token === 'underdogs') meta.odds_condition = 'underdog';
    else if (token === 'favorites') meta.odds_condition = 'favorite';
  }

  return meta;
}

function parseCsv(content) {
  const lines = content.trim().split(/\r?\n/);
  const header = lines.shift().split(',');
  return lines.map(line => {
    const values = line.split(',');
    const row = {};
    header.forEach((key, idx) => {
      row[key] = values[idx];
    });
    return row;
  });
}

function readScenarioFile(filePath, meta) {
  const rows = parseCsv(fs.readFileSync(filePath, 'utf8'));
  return rows.map(row => {
    const bets = Number(row.bets || 0);
    const wins = Number(row.wins || 0);
    const winPct = bets ? (wins / bets * 100) : 0;
    return {
      strategy_group: meta.strategy_group,
      hero_filter: meta.hero_filter,
      odds_condition: meta.odds_condition,
      metric: row.metric,
      delta_threshold: Number(row.threshold || 0),
      bets,
      wins,
      losses: Number(row.losses || 0),
      win_pct: winPct.toFixed(2),
      final_bank: Number(row.final_bankroll || 0).toFixed(2),
      profit: Number(row.profit || 0).toFixed(2),
      total_staked: Number(row.total_staked || 0).toFixed(2),
      roi: Number(row.roi || 0).toFixed(4),
      max_drawdown: Number(row.max_drawdown || 0).toFixed(2),
      max_stake: Number(row.max_stake || 0).toFixed(2),
    };
  });
}

function main() {
  if (!fs.existsSync(INPUT_DIR)) {
    console.error('strategy_results directory not found');
    process.exit(1);
  }

  const files = fs.readdirSync(INPUT_DIR)
    .filter(f => f.endsWith('.csv'))
    .sort();

  const combined = [];
  for (const file of files) {
    const meta = parseScenarioMeta(file);
    const rows = readScenarioFile(path.join(INPUT_DIR, file), meta);
    combined.push(...rows);
  }

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
    'max_stake'
  ];

  const lines = [header.join(',')];
  combined.forEach(row => {
    const line = header.map(key => row[key]).join(',');
    lines.push(line);
  });

  fs.writeFileSync(OUTPUT_FILE, lines.join('\n'), 'utf8');
  console.log(`Wrote ${combined.length} rows to ${OUTPUT_FILE}`);
}

main();
