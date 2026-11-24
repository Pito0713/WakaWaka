import * as path from 'path';
import { fileURLToPath } from 'url';
import { loadPricing } from './pricing.js';
import { bucketCost, unpricedIn } from './usage-rows.js';
import { calculateUsage } from './transcript-usage.js';
import { aggregateSessionUsage } from './aggregate-usage.js';

// The parsers live in their own modules; this file is the CLI the app runs
// and the import path existing callers and tests use.
export { bucketCost, type ModelBuckets, type UsageSnapshot } from './usage-rows.js';
export { calculateUsage, type UsageScan } from './transcript-usage.js';
export { aggregateSessionUsage, type CostedUsage } from './aggregate-usage.js';

// ── CLI entry point ───────────────────────────────────────────────────────────
async function main() {
  // --aggregate mode: scan all projects and sum up session usage
  if (process.argv[2] === '--aggregate') {
    const projectsDir = process.argv[3]
      ?? path.join(process.env.HOME ?? '', '.claude', 'projects');
    const result = await aggregateSessionUsage(projectsDir);
    process.stdout.write(JSON.stringify(result, null, 2) + '\n');
    return;
  }

  const transcriptPath = process.argv[2];
  if (!transcriptPath) {
    process.stderr.write('Usage: npx tsx parser/usage-calculator.ts <transcriptPath>\n       npx tsx parser/usage-calculator.ts --aggregate [projectsDir]\n');
    process.exit(1);
  }

  const pricing = loadPricing();
  if (pricing.claudeModels.size === 0) {
    process.stderr.write('pricing.json: claude.models is empty or malformed\n');
    process.exit(1);
  }

  const { byModel, ...usage } = await calculateUsage(transcriptPath);

  process.stdout.write(
    JSON.stringify({
      ...usage,
      estimatedCostUSD: bucketCost(byModel.cumulative, pricing) ?? 0,
      session5hCostUSD: bucketCost(byModel.session, pricing),
      turnCostUSD: bucketCost(byModel.turn, pricing),
      unpricedModels: unpricedIn([byModel.cumulative, byModel.session, byModel.turn], pricing),
      pricingAsOf: pricing.asOf,
    }, null, 2) + '\n',
  );
}

// Only run main when invoked directly (not when imported by tests)
const thisFile = fileURLToPath(import.meta.url);
const calledFile = path.resolve(process.argv[1] ?? '');
if (calledFile === thisFile || calledFile === thisFile.replace(/\.js$/, '.ts')) {
  main().catch((err) => {
    process.stderr.write(String(err) + '\n');
    process.exit(1);
  });
}
