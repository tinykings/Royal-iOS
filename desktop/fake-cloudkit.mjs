// Test-only in-memory CloudKit Web Services private database, at the HTTP JSON
// level used by CloudKitClient: users/caller, zones/modify, records/changes and
// conditional records/modify, with change tags and sync tokens.
// It is not loaded by the extension.
export function fakeCloudKit() {
  const users = new Map(); // webAuthToken -> userRecordName
  const zones = new Map(); // `${user}/${zone}` -> { records: Map, counter }
  let tagCounter = 0;
  const server = {
    offline: false,
    requests: [],
    signIn(token, user) { users.set(token, user); },
    deleteZone(user, zoneName) { zones.delete(`${user}/${zoneName}`); },
    records(user, zoneName = "RoyalSync") { return [...(zones.get(`${user}/${zoneName}`)?.records.values() ?? [])].filter(r => !r.deleted); },
  };
  const reply = (body, status = 200) => ({ ok: status < 400, status, json: async () => body });

  server.fetch = async (href, options = {}) => {
    if (server.offline) throw new TypeError("Failed to fetch");
    const url = new URL(href);
    const operation = url.pathname.split("/").slice(-2).join("/");
    const body = options.body ? JSON.parse(options.body) : null;
    server.requests.push({ operation, body });
    const user = users.get(url.searchParams.get("ckWebAuthToken"));
    if (!user) return reply({ serverErrorCode: "AUTHENTICATION_REQUIRED", redirectURL: "https://idmsa.apple.com/login" }, 421);
    if (operation === "users/caller") return reply({ users: [{ userRecordName: user }] });
    if (operation === "zones/modify") {
      return reply({ zones: body.operations.map(op => {
        const key = `${user}/${op.zone.zoneID.zoneName}`;
        if (!zones.has(key)) zones.set(key, { records: new Map(), counter: 0 });
        return { zoneID: op.zone.zoneID };
      }) });
    }
    const zone = zones.get(`${user}/${body?.zoneID?.zoneName}`);
    if (!zone) return reply({ serverErrorCode: "ZONE_NOT_FOUND" }, 404);
    if (operation === "records/changes") {
      const since = body.syncToken ? Number(body.syncToken.split(":")[1]) : 0;
      if (body.syncToken && !body.syncToken.startsWith(`${body.zoneID.zoneName}:`)) return reply({ serverErrorCode: "BAD_REQUEST" }, 400);
      const changed = [...zone.records.values()].filter(r => r.changedAt > since).sort((a, b) => a.changedAt - b.changedAt);
      const page = changed.slice(0, body.resultsLimit ?? 200);
      const last = page.at(-1)?.changedAt ?? since;
      return reply({
        records: page.map(({ changedAt, ...record }) => structuredClone(record)),
        syncToken: `${body.zoneID.zoneName}:${page.length < changed.length ? last : zone.counter}`,
        moreComing: page.length < changed.length,
      });
    }
    if (operation === "records/modify") {
      return reply({ records: body.operations.map(({ operationType, record }) => {
        const existing = zone.records.get(record.recordName);
        if (operationType === "create" && existing && !existing.deleted) return { recordName: record.recordName, serverErrorCode: "EXISTS" };
        if (operationType === "update" && (!existing || existing.recordChangeTag !== record.recordChangeTag)) return { recordName: record.recordName, serverErrorCode: existing ? "CONFLICT" : "NOT_FOUND" };
        if (!["create", "update"].includes(operationType)) return { recordName: record.recordName, serverErrorCode: "BAD_REQUEST" };
        const saved = { recordName: record.recordName, recordType: record.recordType, fields: structuredClone(record.fields), recordChangeTag: `tag${++tagCounter}`, changedAt: ++zone.counter };
        zone.records.set(record.recordName, saved);
        const { changedAt, ...result } = saved;
        return structuredClone(result);
      }) });
    }
    return reply({ serverErrorCode: "BAD_REQUEST" }, 400);
  };
  return server;
}
