#!/usr/bin/env node
'use strict';

/**
 * 生成内置模型远程配置并推送到 builtin-config 分支。
 *
 * 设计要点：
 * - 只推 builtin-config 分支，绝不碰 main；CI 只在 main 触发，所以不会跑 CI。
 * - 用 git plumbing 直接造提交（hash-object → mktree → commit-tree），
 *   不改工作区、不建本地分支，避免污染多 agent 共用仓库。
 * - Gitee 与 GitHub 并行推送；任一端失败重试一次，再失败只告警。
 * - 配置里没有 magpie Key；客户端拿到的只有公开别名和隧道地址。
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { spawn, spawnSync } = require('child_process');

// 与 App 端保持一致；这是公开常量，只做完整性校验，不是密钥
const CONFIG_CHECKSUM_KEY = 'qnote-builtin-config-v1';

const REPO_DIR = path.resolve(process.env.QNOTE_REPO_DIR || path.resolve(__dirname, '..', '..'));
const BRANCH = process.env.QNOTE_CONFIG_BRANCH || 'builtin-config';
const FILE_NAME = 'qnote_builtin.json';
const STATE_DIR = process.env.QNOTE_STATE_DIR || path.join(os.homedir(), '.config', 'qnote-tunnel');
const VERSION_FILE = path.join(STATE_DIR, 'config-version');
const LOCAL_CONFIG_PATH = path.join(STATE_DIR, FILE_NAME);
const GATEWAY_CONFIG_PATH = process.env.QNOTE_GATEWAY_CONFIG || path.join(STATE_DIR, 'gateway.json');

function readGatewayConfig() {
  try {
    return JSON.parse(fs.readFileSync(GATEWAY_CONFIG_PATH, 'utf8'));
  } catch {
    return {};
  }
}

const GATEWAY = readGatewayConfig();
const CHAT_GATEWAY = (GATEWAY.models && GATEWAY.models['qnote-free']) || {};
const IMAGE_GATEWAY = (GATEWAY.models && GATEWAY.models['qnote-image-free']) || {};

// Gitee 的 raw 对非默认分支不稳定（实测 404），国内主源改用 Contents API
const GITEE_CONTENTS_API = 'https://gitee.com/api/v5/repos/favo9/qnote/contents/qnote_builtin.json?ref=builtin-config';
const GITHUB_RAW = 'https://raw.githubusercontent.com/favoroo/QNote/builtin-config/qnote_builtin.json';
const JSDELIVR_URL = 'https://cdn.jsdelivr.net/gh/favoroo/QNote@builtin-config/qnote_builtin.json';

function log(...args) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  console.log(`[${ts}]`, ...args);
}

function fail(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--dry-run') out.dryRun = true;
    else if (arg === '--base-url' && argv[i + 1]) out.baseUrl = argv[++i];
    else if (arg.startsWith('--base-url=')) out.baseUrl = arg.slice('--base-url='.length);
    else if (arg === '--version' && argv[i + 1]) out.version = Number(argv[++i]);
    else if (arg.startsWith('--version=')) out.version = Number(arg.slice('--version='.length));
  }
  return out;
}

const ARGS = parseArgs(process.argv.slice(2));
const BASE_URL = (ARGS.baseUrl || process.env.QNOTE_BASE_URL || '').trim().replace(/\/+$/, '');
if (!BASE_URL) {
  fail('缺少公网地址：传 --base-url 或设置 QNOTE_BASE_URL');
}

const MIN_APP_VERSION = (process.env.QNOTE_MIN_APP_VERSION || '0.1.95').trim();
const CHAT_MODEL = (process.env.QNOTE_CHAT_MODEL || 'qnote-free').trim();
const CHAT_DISPLAY = (process.env.QNOTE_CHAT_DISPLAY || CHAT_GATEWAY.displayName || '小Q 免费模型').trim();
const CONTEXT_WINDOW = Number(process.env.QNOTE_CONTEXT_WINDOW || CHAT_GATEWAY.contextWindow || 1048576);
const VISION =
  process.env.QNOTE_VISION !== undefined ? process.env.QNOTE_VISION !== 'false' : CHAT_GATEWAY.vision !== false;
const IMAGE_ENABLED =
  process.env.QNOTE_IMAGE_ENABLED !== undefined
    ? process.env.QNOTE_IMAGE_ENABLED === 'true'
    : IMAGE_GATEWAY.enabled === true;
const MAINTENANCE =
  process.env.QNOTE_MAINTENANCE !== undefined
    ? process.env.QNOTE_MAINTENANCE === 'true'
    : Boolean(GATEWAY.maintenance && GATEWAY.maintenance.enabled);
const MAINTENANCE_MESSAGE = (
  process.env.QNOTE_MAINTENANCE_MESSAGE ||
  (GATEWAY.maintenance && GATEWAY.maintenance.message) ||
  ''
).trim();

function readVersionFloor() {
  let version = 0;
  try {
    version = Math.max(version, Number(fs.readFileSync(VERSION_FILE, 'utf8').trim()) || 0);
  } catch {
    // 首次发布没有本地版本号
  }
  return version;
}

async function fetchGiteeConfig() {
  const res = await fetch(GITEE_CONTENTS_API, { signal: AbortSignal.timeout(8000) });
  if (!res.ok) return null;
  const payload = await res.json();
  if (payload && payload.encoding === 'base64' && payload.content) {
    return JSON.parse(Buffer.from(payload.content, 'base64').toString('utf8'));
  }
  return null;
}

async function fetchRemoteVersion() {
  try {
    const data = await fetchGiteeConfig();
    return Number(data && data.version) || 0;
  } catch {
    return 0;
  }
}

function signConfig(config) {
  // 字段顺序必须与 App 端 builtin_service_config.dart 的 canonical 完全一致
  const canonical = [
    config.version,
    config.updatedAt,
    config.minAppVersion,
    config.enabled,
    config.chat.enabled,
    config.chat.baseUrl,
    config.chat.model,
    config.chat.displayName,
    config.chat.contextWindow,
    config.chat.vision,
    config.image.enabled,
    config.image.model,
    config.image.displayName,
    config.maintenance.enabled,
    config.maintenance.message,
  ].join('\n');
  return crypto.createHmac('sha256', CONFIG_CHECKSUM_KEY).update(canonical).digest('hex');
}

function buildConfig(version) {
  const config = {
    version,
    updatedAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    minAppVersion: MIN_APP_VERSION,
    enabled: !MAINTENANCE,
    chat: {
      enabled: true,
      baseUrl: `${BASE_URL}/v1`,
      model: CHAT_MODEL,
      displayName: CHAT_DISPLAY,
      contextWindow: CONTEXT_WINDOW,
      vision: VISION,
    },
    image: {
      enabled: IMAGE_ENABLED,
      model: 'qnote-image-free',
      displayName: '小Q 免费生图',
    },
    maintenance: {
      enabled: MAINTENANCE,
      message: MAINTENANCE_MESSAGE,
    },
  };
  config.sig = signConfig(config);
  return config;
}

function git(args, options = {}) {
  const result = spawnSync('git', ['-C', REPO_DIR, ...args], {
    encoding: 'utf8',
    timeout: 60000,
    ...options,
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`git ${args.join(' ')} 失败：${(result.stderr || result.stdout || '').trim()}`);
  }
  return (result.stdout || '').trim();
}

function gitMaybe(args) {
  try {
    return git(args);
  } catch {
    return '';
  }
}

function pushRef(remote, sha) {
  return new Promise((resolve) => {
    const child = spawn('git', ['-C', REPO_DIR, 'push', remote, `${sha}:refs/heads/${BRANCH}`], {
      stdio: 'pipe',
    });
    let stderr = '';
    child.stderr.on('data', (chunk) => {
      stderr += chunk.toString();
    });
    child.on('close', (code) => {
      resolve({ ok: code === 0, detail: stderr.trim() });
    });
  });
}

async function pushWithRetry(remote, sha) {
  const first = await pushRef(remote, sha);
  if (first.ok) return first;
  log(`${remote} 首次推送失败，重试一次：${first.detail.slice(0, 200)}`);
  await new Promise((resolve) => setTimeout(resolve, 1500));
  return pushRef(remote, sha);
}

async function waitForGiteeConfig(version) {
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      const data = await fetchGiteeConfig();
      if (data && Number(data.version) === version && typeof data.sig === 'string' && data.sig.length === 64) {
        return { ok: true, version: data.version };
      }
    } catch {
      // 接口抖动，稍后重试
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  return { ok: false };
}

async function waitForRaw(url, version) {
  for (let attempt = 1; attempt <= 6; attempt++) {
    try {
      const res = await fetch(`${url}?t=${Date.now()}`, { signal: AbortSignal.timeout(8000) });
      if (res.ok) {
        const data = await res.json();
        if (Number(data.version) === version && typeof data.sig === 'string' && data.sig.length === 64) {
          return { ok: true, version: data.version };
        }
      }
    } catch {
      // 网络抖动或 CDN 还没刷新
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  return { ok: false };
}

async function main() {
  fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });

  const version = Number(ARGS.version) || Math.max(readVersionFloor(), await fetchRemoteVersion()) + 1;
  if (!Number.isFinite(version) || version <= 0) {
    fail(`版本号无效：${version}`);
  }

  const config = buildConfig(version);
  const json = `${JSON.stringify(config, null, 2)}\n`;
  fs.writeFileSync(LOCAL_CONFIG_PATH, json, { mode: 0o644 });

  if (ARGS.dryRun) {
    log(`dry-run：配置版本 ${version}，未推送`);
    process.stdout.write(json);
    return;
  }

  // 取远端分支作为父提交；分支不存在时就是首次提交
  gitMaybe(['fetch', '--depth', '1', 'origin', `${BRANCH}:refs/remotes/origin/${BRANCH}`]);
  const parent = gitMaybe(['rev-parse', '--verify', `refs/remotes/origin/${BRANCH}`]);

  const blob = git(['hash-object', '-w', LOCAL_CONFIG_PATH]);
  const tree = spawnSync('git', ['-C', REPO_DIR, 'mktree'], {
    input: `100644 blob ${blob}\t${FILE_NAME}\n`,
    encoding: 'utf8',
    timeout: 30000,
  });
  if (tree.status !== 0) {
    fail(`mktree 失败：${(tree.stderr || '').trim()}`);
  }
  const treeSha = tree.stdout.trim();

  const commitArgs = ['commit-tree', treeSha];
  if (parent) commitArgs.push('-p', parent);
  commitArgs.push('-m', `chore(builtin): config v${version}`);
  const commitSha = git(commitArgs, {
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: process.env.GIT_AUTHOR_NAME || 'QNote Builtin Service',
      GIT_AUTHOR_EMAIL: process.env.GIT_AUTHOR_EMAIL || 'builtin@qnote.local',
      GIT_COMMITTER_NAME: process.env.GIT_COMMITTER_NAME || 'QNote Builtin Service',
      GIT_COMMITTER_EMAIL: process.env.GIT_COMMITTER_EMAIL || 'builtin@qnote.local',
    },
  });

  log(`配置 v${version} 已生成，提交 ${commitSha.slice(0, 12)}，开始双端推送…`);
  const [originResult, giteeResult] = await Promise.all([
    pushWithRetry('origin', commitSha),
    pushWithRetry('gitee', commitSha),
  ]);

  const gitee = await waitForGiteeConfig(version);
  const jsdelivr = await waitForRaw(JSDELIVR_URL, version);
  // GitHub raw 有 Fastly 缓存，可能滞后几分钟，只作信息展示，不参与成败判定
  const github = await waitForRaw(GITHUB_RAW, version);

  fs.writeFileSync(VERSION_FILE, String(version), { mode: 0o600 });

  // 国内主源（Gitee API）与 CDN 镜像都拿到新版本即视为发布成功
  const ok = originResult.ok && giteeResult.ok && gitee.ok;
  const summary = {
    ok,
    version,
    baseUrl: BASE_URL,
    commit: commitSha.slice(0, 12),
    push: { origin: originResult.ok, gitee: giteeResult.ok },
    sources: { giteeApi: gitee.ok, jsdelivr: jsdelivr.ok, github: github.ok },
    configPath: LOCAL_CONFIG_PATH,
  };
  process.stdout.write(`\n${JSON.stringify(summary, null, 2)}\n`);

  if (!ok) {
    log(
      `发布未完全成功：push origin=${originResult.ok} gitee=${giteeResult.ok}；源 giteeApi=${gitee.ok} jsdelivr=${jsdelivr.ok} github=${github.ok}`,
    );
    if (!originResult.ok) log(`origin：${originResult.detail.slice(0, 300)}`);
    if (!giteeResult.ok) log(`gitee：${giteeResult.detail.slice(0, 300)}`);
    process.exit(2);
  }
  log(`发布完成：v${version} ${BASE_URL}（jsdelivr=${jsdelivr.ok} github=${github.ok} 为镜像状态）`);
}

main().catch((e) => {
  fail(e.stack || e.message);
});