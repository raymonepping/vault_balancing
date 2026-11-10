// The report page of the latest closed drill: its sentence and numbers match
// report.json exactly (never typed by hand).
import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { ROOT } from '../helpers/env';

test('the report shows the latest report.json', async ({ page }) => {
  const dir = path.join(ROOT, '.build/drill');
  const latest = fs.readdirSync(dir).filter((d) => d.startsWith('drill-') && fs.existsSync(path.join(dir, d, 'report.json'))).sort().pop();
  test.skip(!latest, 'no closed drill yet: make drill');
  const r = JSON.parse(fs.readFileSync(path.join(dir, latest!, 'report.json'), 'utf8'));
  await page.goto('/#/report');
  await expect(page.getByTestId('sentence')).toHaveText(r.sentence);
  await expect(page.getByRole('heading', { name: `RTO: ${r.rto.total_s} s, as clients saw it` })).toBeVisible();
  await expect(page.getByRole('heading', { name: `RPO: ${r.rpo.lost_writes} of ${r.rpo.checked} writes lost` })).toBeVisible();
});
