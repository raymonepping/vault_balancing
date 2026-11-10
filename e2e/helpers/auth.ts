// helpers/auth.ts: sign in through Keycloak's own login page (realm balancing,
// federated from OpenLDAP). Passwords come from the files make identity-up
// generated; never logged.
import fs from 'node:fs';
import path from 'node:path';
import { expect, type Page } from '@playwright/test';
import { ROOT } from './env';

export const password = (user: string): string => fs.readFileSync(path.join(ROOT, '.secrets/identity/users', user), 'utf8').trim();

export async function signIn(page: Page, user: string): Promise<void> {
  await page.goto('/#/room');
  await page.getByRole('link', { name: 'Sign in', exact: true }).click();
  await page.locator('#username').fill(user);
  await page.locator('#password').fill(password(user));
  await page.locator('#kc-login').click();
  await expect(page.locator('.persona')).toBeVisible();
}
