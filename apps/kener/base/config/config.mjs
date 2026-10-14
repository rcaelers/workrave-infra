// Configures Kener from git, so nobody has to log in to set it up. Runs next
// to Kener in the same pod; the pod only turns ready (and only then receives
// traffic) once this has finished.
//
// 1. Writes straight into Kener's database what its API cannot do:
//    - a placeholder owner that cannot log in, which closes Kener's "first
//      visitor becomes admin" signup,
//    - an API key for step 2, regenerated on every start,
//    - the mapping from the Pocket ID admin group to Kener's admin role.
// 2. Pushes monitors, the home page and site settings (including Pocket ID
//    login) from kener.json through Kener's v4 API. Monitors that are not in
//    kener.json, such as Kener's seeded demo monitors, are deleted.
import { createRequire } from "node:module";
import { createHmac, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";

const require = createRequire("/app/package.json");
const Database = require("better-sqlite3");

const config = JSON.parse(readFileSync(process.env.KENER_CONFIG, "utf8"));
const baseURL = "http://127.0.0.1:3000";
const dbPath = "/app/database/kener.sqlite.db";
const apiKeyName = "kener-config";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Kener migrates and seeds its database after it starts listening; wait for
// the last of it (the roles seed) before touching anything.
async function openDatabase() {
  for (let attempt = 0; attempt < 120; attempt++) {
    try {
      const db = new Database(dbPath, { fileMustExist: true, timeout: 10000 });
      const ready =
        db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'oidc_group_role_mappings'").get() &&
        db.prepare("SELECT 1 FROM roles WHERE id = 'admin'").get() &&
        db.prepare("SELECT 1 FROM site_data LIMIT 1").get();
      if (ready) return db;
      db.close();
    } catch {
      // Database file or tables not there yet.
    }
    await sleep(2000);
  }
  throw new Error("Kener did not finish migrating its database in time");
}

function bootstrapDatabase(db) {
  const apiKey = randomBytes(32).toString("hex");
  const hashedKey = createHmac("sha256", process.env.KENER_SECRET_KEY).update(apiKey).digest("hex");
  const { owner, oidc } = config.bootstrap;

  db.transaction(() => {
    if (!db.prepare("SELECT 1 FROM users LIMIT 1").get()) {
      // An empty password hash never matches, and local login is off anyway.
      const { lastInsertRowid } = db
        .prepare(
          `INSERT INTO users (email, name, password_hash, is_active, is_verified, is_owner, auth_provider)
           VALUES (?, ?, '', 1, 1, 'YES', 'local')`,
        )
        .run(owner.email, owner.name);
      db.prepare("INSERT INTO users_roles (users_id, roles_id) VALUES (?, 'admin')").run(lastInsertRowid);
      console.log(`created placeholder owner ${owner.email}`);
    }

    db.prepare("DELETE FROM api_keys WHERE name = ?").run(apiKeyName);
    db.prepare("INSERT INTO api_keys (name, hashed_key, masked_key, status) VALUES (?, ?, ?, 'ACTIVE')").run(
      apiKeyName,
      hashedKey,
      `${apiKey.slice(0, 4)}...${apiKey.slice(-4)}`,
    );

    db.prepare("DELETE FROM oidc_group_role_mappings WHERE oidc_group = ?").run(oidc.admin_group);
    db.prepare("INSERT INTO oidc_group_role_mappings (oidc_group, role_id) VALUES (?, 'admin')").run(
      oidc.admin_group,
    );
  })();
  console.log("bootstrapped database");
  return apiKey;
}

async function waitForKener() {
  for (let attempt = 0; attempt < 120; attempt++) {
    try {
      if ((await fetch(`${baseURL}/healthcheck`)).ok) return;
    } catch {
      // Not listening yet.
    }
    await sleep(2000);
  }
  throw new Error("Kener did not become healthy in time");
}

// "expect" is a list of accepted status codes, or "<400" for any 2xx/3xx.
function evalFor(expect) {
  const condition =
    expect === "<400" ? "statusCode >= 200 && statusCode < 400" : `${JSON.stringify(expect)}.includes(statusCode)`;
  return `(async function (statusCode, responseTime, responseRaw, modules) {
  return { status: (${condition}) ? "UP" : "DOWN", latency: responseTime };
})`;
}

function monitorBody(m) {
  const body = {
    name: m.name,
    category_name: m.group,
    cron: "* * * * *",
    default_status: "UP",
    status: "ACTIVE",
    is_hidden: "NO",
    include_degraded_in_downtime: "NO",
    monitor_settings_json: {
      uptime_formula_numerator: "up + maintenance",
      uptime_formula_denominator: "up + maintenance + down + degraded",
    },
  };
  if (m.tcp) {
    body.monitor_type = "TCP";
    body.type_data = { hosts: [{ type: "IP4", host: m.tcp.host, port: m.tcp.port, timeout: 5000 }] };
  } else {
    body.monitor_type = "API";
    body.type_data = {
      url: m.url,
      method: "GET",
      headers: [],
      body: "",
      timeout: 10000,
      allowSelfSignedCert: false,
      eval: evalFor(m.expect),
    };
  }
  return body;
}

async function sync(apiKey) {
  async function api(method, path, body) {
    const res = await fetch(`${baseURL}/api/v4${path}`, {
      method,
      headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) {
      throw new Error(`${method} ${path}: HTTP ${res.status}: ${text}`);
    }
    return text ? JSON.parse(text) : {};
  }

  const wanted = config.monitors.map((m) => m.tag);
  const existing = new Set((await api("GET", "/monitors")).monitors.map((m) => m.tag));

  for (const m of config.monitors) {
    if (existing.has(m.tag)) {
      await api("PATCH", `/monitors/${m.tag}`, monitorBody(m));
      console.log(`updated monitor ${m.tag}`);
    } else {
      await api("POST", "/monitors", { tag: m.tag, ...monitorBody(m) });
      console.log(`created monitor ${m.tag}`);
    }
  }

  // The home page lists exactly the monitors in kener.json, in that order.
  const home = config.home;
  await api("PATCH", "/pages/~home", {
    page_title: home.page_title,
    page_header: home.page_header,
    page_subheader: home.page_subheader,
    monitors: wanted,
    page_settings: {
      monitor_status_history_days: { desktop: home.history_days, mobile: home.history_days },
    },
  });
  console.log("updated home page");

  for (const tag of existing) {
    if (!wanted.includes(tag)) {
      await api("DELETE", `/monitors/${tag}`);
      console.log(`deleted monitor ${tag}`);
    }
  }

  for (const [key, value] of Object.entries(config.site)) {
    await api("PATCH", `/site/${key}`, { value });
  }
  console.log("updated site settings");

  // Pocket ID login. Until the Pocket ID setup job has stored the client
  // secret, Kener has no login at all; the status page works regardless.
  const { oidc } = config.bootstrap;
  const clientSecret = process.env.KENER_OIDC_CLIENT_SECRET;
  if (clientSecret) {
    await api("PATCH", "/site/oidcSettings", {
      value: {
        enabled: true,
        provider_name: oidc.provider_name,
        issuer_url: oidc.issuer_url,
        client_id: oidc.client_id,
        client_secret: clientSecret,
        scopes: "openid profile email groups",
        groups_claim: "groups",
        allow_local_login: false,
        auto_create_users: true,
        // Pocket ID only lets the admin group use this client; anyone else
        // who somehow gets through can only read.
        default_role_id: "member",
      },
    });
    console.log("configured Pocket ID login");
  } else {
    console.log("KENER_OIDC_CLIENT_SECRET is not set yet; Pocket ID login not configured");
  }
}

const db = await openDatabase();
const apiKey = bootstrapDatabase(db);
db.close();
await waitForKener();
await sync(apiKey);

writeFileSync("/tmp/ready", "");
console.log("Kener is configured");
// Stay up so the pod stays ready; a config change rolls the pod and reruns this.
setInterval(() => {}, 1 << 30);
