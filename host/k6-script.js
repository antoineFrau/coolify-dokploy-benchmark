// §11 load generator. Runs on the host (never inside the VM under test) so the
// VM's CPU is spent serving, not generating.
import http from "k6/http";
import { check } from "k6";

export const options = {
  vus: Number(__ENV.CONNS || 50),
  duration: __ENV.DURATION || "60s",
  // The protocol compares platforms, not SLOs, so no thresholds abort the run.
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
  discardResponseBodies: true,
};

export default function () {
  const res = http.get(__ENV.TARGET);
  check(res, { "status 200": (r) => r.status === 200 });
}

export function handleSummary(data) {
  const m = data.metrics;
  const d = m.http_req_duration ? m.http_req_duration.values : {};
  const compact = {
    target: __ENV.TARGET,
    vus: Number(__ENV.CONNS || 50),
    duration: __ENV.DURATION || "60s",
    requests: m.http_reqs ? m.http_reqs.values.count : 0,
    rps: m.http_reqs ? Number(m.http_reqs.values.rate.toFixed(2)) : 0,
    failed_ratio: m.http_req_failed ? m.http_req_failed.values.rate : null,
    latency_ms: {
      avg: d.avg, min: d.min, med: d.med,
      p90: d["p(90)"], p95: d["p(95)"], p99: d["p(99)"], max: d.max,
    },
  };
  return {
    "/out/summary.json": JSON.stringify(compact, null, 2),
    "/out/full.json": JSON.stringify(data),
    stdout: JSON.stringify(compact, null, 2) + "\n",
  };
}
