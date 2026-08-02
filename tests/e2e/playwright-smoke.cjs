#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const ARTIFACT_ROOT = path.resolve(__dirname, 'artifacts');

/**
 * 環境変数から必須値を取得する。
 *
 * @param {string} name - 取得する環境変数名。
 * @returns {string} 環境変数の値。
 * @throws {Error} 値が未設定の場合に送出する。
 */
function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`required environment variable is missing: ${name}`);
  }
  return value;
}

/**
 * BookStack smoke test用の設定を構築する。
 *
 * @returns {{baseUrl: string, readyUrl: string, username: string, password: string, artifactRoot: string}} BookStack検証設定。
 */
function buildBookStackConfig() {
  return {
    baseUrl: requiredEnv('BOOKSTACK_SMOKE_BASE_URL').replace(/\/$/, ''),
    readyUrl: (process.env.BOOKSTACK_SMOKE_READY_URL ?? requiredEnv('BOOKSTACK_SMOKE_BASE_URL')).replace(/\/$/, ''),
    username: requiredEnv('BOOKSTACK_SMOKE_USERNAME'),
    password: requiredEnv('BOOKSTACK_SMOKE_PASSWORD'),
    artifactRoot: ARTIFACT_ROOT,
  };
}

/**
 * 現在時刻をartifact file名へ安全に埋め込める形式で返す。
 *
 * @returns {string} `YYYY-MM-DDTHH-mm-ss-sssZ`形式のtimestamp。
 */
function artifactTimestamp() {
  return new Date().toISOString().replace(/[:.]/g, '-');
}

/**
 * BookStackの未認証login flow内URLかどうかを判定する。
 *
 * @param {URL} url - 判定対象のURL。
 * @param {string} baseUrl - BookStackのbase URL。
 * @returns {boolean} `/login`または`/oidc/login`にいる場合はtrue、それ以外はfalse。
 */
function isBookStackLoginFlowUrl(url, baseUrl) {
  const base = new URL(baseUrl);
  return url.origin === base.origin && (url.pathname === '/login' || url.pathname === '/oidc/login');
}

/**
 * 検証失敗時の調査用artifactを保存する。
 *
 * @param {import('playwright').Page} page - 保存対象のbrowser page。
 * @param {string} label - artifact名へ含める識別子。
 * @returns {Promise<void>} 保存完了後に解決するPromise。
 * @throws {Error} filesystemへの保存に失敗した場合に送出する。
 */
async function saveFailureArtifacts(page, label) {
  fs.mkdirSync(ARTIFACT_ROOT, { recursive: true });
  const basename = `${artifactTimestamp()}-${label}`;
  await page.screenshot({
    path: path.join(ARTIFACT_ROOT, `${basename}.png`),
    fullPage: true,
  });
  fs.writeFileSync(
    path.join(ARTIFACT_ROOT, `${basename}.html`),
    await page.content(),
    'utf8',
  );
}

/**
 * 指定URLへHTTP到達できるまで待機する。
 *
 * @param {string} url - 到達確認するURL。
 * @param {number} timeoutMs - 最大待機時間をミリ秒で指定する。
 * @returns {Promise<void>} URLが2xxまたは3xxで応答したら解決するPromise。
 * @throws {Error} timeoutまでに応答しない場合に送出する。
 */
