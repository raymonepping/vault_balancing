// The drill buttons (prompt 12, D16): who may press them, decided by Keycloak
// from the OpenLDAP groups; the API and the runner verify the token themselves.
import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { signIn } from '../helpers/auth';

// A POST from inside the page: the browser's cookie, its Sec-Fetch-Site and
// its trust in the lab CA (Node's request context has none of them).
const postFromPage = (page: import('@playwright/test').Page, path: string, body: object) =>
  page.evaluate(async ([p, b]) => {
    const r = await fetch(p as string, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b) });
    return { status: r.status, json: await r.json().catch(() => ({})) };
  }, [path, body] as const);

const TAGS = ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'];

test('signed out: the next step shows, the button is off, sign-in is offered', async ({ page }) => {
  await page.goto('/#/room');
  await expect(page.getByRole('heading', { name: /Next step, Act I/ })).toBeVisible();
  await expect(page.getByRole('button', { name: /goes dark/ })).toBeDisabled();
  await expect(page.getByTestId('action-reason')).toContainText('Sign in as an operator');
  const r = await postFromPage(page, '/api/actions/site-down', { confirm: 'ams' });
  expect(r.status).toBe(401);
});

test('a viewer (vera) sees why she cannot press it, and the API refuses her', async ({ page }) => {
  await signIn(page, 'vera');
  await expect(page.getByTestId('action-reason')).toContainText('you are a viewer');
  await expect(page.getByRole('button', { name: /goes dark/ })).toBeDisabled();
  const r = await postFromPage(page, '/api/actions/site-down', { confirm: 'ams' });
  expect(r.status).toBe(403);
  expect(r.json.error.message).toContain('vera is a viewer');
});

test('sign-out is a POST: the menu button signs out, a GET does not', async ({ page }) => {
  await signIn(page, 'vera');
  // A GET (what an image tag on another page would send) is refused; still signed in.
  expect(await page.evaluate(async () => (await fetch('/auth/logout', { redirect: 'manual' })).status)).toBe(405);
  await page.reload();
  await expect(page.locator('.persona')).toBeVisible();
  await page.locator('.persona').click();
  await page.getByRole('button', { name: 'Sign out' }).click();
  await page.waitForURL(/localhost:\d+\/(#.*)?$/);
  await expect(page.getByRole('link', { name: 'Sign in', exact: true })).toBeVisible();
});

test('an operator (oscar) may press it, after typing the site', async ({ page }) => {
  await signIn(page, 'oscar');
  await page.locator('.persona').click();
  await expect(page.getByRole('dialog', { name: 'Signed in' })).toContainText('Operator: runs the drill');
  await page.keyboard.press('Escape');
  const button = page.getByRole('button', { name: /goes dark/ });
  await expect(button).toBeDisabled();
  await page.getByLabel('Type ams to confirm').fill('ams');
  await expect(button).toBeEnabled();
  const r = await new AxeBuilder({ page }).withTags(TAGS).analyze();
  expect(r.violations.map((v) => v.id)).toEqual([]);
});

// @drill-clicks: the whole night, pressed by the operator in the browser.
test('@drill-clicks an operator runs the whole drill from the console', async ({ page }) => {
  test.setTimeout(900_000);
  await signIn(page, 'oscar');
  const order = ['goes dark', 'Promote Dublin', 'Point Frankfurt', 'Fence Amsterdam', 'Bring Amsterdam back', 'Demote Amsterdam', 'Unfence Amsterdam', 'Fail back', 'Write the report'];
  for (const label of order) {
    const button = page.getByRole('button', { name: new RegExp(label) });
    await expect(button).toBeVisible({ timeout: 120_000 });
    if (label === 'goes dark') await page.getByLabel('Type ams to confirm').fill('ams');
    await expect(button).toBeEnabled({ timeout: 120_000 });
    await button.click();
    // The run shows, then finishes (exit 0), started by oscar.
    await expect(page.locator('.action-run__head')).toContainText('started by oscar', { timeout: 30_000 });
    await expect(page.locator('.action-run__head')).toContainText('finished', { timeout: 480_000 });
  }
  await expect(page.getByRole('heading', { name: /Next step, Act I/ })).toBeVisible({ timeout: 60_000 });
});
