// The two-primaries state, from a recorded snapshot (the real drill never
// reaches it: the fence prevents it). The API's event stream is replaced by
// a fixture for this test only.
import { test, expect } from '@playwright/test';

const site = (id: string, role: string) => ({ site: id, state: 'up', stale: false, read_at: new Date().toISOString(), data: { site: id, role, nodes: [{ node: `vault-${id}-1`, ha_state: 'active', health_code: 200, said: { code: 200 } }], wal: {}, vault_said: { replication: { dr: { mode: 'primary' }, performance: { mode: 'primary' } } } } });
const snapshot = { sites: [site('ams', 'primary'), site('fra', 'performance secondary'), site('dub', 'primary')], split_brain: true, frontdoor: { state: 'up', data: { backends: [] } }, ticker: { state: 'up', data: { spark: [] } }, drill: { open: null } };

test('two primaries: the room says so in red, with both names', async ({ page }) => {
  await page.route('**/api/events', (r) => r.fulfill({ status: 200, headers: { 'content-type': 'text/event-stream' }, body: `event: snapshot\ndata: ${JSON.stringify(snapshot)}\n\n` }));
  await page.goto('/#/room');
  const alert = page.getByTestId('split-brain');
  await expect(alert).toBeVisible();
  await expect(alert).toContainText('Amsterdam and Dublin both say they are primary');
  await expect(page.locator('.cluster-pill')).toHaveText('two primaries');
});
