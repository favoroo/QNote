#!/usr/bin/env node
'use strict';

/**
 * QNote 内置免费模型网关
 *
 * 职责：
 * 1. 把 magpie 的 group/qnote 包装成公开别名 qnote-free，隐藏真实模型名；
 * 2. 只放行 /v1/models、/v1/chat/completions、/v1/images/generations；
 * 3. 注入 magpie 网关 Key，丢弃客户端自带的 Authorization，避免把用户 Key 转发出去；
 * 4. 按安装 ID / IP 做小时与天级配额，超限返回 429；
 * 5. 流式与非流式响应都把 model 字段改写回公开别名，避免上游模型名泄露。
 *
 * 客户端常量（安装签名 secret）不是真密钥：源码公开，任何人都能提取。
 * 真正的防线是配额、模型白名单和全局开关，签名只用于挡掉随手扫描。
 */

const http = require('http');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const GATEWAY_VERSION = '1.0.0';
const CHAT_PATH = '/v1/chat/completions';
const IMAGE_PATH = '/v1/images/generations';
const MODELS_PATH = '/v1/models';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--config' && argv[i + 1]) {
      out.config = argv[++i];
    } else if (arg.startsWith('--config=')) {
      out.config = arg.slice('--config='.length);
    }
  }
  return out;
}

const ARGS = parseArgs(process.argv.slice(2));
const CONFIG_PATH = path.resolve(
  ARGS.config || process.env.QNOTE_GATEWAY_CONFIG || path.join(__dirname, 'config.json'),
);

function expandHome(value) {
  if (!value) return value;
  if (value === '~') return os.homedir();
  if (value.startsWith('~/')) return path.join(os.homedir(), value.slice(2));
  return value;
}

function log(...args) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  console.log(`[${ts}]`, ...args);
}

function warn(...args) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  console.warn(`[${ts}] WARN`, ...args);
}

function die(message) {
  warn(message);
  process.exit(1);
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    die(`配置文件不存在：${CONFIG_PATH}`);
  }
  let raw;
  try {
    raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  } catch (e) {
    die(`配置文件解析失败：${e.message}`);
  }
  const dir = path.dirname(CONFIG_PATH);
  const rawQuotas = raw.quotas || {};
  const quotas = {
    device: { perHour: 30, perDay: 300, tokensPerDay: 3000000, ...(rawQuotas.device || {}) },
    ip: { perHour: 60, perDay: 600, ...(rawQuotas.ip || {}) },
    global: { perDay: 0, tokensPerDay: 0, ...(rawQuotas.global || {}) },
    imageDevice: { perDay: 3, ...(rawQuotas.imageDevice || {}) },
    maxTokensPerRequest: rawQuotas.maxTokensPerRequest ?? 4096,
    maxBodyBytes: rawQuotas.maxBodyBytes ?? 1048576,
  };
  return {
    listen: raw.listen || '127.0.0.1:3426',
    upstream: (raw.upstream || 'http://127.0.0.1:3425').replace(/\/+$/, ''),
    appSecrets: Array.isArray(raw.appSecrets) ? raw.appSecrets.map((s) => String(s).trim()).filter(Boolean) : [],
    requireSignature: raw.requireSignature !== false,
    magpieSettingsPath: expandHome(raw.magpieSettingsPath || '~/.config/magpie/settings.json'),
    models: raw.models || {},
    quotas,
    maintenance: { enabled: false, message: '', ...(raw.maintenance || {}) },
    logFile: path.resolve(dir, raw.logFile || 'usage.jsonl'),
    stateFile: path.resolve(dir, raw.stateFile || 'usage-state.json'),
    upstreamTimeoutMs: Number(raw.upstreamTimeoutMs || 180000),
  };
}

let cfg = loadConfig();