async function waitForHttpReady(url, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError = undefined;

  while (Date.now() < deadline) {
    try {
      const response = await fetch(url, { redirect: 'manual' });
      if (response.status >= 200 && response.status < 400) {
        return;
      }
      lastError = new Error(`unexpected status ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }

  throw new Error(`timed out waiting for ${url}: ${lastError?.message ?? 'no response'}`);
}

/**
 * 表示されているKeycloak login formへ資格情報を入力する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{username: string, password: string}} credentials - Keycloak realm userの資格情報。
 * @returns {Promise<void>} login submit後の遷移が落ち着いたら解決するPromise。
 * @throws {Error} login formまたはsubmit buttonが見つからない場合に送出する。
 */
async function submitKeycloakLogin(page, credentials) {
  const username = page.locator('input[name="username"], input#username').first();
  const password = page.locator('input[name="password"], input#password').first();
  await username.waitFor({ state: 'visible', timeout: 60000 });
  await username.fill(credentials.username);
  await password.fill(credentials.password);

  const submitButton = page.locator('input[type="submit"], button[type="submit"]').first();
  await Promise.all([
    page.waitForLoadState('domcontentloaded', { timeout: 60000 }).catch(() => undefined),
    submitButton.click(),
  ]);
}

/**
 * BookStackのOIDC入口からKeycloak認証を完了する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - BookStackとKeycloakの検証設定。
 * @returns {Promise<void>} BookStackへ戻ったら解決するPromise。
 * @throws {Error} OIDC login linkが見つからない、または認証後にBookStackへ戻らない場合に送出する。
 */
async function loginToBookStack(page, config) {
  await page.goto(`${config.baseUrl}/login`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });

  const oidcLink = page
    .locator('#oidc-login, form[action*="/oidc/login"] button, a[href*="/oidc/login"]')
    .first();
  await oidcLink.waitFor({ state: 'visible', timeout: 60000 });
  await Promise.all([
    page.waitForURL((url) => !isBookStackLoginFlowUrl(url, config.baseUrl), {
      timeout: 60000,
    }),
    oidcLink.click(),
  ]);

  if (!page.url().startsWith(config.baseUrl)) {
    await submitKeycloakLogin(page, {
      username: config.username,
      password: config.password,
    });
  }

  await page.waitForURL((url) => {
    const base = new URL(config.baseUrl);
    return url.origin === base.origin && !isBookStackLoginFlowUrl(url, config.baseUrl);
  }, {
    timeout: 90000,
  });
}

/**
 * BookStackへ新規Bookを作成する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {string} baseUrl - BookStackのbase URL。
 * @param {string} title - 作成するBook名。
 * @returns {Promise<void>} 作成後画面でBook名が確認できたら解決するPromise。
 * @throws {Error} 作成form、保存button、または作成結果が確認できない場合に送出する。
 */
async function createBook(page, baseUrl, title) {
  await page.goto(`${baseUrl}/create-book`, {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });

  const nameInput = page.locator('input[name="name"], input#name').first();
  await nameInput.waitFor({ state: 'visible', timeout: 60000 });
  await nameInput.fill(title);

  const description = page
    .locator('textarea[name="description"], textarea[name="description_html"]')
    .first();
  if ((await description.count()) && (await description.isVisible())) {
    await description.fill('Playwright smoke testで作成した検証用Bookです。');
  }

  const saveButton = page
    .locator('button[type="submit"], input[type="submit"]')
    .filter({ hasText: /Create|Save|作成|保存|新規/i })
    .first();
  await Promise.all([
    page.waitForURL(/\/books\/.+/, { timeout: 60000 }).catch(() => undefined),
    saveButton.click(),
  ]);

  await page.locator('body').filter({ hasText: title }).waitFor({
    state: 'visible',
    timeout: 60000,
  });
}

/**
 * BookStackの認証と基本操作を検証する。
 *
 * @param {{baseUrl: string, readyUrl: string, username: string, password: string, artifactRoot: string}} config - BookStack検証設定。
 * @returns {Promise<void>} 検証が成功したら解決するPromise。
 * @throws {Error} 認証またはBook作成が失敗した場合に送出する。
 */
async function runBookStackSmoke(config) {
  await waitForHttpReady(`${config.readyUrl}/login`, 180000);

  const launchArgs = [];
  if (process.env.PLAYWRIGHT_HOST_RESOLVER_RULES) {
    launchArgs.push(`--host-resolver-rules=${process.env.PLAYWRIGHT_HOST_RESOLVER_RULES}`);
  }

  const browser = await chromium.launch({
    headless: process.env.PLAYWRIGHT_HEADLESS !== 'false',
    args: launchArgs,
  });
  const context = await browser.newContext({
    ignoreHTTPSErrors: true,
  });
  const page = await context.newPage();
  const title = `Codex Smoke Book ${artifactTimestamp()}`;

  try {
    await loginToBookStack(page, config);
    await createBook(page, config.baseUrl, title);
    console.log(`BookStack smoke passed: created "${title}"`);
  } catch (error) {
    await saveFailureArtifacts(page, 'bookstack');
    throw error;
  } finally {
    await context.close();
    await browser.close();
  }
}

/**
 * command line引数に対応するsmoke testを実行する。
 *
 * @returns {Promise<void>} 指定されたsmoke testが完了したら解決するPromise。
 * @throws {Error} 未知のsmoke case、またはsmoke test失敗時に送出する。
 */
async function main() {
  const smokeCase = process.argv[2] ?? 'bookstack';

  switch (smokeCase) {
    case 'bookstack':
      await runBookStackSmoke(buildBookStackConfig());
      break;
    default:
      throw new Error(`unknown smoke case: ${smokeCase}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
