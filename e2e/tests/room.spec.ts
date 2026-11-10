// Act 0: three sites with the roles Vault reports, the front door, and the
// ticker strip moving. Then the "Vault said" drawer and the keyboard.
import { test, expect } from '@playwright/test';

test('a normal day: three sites, their roles, one write server, the ticker moving', async ({ page }) => {
  await page.goto('/#/room');
  await expect(page.locator('.cluster-pill')).toHaveText('primary: Amsterdam');
  await expect(page.getByTestId('site-ams')).toContainText('Primary: takes the writes');
  await expect(page.getByTestId('site-fra')).toContainText('Performance secondary: serves reads');
  await expect(page.getByTestId('site-dub')).toContainText('DR secondary: waits');
  await expect(page.getByTestId('backend-primary').locator('.server--up')).toHaveCount(1);
  await expect(page.getByTestId('backend-regional').locator('.server--up')).toHaveCount(3);
  const first = Number(await page.getByTestId('acked').textContent());
  expect(first).toBeGreaterThan(30);
  await expect(page.getByTestId('failed')).toHaveText('0');
  await expect(page.getByTestId('split-brain')).toHaveCount(0);
});

test('"Vault said" shows each site raw answer; arrow keys move between pages', async ({ page }) => {
  await page.goto('/#/room');
  await expect(page.locator('.cluster-pill')).toHaveText('primary: Amsterdam');
  await page.getByRole('button', { name: 'Vault said' }).click();
  const drawer = page.getByRole('dialog', { name: 'Vault said' });
  await expect(drawer).toContainText('"mode": "primary"');
  await expect(drawer).not.toContainText(/hv[sb]\./);
  await page.keyboard.press('Escape');
  await page.keyboard.press('ArrowRight');
  await expect(page).toHaveURL(/#\/replication$/);
  await expect(page.locator('.vg-hero')).toContainText('Amsterdam is primary');
});
