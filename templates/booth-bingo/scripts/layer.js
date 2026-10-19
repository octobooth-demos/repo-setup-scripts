// Switch the local checkout to a layer of the stack: npm run layer -- <0-3>
// Branch names match the booth-bingo "stack" entries in repo-setup-scripts/config.json.
import { execFileSync } from 'node:child_process';

const LAYERS = [
  ['main', 'Base card'],
  ['bingo/1-game-logic', 'Game logic'],
  ['bingo/2-wire-ui', 'Wire up the UI'],
  ['bingo/3-celebration', 'Celebration'],
];

const git = (...args) => execFileSync('git', args, { encoding: 'utf8' }).trim();
const n = Number(process.argv[2]);

if (process.argv[2] === undefined || !Number.isInteger(n) || n < 0 || n >= LAYERS.length) {
  console.error('Usage: npm run layer -- <0-3>\n');
  LAYERS.forEach(([branch, label], i) => console.error(`  ${i}  ${label.padEnd(16)} ${branch}`));
  process.exit(1);
}

if (git('status', '--porcelain')) {
  console.error('You have uncommitted changes. Commit or stash them before switching layers.');
  process.exit(1);
}

git('fetch', '--quiet', '--prune', 'origin');
let [branch, label] = LAYERS[n];
try {
  git('rev-parse', '--verify', '--quiet', `refs/remotes/origin/${branch}`);
} catch {
  console.log(`${branch} is gone from GitHub (probably merged), so showing main instead.`);
  [branch, label] = LAYERS[0];
}

git('checkout', '--quiet', branch);
// Follow GitHub, including after "Rebase stack" rewrites the branch.
git('reset', '--quiet', '--hard', `origin/${branch}`);
console.log(`Now showing ${label} (${branch}). Reload the browser tab.`);
