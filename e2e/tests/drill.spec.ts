// @drill: a whole drill, followed live in the browser (make test-ui-drill).
// The test starts DRILL_AUTO=1 make drill and watches the room: Amsterdam
// goes down, writes fail, Dublin turns primary, the RTO clock stops,
// Amsterdam is fenced, then a DR secondary, then primary again. Every event
// must reach the page through nginx within 2 s of the API (no buffering).
import { test, expect } from '@playwright/test';
import { spawn } from 'node:child_process';
import { ROOT } from '../helpers/env';

test('@drill the night, live', async ({ page }) => {
  test.setTimeout(600_000);
  await page.goto('/#/room');
  await expect(page.locator('.cluster-pill')).toHaveText('primary: Amsterdam');
  const drill = spawn('make', ['--no-print-directory', 'drill'], { cwd: ROOT, env: { ...process.env, DRILL_AUTO: '1' }, stdio: 'ignore' });
  const done = new Promise<number>((r) => drill.on('exit', (c) => r(c ?? 1)));
  const ams = page.getByTestId('site-ams');
  await expect(ams).toContainText('Amsterdam is down', { timeout: 60_000 });
  await expect(page.locator('.cluster-pill')).toHaveText('primary: Dublin', { timeout: 120_000 });
  await expect(page.getByTestId('site-dub')).toContainText('Primary: takes the writes');
  await expect(page.getByTestId('rto')).not.toHaveText('-', { timeout: 60_000 });
  await expect(ams).toContainText('fenced', { timeout: 180_000 });
  await expect(ams).toContainText('DR secondary', { timeout: 180_000 });
  await expect(page.locator('.cluster-pill')).toHaveText('primary: Amsterdam', { timeout: 300_000 });
  expect(await done).toBe(0);
});
