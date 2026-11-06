// Optional browser regression against the actual tutorial Load/Call controls.
// Requires Playwright and CHROME_PATH. ACTOR_URL defaults to public N5.
// NATIVE_WS_URL redirects only the UI's actor socket to a disposable candidate.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {chromium} = require('playwright');

(async () => {
  const origin = process.env.ACTOR_URL || 'https://n5.elfenbenstornet.se';
  const candidate = process.env.NATIVE_WS_URL || '';
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH, headless: true,
    args: candidate ? ['--disable-features=LocalNetworkAccessChecks'] : []
  });
  const report = {origin, candidate, rounds: []};
  let page;
  try {
    page = await browser.newPage();
    page.setDefaultTimeout(15000);
    if (candidate) await page.addInitScript(({origin, candidate}) => {
      const Native = window.WebSocket;
      const actorSocket = origin.replace(/^http/, 'ws') + '/ws';
      window.WebSocket = class extends Native {
        constructor(url, protocols) {
          super(String(url).startsWith(actorSocket) ? candidate : url, protocols);
        }
      };
    }, {origin, candidate});
    await page.goto(origin + '/demonstrator');
    await page.getByRole('button', {name: 'Dismiss', exact: true}).click();
    await page.evaluate(() => vm.openTutorialDocument('/actor-profile-tutorial'));
    const frame = page.frameLocator('iframe[src="/actor-profile-tutorial"]');
    await frame.locator('[onclick=\'consult("#cpw-remote-pingpong-source")\']').click();
    await page.waitForFunction(() => vm.wsPid && !vm.wsSpawnPromise && !vm.terminalBusy);
    async function query(goal) {
      await page.evaluate(goal => { vm.terminal.exec(goal); }, goal);
      await page.waitForTimeout(100);
      await page.waitForFunction(() => !vm.terminalBusy);
      return page.evaluate(() => ({bindings: {...vm.lastBindings}, output: vm.terminal.get_output()}));
    }
    const before = await query('actors(PingBaseline).');
    assert.ok(before.bindings.PingBaseline, before.output);
    report.baseline = before.bindings.PingBaseline;
    for (let round = 1; round <= 2; round++) {
      const prefix = await page.evaluate(() => vm.terminal.get_output());
      const result = await query('ping_pong_remote.');
      const output = result.output.slice(prefix.length);
      assert.equal((output.match(/Ping received pong\./g) || []).length, 3, output);
      assert.equal((output.match(/Pong received ping\./g) || []).length, 3, output);
      assert.ok(output.includes('Ping finished.') && output.includes('Pong finished.'), output);
      const after = await query('actors(PingAfter).');
      assert.equal(after.bindings.PingAfter, report.baseline,
        'Public actor list changed after ping-pong: ' + after.bindings.PingAfter);
      report.rounds.push({round, status: 'pass', actors: after.bindings.PingAfter});
    }
    const fresh = await query('AfterPing = ready.');
    assert.equal(fresh.bindings.AfterPing, 'ready');
    report.fresh_query = true;
    report.status = 'pass';
    console.log('Tutorial ping-pong restores the actor baseline, including connection reuse: pass');
  } catch (error) {
    report.status = 'fail'; report.error = String(error);
    if (page) report.diagnostics = await page.evaluate(() => ({
      output: vm.terminal.get_output(), logs: vm.logEntries.slice(0, 12)
    })).catch(() => null);
    throw error;
  } finally {
    await browser.close();
    if (process.env.PING_REPORT) fs.writeFileSync(process.env.PING_REPORT, JSON.stringify(report, null, 2) + '\n');
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
