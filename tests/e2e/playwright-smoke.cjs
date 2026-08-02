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
 * Playwright smoke test用の共通設定を構築する。
 *
 * @param {string} smokeCase - 実行するsmoke case名。
 * @returns {{smokeCase: string, baseUrl: string, readyUrl: string, username: string, password: string, artifactRoot: string}} 共通検証設定。
 */
function buildSmokeConfig(smokeCase) {
  return {
    smokeCase,
    baseUrl: requiredEnv('PLAYWRIGHT_SMOKE_BASE_URL').replace(/\/$/, ''),
    readyUrl: (process.env.PLAYWRIGHT_SMOKE_READY_URL ?? requiredEnv('PLAYWRIGHT_SMOKE_BASE_URL')).replace(/\/$/, ''),
    username: requiredEnv('PLAYWRIGHT_SMOKE_USERNAME'),
    password: requiredEnv('PLAYWRIGHT_SMOKE_PASSWORD'),
    artifactRoot: ARTIFACT_ROOT,
    langfusePublicKey: process.env.PLAYWRIGHT_LANGFUSE_PUBLIC_KEY,
    langfuseSecretKey: process.env.PLAYWRIGHT_LANGFUSE_SECRET_KEY,
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
 * browser sessionのcookieを使って同一originのJSON APIを呼び出す。
 *
 * @param {import('playwright').Page} page - 認証済みbrowser page。
 * @param {string} url - 呼び出すAPI URL。
 * @param {{method?: string, data?: unknown, headers?: Record<string, string>}} [options] - HTTP method、JSON body、追加header。
 * @returns {Promise<any>} JSON response body。
 * @throws {Error} HTTP responseが成功でない場合、またはJSONとして解釈できない場合に送出する。
 */
async function requestJsonFromPage(page, url, options = {}) {
  const result = await page.evaluate(async ({ requestUrl, requestOptions }) => {
    const response = await fetch(requestUrl, {
      method: requestOptions.method ?? 'GET',
      headers: {
        ...requestOptions.data !== undefined ? { 'content-type': 'application/json' } : {},
        ...(requestOptions.headers ?? {}),
      },
      body: requestOptions.data !== undefined ? JSON.stringify(requestOptions.data) : undefined,
    });
    return {
      ok: response.ok,
      status: response.status,
      body: await response.text(),
    };
  }, { requestUrl: url, requestOptions: options });

  if (!result.ok) {
    throw new Error(`JSON API request failed: ${result.status} ${result.body}`);
  }
  return result.body ? JSON.parse(result.body) : null;
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
 * serviceのlogin入口を押し、必要ならKeycloak資格情報を入力してserviceへ戻るまで待機する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - serviceとKeycloakの検証設定。
 * @param {{entryPath: string, providerSelector: string, loginPathPattern?: RegExp}} options - login入口と未認証pathの判定設定。
 * @returns {Promise<void>} 認証後にservice originへ戻ったら解決するPromise。
 * @throws {Error} login入口が見つからない、または認証後にserviceへ戻らない場合に送出する。
 */
async function loginViaKeycloak(page, config, options) {
  await page.goto(`${config.baseUrl}${options.entryPath}`, {
    waitUntil: 'domcontentloaded',
    timeout: 90000,
  });

  const providerLink = page.locator(options.providerSelector).first();
  await providerLink.waitFor({ state: 'visible', timeout: 90000 });
  const loginEntryUrl = page.url();
  await Promise.all([
    page.waitForURL((url) => url.href !== loginEntryUrl, { timeout: 90000 }),
    providerLink.click({ force: true }),
  ]);

  if (new URL(page.url()).origin !== new URL(config.baseUrl).origin) {
    await submitKeycloakLogin(page, {
      username: config.username,
      password: config.password,
    });
  }

  const appOrigin = new URL(config.baseUrl).origin;
  const appReturn = page.waitForURL((url) => {
    const stillInLoginPath = options.loginPathPattern?.test(url.pathname) ?? false;
    return url.origin === appOrigin && !stillInLoginPath;
  }, {
    timeout: 120000,
  });
  const providerFailure = page
    .getByText(/Failed to get token from provider|OAuth login failed|OIDC login failed/i)
    .first()
    .waitFor({ state: 'visible', timeout: 120000 })
    .then(() => {
      throw new Error(`OIDC provider login failed at ${page.url()}`);
    });
  await Promise.race([appReturn, providerFailure]);
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
 * 認証済みNextcloud sessionで検証用folderを作成する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string}} config - NextcloudのURLと利用者名。
 * @param {string} folderName - 作成するfolder名。
 * @returns {Promise<void>} WebDAVでfolder作成と一覧表示を確認したら解決するPromise。
 * @throws {Error} request token取得、WebDAV作成、または一覧確認に失敗した場合に送出する。
 */
async function createNextcloudFolder(page, config, folderName) {
  const requestToken = await page.evaluate(() => globalThis.OC?.requestToken ?? '');
  if (!requestToken) {
    throw new Error('Nextcloud request token was not found');
  }

  const folderUrl = `${config.baseUrl}/remote.php/dav/files/${encodeURIComponent(config.username)}/${encodeURIComponent(folderName)}`;
  const result = await page.evaluate(async ({ url, token }) => {
    const response = await fetch(url, {
      method: 'MKCOL',
      headers: {
        requesttoken: token,
      },
    });
    return { status: response.status, body: await response.text() };
  }, { url: folderUrl, token: requestToken });
  if (result.status !== 201) {
    throw new Error(`Nextcloud folder creation failed: ${result.status} ${result.body}`);
  }

  await page.goto(`${config.baseUrl}/apps/files/files`, {
    waitUntil: 'domcontentloaded',
    timeout: 90000,
  });
  await page.getByText(folderName, { exact: true }).first().waitFor({
    state: 'visible',
    timeout: 90000,
  });
}

/**
 * NextcloudへOIDC loginし、Files画面を表示できることを検証する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - NextcloudとKeycloakの検証設定。
 * @returns {Promise<void>} Files画面を確認できたら解決するPromise。
 * @throws {Error} OIDC認証またはFiles画面の表示に失敗した場合に送出する。
 */
async function verifyNextcloud(page, config) {
  await loginViaKeycloak(page, config, {
    entryPath: '/login',
    providerSelector: 'a[href*="user_oidc"], button:has-text("Keycloak"), a:has-text("Keycloak")',
    loginPathPattern: /^\/login/,
  });
  await page.goto(`${config.baseUrl}/apps/files/files`, {
    waitUntil: 'domcontentloaded',
    timeout: 90000,
  });
  await page.locator('body').filter({ hasText: /Files|ファイル|All files|すべてのファイル/i }).waitFor({
    state: 'visible',
    timeout: 90000,
  });
  await createNextcloudFolder(page, config, `Playwright Folder ${artifactTimestamp()}`);
}

/**
 * KaneoへOIDC loginし、project画面を表示できることを検証する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - KaneoとKeycloakの検証設定。
 * @returns {Promise<void>} 認証済み画面を確認できたら解決するPromise。
 * @throws {Error} OIDC認証または認証済み画面の表示に失敗した場合に送出する。
 */
async function verifyKaneo(page, config) {
  await loginViaKeycloak(page, config, {
    entryPath: '/',
    providerSelector: 'button:has-text("OAuth"), button:has-text("Keycloak"), button:has-text("Continue"), a[href*="oauth"]',
    loginPathPattern: /^\/(login|auth)/,
  });
  await page.locator('body').filter({ hasText: /Project|プロジェクト|Board|ボード/i }).waitFor({
    state: 'visible',
    timeout: 90000,
  });

  const workspaceResult = await requestJsonFromPage(
    page,
    `${config.baseUrl}/api/auth/organization/list`,
  );
  const workspaces = Array.isArray(workspaceResult)
    ? workspaceResult
    : (workspaceResult?.organizations ?? []);
  if (!workspaces[0]?.id) {
    throw new Error('Kaneo workspace was not found after OIDC login');
  }

  const suffix = artifactTimestamp().toLowerCase();
  const project = await requestJsonFromPage(page, `${config.baseUrl}/api/project`, {
    method: 'POST',
    data: {
      name: `Playwright Project ${suffix}`,
      workspaceId: workspaces[0].id,
      icon: 'Layout',
      slug: `playwright-${suffix}`,
    },
  });
  if (!project?.id) {
    throw new Error('Kaneo project creation did not return an ID');
  }

  const task = await requestJsonFromPage(page, `${config.baseUrl}/api/task/${project.id}`, {
    method: 'POST',
    data: {
      title: `Playwright Ticket ${suffix}`,
      description: 'Playwright smoke testで作成した検証用ticketです。',
      priority: 'medium',
      status: 'to-do',
    },
  });
  if (!task?.id) {
    throw new Error('Kaneo ticket creation did not return an ID');
  }
}

/**
 * ZulipへOIDC loginし、message画面を表示できることを検証する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - ZulipとKeycloakの検証設定。
 * @returns {Promise<void>} 認証済みmessage画面を確認できたら解決するPromise。
 * @throws {Error} OIDC認証またはmessage画面の表示に失敗した場合に送出する。
 */
async function verifyZulip(page, config) {
  await loginViaKeycloak(page, config, {
    entryPath: '/login/',
    providerSelector: 'a:has-text("Keycloak"), button:has-text("Keycloak"), a[href*="oidc"]',
    loginPathPattern: /^\/(login|accounts\/login)/,
  });
  await page.locator('body').filter({ hasText: /Streams|Channels|ストリーム|チャンネル/i }).waitFor({
    state: 'visible',
    timeout: 120000,
  });
}

/**
 * GiteaへOIDC loginし、repository画面を表示できることを検証する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - GiteaとKeycloakの検証設定。
 * @returns {Promise<void>} 認証済みrepository画面を確認できたら解決するPromise。
 * @throws {Error} OIDC認証またはrepository画面の表示に失敗した場合に送出する。
 */
async function verifyGitea(page, config) {
  await loginViaKeycloak(page, config, {
    entryPath: '/user/login',
    providerSelector: 'a[href*="/user/oauth2/keycloak"], a:has-text("keycloak"), button:has-text("keycloak")',
    loginPathPattern: /^\/user\/login/,
  });
  await page.locator('body').filter({ hasText: /Repositories|リポジトリ|Dashboard|ダッシュボード/i }).waitFor({
    state: 'visible',
    timeout: 90000,
  });

  const repositoryName = `playwright-${artifactTimestamp().toLowerCase()}`;
  const repository = await requestJsonFromPage(page, `${config.baseUrl}/api/v1/user/repos`, {
    method: 'POST',
    data: {
      name: repositoryName,
      description: 'Playwright smoke testで作成した検証用repositoryです。',
      private: true,
      auto_init: true,
    },
  });
  if (repository?.name !== repositoryName) {
    throw new Error('Gitea repository creation result did not match the request');
  }
}

/**
 * Open WebUIへOIDC loginし、chat入力画面を表示できることを検証する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - Open WebUIとKeycloakの検証設定。
 * @returns {Promise<void>} chat入力欄を確認できたら解決するPromise。
 * @throws {Error} OIDC認証またはchat画面の表示に失敗した場合に送出する。
 */
async function verifyOpenWebUi(page, config) {
  await loginViaKeycloak(page, config, {
    entryPath: '/auth',
    providerSelector: 'button:has-text("Keycloak"), button:has-text("Continue"), a[href*="oauth"]',
    loginPathPattern: /^\/auth/,
  });
  await page.locator('textarea, [contenteditable="true"], #chat-input').first().waitFor({
    state: 'visible',
    timeout: 120000,
  });

  const title = `Playwright Note ${artifactTimestamp()}`;
  const note = await requestJsonFromPage(page, `${config.baseUrl}/api/v1/notes/create`, {
    method: 'POST',
    data: {
      title,
      data: {
        content: {
          md: 'Playwright smoke testで作成した検証用Noteです。',
        },
      },
      meta: {},
      access_grants: [],
    },
  });
  if (note?.title !== title) {
    throw new Error('Open WebUI note creation result did not match the request');
  }
}

/**
 * GrafanaへOIDC loginし、dashboard画面を表示できることを検証する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - GrafanaとKeycloakの検証設定。
 * @returns {Promise<void>} dashboard画面を確認できたら解決するPromise。
 * @throws {Error} OIDC認証またはdashboard画面の表示に失敗した場合に送出する。
 */
async function verifyGrafana(page, config) {
  await loginViaKeycloak(page, config, {
    entryPath: '/login',
    providerSelector: 'a[href*="/login/generic_oauth"], button:has-text("Keycloak"), a:has-text("Keycloak")',
    loginPathPattern: /^\/login/,
  });
  await page.locator('body').filter({ hasText: /Dashboards|ダッシュボード|Home/i }).waitFor({
    state: 'visible',
    timeout: 90000,
  });

  const title = `Playwright Dashboard ${artifactTimestamp()}`;
  const result = await requestJsonFromPage(page, `${config.baseUrl}/api/dashboards/db`, {
    method: 'POST',
    data: {
      dashboard: {
        title,
        schemaVersion: 41,
        panels: [],
      },
      overwrite: false,
    },
  });
  await page.goto(`${config.baseUrl}${result.url}`, {
    waitUntil: 'domcontentloaded',
    timeout: 90000,
  });
  await page.getByText(title, { exact: true }).first().waitFor({ state: 'visible', timeout: 90000 });
}

/**
 * LangfuseへOIDC loginし、project画面を表示できることを検証する。
 *
 * @param {import('playwright').Page} page - 操作対象のbrowser page。
 * @param {{baseUrl: string, username: string, password: string}} config - LangfuseとKeycloakの検証設定。
 * @returns {Promise<void>} project画面を確認できたら解決するPromise。
 * @throws {Error} OIDC認証またはproject画面の表示に失敗した場合に送出する。
 */
async function verifyLangfuse(page, config) {
  await loginViaKeycloak(page, config, {
    entryPath: '/auth/sign-in',
    providerSelector: 'button:has-text("Keycloak"), a:has-text("Keycloak"), a[href*="keycloak"]',
    loginPathPattern: /^\/auth/,
  });
  await page.locator('body').filter({ hasText: /Projects|プロジェクト|Tracing|トレース/i }).waitFor({
    state: 'visible',
    timeout: 90000,
  });

  if (!config.langfusePublicKey || !config.langfuseSecretKey) {
    throw new Error('Langfuse prompt API credentials are missing');
  }
  const promptName = `playwright-${artifactTimestamp().toLowerCase()}`;
  const authorization = Buffer.from(
    `${config.langfusePublicKey}:${config.langfuseSecretKey}`,
    'utf8',
  ).toString('base64');
  const prompt = await requestJsonFromPage(page, `${config.baseUrl}/api/public/v2/prompts`, {
    method: 'POST',
    headers: {
      authorization: `Basic ${authorization}`,
    },
    data: {
      name: promptName,
      type: 'text',
      prompt: 'Playwright smoke testで作成した検証用promptです。',
      labels: ['latest'],
    },
  });
  if (prompt?.name !== promptName) {
    throw new Error('Langfuse prompt creation result did not match the request');
  }
}

/**
 * service固有のbrowser操作を共通browser context上で実行する。
 *
 * @param {{smokeCase: string, baseUrl: string, readyUrl: string}} config - 実行するserviceの検証設定。
 * @param {(page: import('playwright').Page, config: object) => Promise<void>} operation - service固有の認証と基本操作。
 * @returns {Promise<void>} service固有操作が成功したら解決するPromise。
 * @throws {Error} serviceの準備、browser起動、認証、基本操作のいずれかが失敗した場合に送出する。
 */
async function runBrowserSmoke(config, operation) {
  await waitForHttpReady(config.readyUrl, 240000);

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

  try {
    await operation(page, config);
    console.log(`${config.smokeCase} smoke passed`);
  } catch (error) {
    await saveFailureArtifacts(page, config.smokeCase);
    throw error;
  } finally {
    await context.close();
    await browser.close();
  }
}

/**
 * BookStackの認証と基本操作を検証する。
 *
 * @param {{baseUrl: string, readyUrl: string, username: string, password: string, artifactRoot: string}} config - BookStack検証設定。
 * @returns {Promise<void>} 検証が成功したら解決するPromise。
 * @throws {Error} 認証またはBook作成が失敗した場合に送出する。
 */
async function runBookStackSmoke(config) {
  await runBrowserSmoke(config, async (page) => {
    const title = `Codex Smoke Book ${artifactTimestamp()}`;
    await loginToBookStack(page, config);
    await createBook(page, config.baseUrl, title);
    console.log(`BookStack smoke passed: created "${title}"`);
  });
}

/**
 * command line引数に対応するsmoke testを実行する。
 *
 * @returns {Promise<void>} 指定されたsmoke testが完了したら解決するPromise。
 * @throws {Error} 未知のsmoke case、またはsmoke test失敗時に送出する。
 */
async function main() {
  const smokeCase = process.argv[2] ?? 'bookstack';
  const config = buildSmokeConfig(smokeCase);

  switch (smokeCase) {
    case 'nextcloud':
      await runBrowserSmoke(config, verifyNextcloud);
      break;
    case 'bookstack':
      await runBookStackSmoke(config);
      break;
    case 'kaneo':
      await runBrowserSmoke(config, verifyKaneo);
      break;
    case 'zulip':
      await runBrowserSmoke(config, verifyZulip);
      break;
    case 'gitea':
      await runBrowserSmoke(config, verifyGitea);
      break;
    case 'open-webui':
      await runBrowserSmoke(config, verifyOpenWebUi);
      break;
    case 'grafana':
      await runBrowserSmoke(config, verifyGrafana);
      break;
    case 'langfuse':
      await runBrowserSmoke(config, verifyLangfuse);
      break;
    default:
      throw new Error(`unknown smoke case: ${smokeCase}`);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
