// @shots: refresh docs/screenshots (make screenshots). Not part of make test-ui.
import { test, expect } from '@playwright/test';
import path from 'node:path';
import { ROOT } from '../helpers/env';

const OUT = path.join(ROOT, 'docs/screenshots');
test.use({ bypassCSP: true });

for (const id of ['room', 'replication', 'timeline', 'report', 'layers']) {
  test(`@shots ${id}`, async ({ page }) => {
    for (const vp of [{ n: '', width: 1440, height: 900 }, { n: '-phone', width: 390, height: 844 }]) {
      await page.setViewportSize({ width: vp.width, height: vp.height });
      await page.goto(`/#/${id}`);
      await expect(page.locator('.cluster-pill')).not.toHaveText('connecting…');
      await page.waitForTimeout(1500);
      await page.addStyleTag({ content: '.topbar-wrap{position:static!important}.vg-sidebar{position:static!important;height:auto!important;min-height:100%!important}.skip-link{display:none!important}' });
      await page.screenshot({ path: path.join(OUT, `${id}${vp.n}.png`), fullPage: true });
    }
  });
}