function readMagpieKey() {
  if (process.env.MAGPIE_KEY && process.env.MAGPIE_KEY.trim()) {
    return process.env.MAGPIE_KEY.trim();
  }
  try {
    const settings = JSON.parse(fs.readFileSync(cfg.magpieSettingsPath, 'utf8'));
    if (settings.lan !== true) {
      warn(`magpie 未开启「局域网共享」：${cfg.magpieSettingsPath}`);
    }
    const key = String(settings.lanKey || '').trim();
    if (!key) warn('magpie settings.json 里没有 lanKey');
    return key;
  } catch (e) {
    warn(`读取 magpie 配置失败：${e.message}`);
    return '';
  }
}

let MAGPIE_KEY = readMagpieKey();
if (!MAGPIE_KEY) {
  die('缺少 magpie 网关 Key（Settings → Network and sharing → Share on local network）');
}

// ── 时间与配额 ────────────────────────────────────────────────

function pad2(n) {
  return String(n).padStart(2, '0');
}

function dayKey(date = new Date()) {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

function hourKey(date = new Date()) {
  return `${dayKey(date)}-${pad2(date.getHours())}`;
}

function sha256(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function emptyState() {
  return {
    device: {},
    ip: {},
    image: {},
    global: { dayKey: dayKey(), dayCount: 0, tokensDay: 0 },
  };
}

function loadState() {
  try {
    const parsed = JSON.parse(fs.readFileSync(cfg.stateFile, 'utf8'));
    return {
      device: parsed.device || {},
      ip: parsed.ip || {},
      image: parsed.image || {},
      global: parsed.global || { dayKey: dayKey(), dayCount: 0, tokensDay: 0 },
    };
  } catch {
    return emptyState();
  }
}

let state = loadState();

function pruneState() {
  const today = dayKey();
  for (const bucket of ['device', 'ip', 'image']) {
    for (const [key, value] of Object.entries(state[bucket])) {
      if (value.dayKey && value.dayKey !== today) {
        delete state[bucket][key];
      }
    }
  }
}

function saveState() {
  pruneState();
  try {
    const tmp = `${cfg.stateFile}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(state));
    fs.renameSync(tmp, cfg.stateFile);
  } catch (e) {
    warn(`写入用量状态失败：${e.message}`);
  }
}

function deviceEntry(installId) {
  const key = sha256(installId).slice(0, 16);
  let entry = state.device[key];
  if (!entry) {
    entry = { hourKey: hourKey(), hourCount: 0, dayKey: dayKey(), dayCount: 0, tokensDay: 0 };
    state.device[key] = entry;
  }
  if (entry.hourKey !== hourKey()) {
    entry.hourKey = hourKey();
    entry.hourCount = 0;
  }
  if (entry.dayKey !== dayKey()) {
    entry.dayKey = dayKey();
    entry.dayCount = 0;
    entry.tokensDay = 0;
  }
  return entry;
}

function ipEntry(ip) {
  const key = sha256(ip).slice(0, 16);
  let entry = state.ip[key];
  if (!entry) {
    entry = { hourKey: hourKey(), hourCount: 0, dayKey: dayKey(), dayCount: 0 };
    state.ip[key] = entry;
  }
  if (entry.hourKey !== hourKey()) {
    entry.hourKey = hourKey();
    entry.hourCount = 0;
  }
  if (entry.dayKey !== dayKey()) {
    entry.dayKey = dayKey();
    entry.dayCount = 0;
  }
  return entry;
}

function imageEntry(installId) {
  const key = sha256(installId).slice(0, 16);
  let entry = state.image[key];
  if (!entry) {
    entry = { dayKey: dayKey(), dayCount: 0 };
    state.image[key] = entry;
  }
  if (entry.dayKey !== dayKey()) {
    entry.dayKey = dayKey();
    entry.dayCount = 0;
  }
  return entry;
}

function globalEntry() {
  if (state.global.dayKey !== dayKey()) {
    state.global = { dayKey: dayKey(), dayCount: 0, tokensDay: 0 };
  }
  return state.global;
}

function quotaHeaders(kind, installId) {
  const q = cfg.quotas;
  const d = deviceEntry(installId);
  const image = imageEntry(installId);
  const headers = {
    'X-QNote-Quota-Hour-Limit': String(kind === 'image' ? q.imageDevice.perDay : q.device.perHour),
    'X-QNote-Quota-Hour-Remaining': String(
      Math.max(0, (kind === 'image' ? q.imageDevice.perDay : q.device.perHour) - (kind === 'image' ? image.dayCount : d.hourCount)),
    ),
    'X-QNote-Quota-Day-Limit': String(kind === 'image' ? q.imageDevice.perDay : q.device.perDay),
    'X-QNote-Quota-Day-Remaining': String(
      Math.max(0, (kind === 'image' ? q.imageDevice.perDay : q.device.perDay) - (kind === 'image' ? image.dayCount : d.dayCount)),
    ),
    'X-QNote-Token-Day-Remaining': String(Math.max(0, q.device.tokensPerDay - d.tokensDay)),
  };
  return headers;
}

function quotaDeny(reason, limit) {
  return { ok: false, reason, limit };
}

function reserve(kind, installId, ip) {
  const q = cfg.quotas;
  const d = deviceEntry(installId);
  const ipEntryValue = ipEntry(ip);
  const g = globalEntry();

  if (kind === 'image') {
    const img = imageEntry(installId);
    if (q.imageDevice.perDay > 0 && img.dayCount >= q.imageDevice.perDay) {
      return quotaDeny('image_day', q.imageDevice.perDay);
    }
    if (q.ip.perHour > 0 && ipEntryValue.hourCount >= q.ip.perHour) {
      return quotaDeny('ip_hour', q.ip.perHour);
    }
    if (q.ip.perDay > 0 && ipEntryValue.dayCount >= q.ip.perDay) {
      return quotaDeny('ip_day', q.ip.perDay);
    }
    img.dayCount++;
    ipEntryValue.hourCount++;
    ipEntryValue.dayCount++;
    return { ok: true };
  }

  if (q.device.perHour > 0 && d.hourCount >= q.device.perHour) {
    return quotaDeny('device_hour', q.device.perHour);
  }
  if (q.device.perDay > 0 && d.dayCount >= q.device.perDay) {
    return quotaDeny('device_day', q.device.perDay);
  }
  if (q.device.tokensPerDay > 0 && d.tokensDay >= q.device.tokensPerDay) {
    return quotaDeny('tokens_day', q.device.tokensPerDay);
  }
  if (q.ip.perHour > 0 && ipEntryValue.hourCount >= q.ip.perHour) {
    return quotaDeny('ip_hour', q.ip.perHour);
  }
  if (q.ip.perDay > 0 && ipEntryValue.dayCount >= q.ip.perDay) {
    return quotaDeny('ip_day', q.ip.perDay);
  }
  if (q.global.perDay > 0 && g.dayCount >= q.global.perDay) {
    return quotaDeny('global_day', q.global.perDay);
  }
  if (q.global.tokensPerDay > 0 && g.tokensDay >= q.global.tokensPerDay) {
    return quotaDeny('global_tokens_day', q.global.tokensPerDay);
  }

  d.hourCount++;
  d.dayCount++;
  ipEntryValue.hourCount++;
  ipEntryValue.dayCount++;
  g.dayCount++;
  return { ok: true };
}

function addTokens(kind, installId, tokens) {
  if (!Number.isFinite(tokens) || tokens <= 0) return;
  const d = deviceEntry(installId);
  d.tokensDay += Math.floor(tokens);
  const g = globalEntry();
  g.tokensDay += Math.floor(tokens);
}

function quotaMessage(deny) {
  const map = {
    device_hour: `本设备每小时免费额度已用完（${deny.limit} 次），请稍后再试。`,
    device_day: `本设备今日免费额度已用完（${deny.limit} 次），明天再来，或在「小Q设置 → 模型」里添加自己的模型。`,
    tokens_day: `本设备今日免费 tokens 已用完，明天再来，或添加自己的模型。`,
    ip_hour: `当前网络请求过于频繁，请稍后再试。`,
    ip_day: `当前网络今日免费额度已用完，请明天再来。`,
    global_day: `今日免费额度已全部用完，请明天再来。`,
    global_tokens_day: `今日免费 tokens 已全部用完，请明天再来。`,
    image_day: `本设备今日免费生图额度已用完（${deny.limit} 张），明天再来。`,
  };
  return map[deny.reason] || '免费额度已用完，请稍后再试。';
}

// ── HTTP 工具 ────────────────────────────────────────────────

function corsHeaders(origin) {
  return {
    'Access-Control-Allow-Origin': origin || '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers':
      'Authorization, Content-Type, Accept, X-QNote-Install, X-QNote-Client, X-QNote-Timestamp, X-QNote-Sign',
    'Access-Control-Expose-Headers':
      'X-QNote-Quota-Hour-Limit, X-QNote-Quota-Hour-Remaining, X-QNote-Quota-Day-Limit, X-QNote-Quota-Day-Remaining, X-QNote-Token-Day-Remaining',
    'Access-Control-Max-Age': '86400',
    Vary: 'Origin',
  };
}

function sendJson(res, status, payload, extraHeaders = {}) {
  if (res.headersSent) return;
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.end(body);
}

function apiError(res, status, code, message, extraHeaders = {}) {
  sendJson(
    res,
    status,
    { error: { message, type: 'qnote_error', code } },
    extraHeaders,
  );
}

function clientIp(req) {
  // Cloudflare 会覆盖写入 cf-connecting-ip，比可伪造的 x-forwarded-for 更可信
  const cf = String(req.headers['cf-connecting-ip'] || '').trim();
  if (cf) return cf;
  const forwarded = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim();
  return forwarded || req.socket.remoteAddress || 'unknown';
}

function safeEqual(a, b) {
  const bufA = Buffer.from(String(a));
  const bufB = Buffer.from(String(b));
  if (bufA.length !== bufB.length) return false;
  return crypto.timingSafeEqual(bufA, bufB);
}

function verifyAppRequest(req, pathName) {
  const installId = String(req.headers['x-qnote-install'] || '').trim();
  if (!cfg.requireSignature) {
    return { ok: true, installId: installId || 'anonymous' };
  }
  if (!/^[A-Za-z0-9._-]{8,64}$/.test(installId)) {
    return { ok: false, reason: 'install' };
  }
  const timestamp = String(req.headers['x-qnote-timestamp'] || '').trim();
  const signature = String(req.headers['x-qnote-sign'] || '').trim();
  const seconds = Number(timestamp);
  if (!Number.isFinite(seconds) || Math.abs(Date.now() / 1000 - seconds) > 300) {
    return { ok: false, reason: 'timestamp' };
  }
  if (cfg.appSecrets.length === 0) {
    return { ok: false, reason: 'no_secret' };
  }
  const payload = `${installId}\n${timestamp}\n${pathName}`;
  for (const secret of cfg.appSecrets) {
    const expected = crypto.createHmac('sha256', secret).update(payload).digest('hex');
    if (safeEqual(signature, expected)) {
      return { ok: true, installId };
    }
  }
  return { ok: false, reason: 'signature' };
}

function readJsonBody(req, res) {
  return new Promise((resolve) => {
    let done = false;
    let size = 0;
    const chunks = [];
    req.on('data', (chunk) => {
      if (done) return;
      size += chunk.length;
      if (size > cfg.quotas.maxBodyBytes) {
        done = true;
        apiError(res, 413, 'qnote_body_too_large', '请求体过大');
        req.destroy();
        resolve(null);
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (done) return;
      done = true;
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        apiError(res, 400, 'qnote_bad_json', '请求体不是合法 JSON');
        resolve(null);
      }
    });
    req.on('error', () => {
      if (!done) {
        done = true;
        resolve(null);
      }
    });
  });
}

// ── 上游转发 ────────────────────────────────────────────────

function upstreamHeaders(req) {
  const headers = {};
  const pass = ['accept', 'accept-language', 'user-agent', 'x-forwarded-for', 'cf-connecting-ip'];
  for (const name of pass) {
    if (req.headers[name]) headers[name] = req.headers[name];
  }
  headers['content-type'] = 'application/json';
  headers.host = new URL(cfg.upstream).host;
  // 客户端自带的 Authorization 一律丢弃，只发 magpie 自己的网关 Key
  headers.authorization = `Bearer ${MAGPIE_KEY}`;
  return headers;
}

function mapUpstreamError(status) {
  if (status === 429) {
    return { status: 429, code: 'qnote_upstream_rate_limited', message: '内置服务当前较忙，请稍后再试。' };
  }
  if (status === 401 || status === 403) {
    return { status: 502, code: 'qnote_upstream_auth', message: '内置服务凭证失效，请联系维护者。' };
  }
  if (status === 408 || status === 504) {
    return { status: 504, code: 'qnote_upstream_timeout', message: '内置服务响应超时，请稍后再试。' };
  }
  if (status === 400 || status === 422) {
    return { status: 400, code: 'qnote_bad_request', message: '请求参数不被内置服务支持。' };
  }
  return { status: 503, code: 'qnote_upstream_error', message: '内置服务暂时不可用，请稍后再试。' };
}

function estimateTokens(text) {
  return Math.max(1, Math.ceil(String(text || '').length / 4));
}

function usageTokens(usage) {
  if (!usage || typeof usage !== 'object') return 0;
  const total = Number(usage.total_tokens);
  if (Number.isFinite(total) && total > 0) return total;
  const prompt = Number(usage.prompt_tokens) || 0;
  const completion = Number(usage.completion_tokens) || 0;
  return prompt + completion;
}

function logUsage(entry) {
  try {
    fs.appendFileSync(cfg.logFile, `${JSON.stringify(entry)}\n`);
  } catch (e) {
    warn(`写入用量日志失败：${e.message}`);
  }
}

function finishUsage({ kind, installId, ip, pathName, model, startedAt, usage, fallbackTokens, ok, status }) {
  const tokens = usageTokens(usage) || fallbackTokens || 0;
  addTokens(kind, installId, tokens);
  const entry = {
    ts: new Date().toISOString(),
    kind,
    install: sha256(installId).slice(0, 16),
    ip: sha256(ip).slice(0, 16),
    path: pathName,
    model,
    tokens,
    estimated: usageTokens(usage) === 0,
    status,
    ok,
    latencyMs: Date.now() - startedAt,
  };
  logUsage(entry);
  log(
    `${kind} ${model} status=${status} tokens=${tokens}${entry.estimated ? '(est)' : ''} ${entry.latencyMs}ms install=${entry.install}`,
  );
}

// ── 模型列表 ────────────────────────────────────────────────

function enabledModels() {
  return Object.entries(cfg.models)
    .filter(([, model]) => model && model.enabled !== false)
    .map(([id, model]) => ({
      id,
      object: 'model',
      created: 0,
      owned_by: 'qnote',
      name: model.displayName || id,
      display_name: model.displayName || id,
      type: model.type || 'chat',
      context_length: model.contextWindow ?? null,
      modalities: {
        input: model.vision ? ['text', 'image'] : ['text'],
        output: model.type === 'image' ? ['image'] : ['text'],
      },
    }));
}

// ── SSE 脱敏 ────────────────────────────────────────────────

function rewriteSseLine(line, publicModel, onData) {
  if (!line.startsWith('data:')) return line;
  const payload = line.slice(5).trim();
  if (!payload) return line;
  if (payload === '[DONE]') return line;
  let obj;
  try {
    obj = JSON.parse(payload);
  } catch {
    return line;
  }
  if (obj && typeof obj === 'object') {
    if (typeof obj.model === 'string') obj.model = publicModel;
    const choice = Array.isArray(obj.choices) ? obj.choices[0] : null;
    const content = choice && choice.delta && typeof choice.delta.content === 'string' ? choice.delta.content : '';
    onData(obj.usage || null, content.length);
  }
  return `data: ${JSON.stringify(obj)}`;
}

// ── 业务处理 ────────────────────────────────────────────────

async function handleChat(req, res, ctx, startedAt) {
  if (cfg.maintenance.enabled) {
    return apiError(res, 503, 'qnote_maintenance', cfg.maintenance.message || '内置服务维护中，请稍后再试。');
  }
  const body = await readJsonBody(req, res);
  if (!body) return;

  const requestedModel = typeof body.model === 'string' ? body.model : '';
  const model = cfg.models[requestedModel];
  if (!model || model.type !== 'chat' || model.enabled === false) {
    return apiError(res, 400, 'qnote_unknown_model', '未知的内置模型，请更新 App 或稍后再试。');
  }

  const quota = reserve('chat', ctx.installId, ctx.ip);
  if (!quota.ok) {
    return apiError(res, 429, 'qnote_quota_exceeded', quotaMessage(quota), {
      'Retry-After': '3600',
      ...corsHeaders(ctx.origin),
    });
  }

  const maxTokens = cfg.quotas.maxTokensPerRequest;
  if (maxTokens > 0) {
    if (Number.isFinite(body.max_tokens) && body.max_tokens > maxTokens) body.max_tokens = maxTokens;
    if (Number.isFinite(body.max_completion_tokens) && body.max_completion_tokens > maxTokens) {
      body.max_completion_tokens = maxTokens;
    }
  }
  body.n = 1;
  body.model = model.upstream;
  const wantStream = body.stream === true;
  const requestText = JSON.stringify(body);

  const controller = new AbortController();
  const onClose = () => {
    if (!res.writableEnded) controller.abort();
  };
  res.on('close', onClose);

  let upstreamRes;
  try {
    upstreamRes = await fetch(`${cfg.upstream}${CHAT_PATH}`, {
      method: 'POST',
      headers: upstreamHeaders(req),
      body: requestText,
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(cfg.upstreamTimeoutMs)]),
    });
  } catch (e) {
    warn(`上游连接失败：${e.message}`);
    return apiError(res, 503, 'qnote_upstream_error', '内置服务暂时不可用，请稍后再试。');
  }

  if (upstreamRes.status !== 200) {
    const detail = await upstreamRes.text().catch(() => '');
    warn(`上游拒绝：status=${upstreamRes.status} body=${detail.slice(0, 300)}`);
    finishUsage({
      kind: 'chat',
      installId: ctx.installId,
      ip: ctx.ip,
      pathName: CHAT_PATH,
      model: requestedModel,
      startedAt,
      usage: null,
      fallbackTokens: estimateTokens(requestText),
      ok: false,
      status: upstreamRes.status,
    });
    const mapped = mapUpstreamError(upstreamRes.status);
    return apiError(res, mapped.status, mapped.code, mapped.message);
  }

  const quotaOut = quotaHeaders('chat', ctx.installId);

  if (wantStream) {
    if (!res.headersSent) {
      res.writeHead(200, {
        ...corsHeaders(ctx.origin),
        ...quotaOut,
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no',
      });
    }
    let buffer = '';
    let usage = null;
    let contentChars = 0;
    try {
      for await (const chunk of upstreamRes.body) {
        buffer += Buffer.from(chunk).toString('utf8');
        let index;
        while ((index = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, index).replace(/\r$/, '');
          buffer = buffer.slice(index + 1);
          const rewritten = rewriteSseLine(line, requestedModel, (chunkUsage, chars) => {
            if (chunkUsage) usage = chunkUsage;
            contentChars += chars;
          });
          if (rewritten !== null) res.write(`${rewritten}\n`);
        }
      }
      if (buffer) {
        const rewritten = rewriteSseLine(buffer, requestedModel, (chunkUsage, chars) => {
          if (chunkUsage) usage = chunkUsage;
          contentChars += chars;
        });
        if (rewritten !== null) res.write(rewritten);
      }
    } catch (e) {
      warn(`流式转发中断：${e.message}`);
    } finally {
      res.end();
      res.removeListener('close', onClose);
      finishUsage({
        kind: 'chat',
        installId: ctx.installId,
        ip: ctx.ip,
        pathName: CHAT_PATH,
        model: requestedModel,
        startedAt,
        usage,
        fallbackTokens: estimateTokens(requestText) + Math.ceil(contentChars / 4),
        ok: true,
        status: 200,
      });
    }
    return;
  }

  const text = await upstreamRes.text();
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = null;
  }
  if (parsed && typeof parsed === 'object' && typeof parsed.model === 'string') {
    parsed.model = requestedModel;
  }
  const output = parsed ? JSON.stringify(parsed) : text;
  if (!res.headersSent) {
    res.writeHead(200, {
      ...corsHeaders(ctx.origin),
      ...quotaOut,
      'Content-Type': 'application/json; charset=utf-8',
    });
  }
  res.end(output);
  res.removeListener('close', onClose);
  finishUsage({
    kind: 'chat',
    installId: ctx.installId,
    ip: ctx.ip,
    pathName: CHAT_PATH,
    model: requestedModel,
    startedAt,
    usage: parsed && parsed.usage ? parsed.usage : null,
    fallbackTokens: estimateTokens(requestText) + estimateTokens(text),
    ok: true,
    status: 200,
  });
}

async function handleImage(req, res, ctx, startedAt) {
  if (cfg.maintenance.enabled) {
    return apiError(res, 503, 'qnote_maintenance', cfg.maintenance.message || '内置服务维护中，请稍后再试。');
  }
  const body = await readJsonBody(req, res);
  if (!body) return;

  const requestedModel = typeof body.model === 'string' ? body.model : '';
  const model = cfg.models[requestedModel];
  if (!model || model.type !== 'image' || model.enabled === false) {
    return apiError(res, 404, 'qnote_unknown_model', '生图模型暂未开放。');
  }

  const quota = reserve('image', ctx.installId, ctx.ip);
  if (!quota.ok) {
    return apiError(res, 429, 'qnote_quota_exceeded', quotaMessage(quota), {
      'Retry-After': '3600',
      ...corsHeaders(ctx.origin),
    });
  }

  body.model = model.upstream;
  const requestText = JSON.stringify(body);
  let upstreamRes;
  try {
    upstreamRes = await fetch(`${cfg.upstream}${IMAGE_PATH}`, {
      method: 'POST',
      headers: upstreamHeaders(req),
      body: requestText,
      signal: AbortSignal.timeout(cfg.upstreamTimeoutMs),
    });
  } catch (e) {
    warn(`生图上游连接失败：${e.message}`);
    return apiError(res, 503, 'qnote_upstream_error', '生图服务暂时不可用，请稍后再试。');
  }

  if (upstreamRes.status !== 200) {
    const detail = await upstreamRes.text().catch(() => '');
    warn(`生图上游拒绝：status=${upstreamRes.status} body=${detail.slice(0, 300)}`);
    finishUsage({
      kind: 'image',
      installId: ctx.installId,
      ip: ctx.ip,
      pathName: IMAGE_PATH,
      model: requestedModel,
      startedAt,
      usage: null,
      fallbackTokens: 0,
      ok: false,
      status: upstreamRes.status,
    });
    const mapped = mapUpstreamError(upstreamRes.status);
    return apiError(res, mapped.status, mapped.code, mapped.message);
  }

  const text = await upstreamRes.text();
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = null;
  }
  if (parsed && typeof parsed === 'object' && typeof parsed.model === 'string') {
    parsed.model = requestedModel;
  }
  const output = parsed ? JSON.stringify(parsed) : text;
  if (!res.headersSent) {
    res.writeHead(200, {
      ...corsHeaders(ctx.origin),
      ...quotaHeaders('image', ctx.installId),
      'Content-Type': 'application/json; charset=utf-8',
    });
  }
  res.end(output);
  finishUsage({
    kind: 'image',
    installId: ctx.installId,
    ip: ctx.ip,
    pathName: IMAGE_PATH,
    model: requestedModel,
    startedAt,
    usage: parsed && parsed.usage ? parsed.usage : null,
    fallbackTokens: estimateTokens(requestText),
    ok: true,
    status: 200,
  });
}

// ── 路由 ────────────────────────────────────────────────────

async function handle(req, res) {
  const startedAt = Date.now();
  const url = new URL(req.url, 'http://local');
  const pathName = url.pathname;
  const origin = req.headers.origin;

  if (req.method === 'OPTIONS') {
    res.writeHead(204, corsHeaders(origin));
    res.end();
    return;
  }

  if (pathName === '/health') {
    sendJson(
      res,
      200,
      {
        ok: true,
        service: 'qnote-builtin-gateway',
        version: GATEWAY_VERSION,
        enabled: !cfg.maintenance.enabled,
        maintenance: cfg.maintenance,
        models: Object.keys(cfg.models).filter((id) => cfg.models[id].enabled !== false),
        uptimeSeconds: Math.floor(process.uptime()),
      },
      corsHeaders(origin),
    );
    return;
  }

  const auth = verifyAppRequest(req, pathName);
  if (!auth.ok) {
    apiError(res, 401, 'qnote_unauthorized', '内置服务鉴权失败，请更新 App 或稍后再试。', corsHeaders(origin));
    return;
  }
  const ip = clientIp(req);
  // 未要求签名时没有安装 ID，用 IP 兜底，避免所有匿名请求共用同一个设备桶
  const installId = !auth.installId || auth.installId === 'anonymous' ? `ip:${ip}` : auth.installId;
  const ctx = { installId, ip, origin };

  if (pathName === MODELS_PATH && req.method === 'GET') {
    sendJson(res, 200, { object: 'list', data: enabledModels() }, {
      ...corsHeaders(origin),
      ...quotaHeaders('chat', ctx.installId),
    });
    return;
  }

  if (pathName === CHAT_PATH && req.method === 'POST') {
    return handleChat(req, res, ctx, startedAt);
  }

  if (pathName === IMAGE_PATH && req.method === 'POST') {
    return handleImage(req, res, ctx, startedAt);
  }

  apiError(res, 404, 'qnote_not_found', '接口不存在。', corsHeaders(origin));
}

// ── 启动 ────────────────────────────────────────────────────

const [listenHost, listenPortText] = cfg.listen.split(':');
const listenPort = Number(listenPortText);
if (!listenHost || !Number.isFinite(listenPort)) {
  die(`listen 配置无效：${cfg.listen}`);
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    warn(`未捕获错误：${e.stack || e.message}`);
    if (!res.headersSent) {
      apiError(res, 500, 'qnote_gateway_error', '网关内部错误。');
    } else {
      res.end();
    }
  });
});
server.keepAliveTimeout = 65000;
server.headersTimeout = 66000;
server.requestTimeout = 0;

let persistTimer = setInterval(saveState, 30000);
persistTimer.unref?.();

server.listen(listenPort, listenHost, () => {
  log(`gateway ${GATEWAY_VERSION} listening on ${cfg.listen} → ${cfg.upstream}`);
  log(`models: ${Object.entries(cfg.models).map(([id, m]) => `${id}→${m.upstream}${m.enabled === false ? '(off)' : ''}`).join(', ')}`);
  log(`quota: device ${cfg.quotas.device.perHour}/h ${cfg.quotas.device.perDay}/d ${cfg.quotas.device.tokensPerDay} tokens/d`);
  if (cfg.requireSignature && cfg.appSecrets.length === 0) {
    warn('requireSignature=true 但 appSecrets 为空：所有请求都会被 401');
  }
  if (!cfg.requireSignature) {
    warn('requireSignature=false：仅靠配额控制，适合内测');
  }
});

function shutdown(signal) {
  log(`收到 ${signal}，保存状态并退出`);
  try {
    clearInterval(persistTimer);
    saveState();
  } finally {
    process.exit(0);
  }
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGHUP', () => {
  log('收到 SIGHUP，重新加载配置');
  try {
    cfg = loadConfig();
    MAGPIE_KEY = readMagpieKey();
    log('配置已重新加载');
  } catch (e) {
    warn(`重新加载失败：${e.message}`);
  }
});