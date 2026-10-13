// Pushes the monitors, home page and site settings in monitors.json to Kener
// through its v4 API, so git stays the source of truth. Monitors that are not
// in monitors.json (including Kener's seeded demo monitors) are deleted.
import { readFileSync } from "node:fs";

const baseURL = process.env.KENER_URL;
const apiKey = process.env.KENER_API_KEY;
const config = JSON.parse(readFileSync(process.env.SYNC_CONFIG, "utf8"));

if (!apiKey) {
  console.log("KENER_API_KEY is not set; create one in Kener and add it to kener-secrets. Nothing synced.");
  process.exit(0);
}

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

// The home page lists exactly the monitors in monitors.json, in that order.
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
