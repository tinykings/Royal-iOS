// No remote SDK: this module uses CloudKit Web Services from the extension worker.
export const PROBE = { recordName: "royal-sync-probe-v1", recordType: "RoyalSyncProbe" };

export class CloudKitError extends Error {
  constructor(code, redirectURL) {
    // Never propagate Apple's reason/response URL: these can contain credentials.
    const safeCode = /^[A-Z_]{1,60}$/.test(code) ? code : "REQUEST_FAILED";
    super(safeCode);
    this.code = safeCode;
    this.redirectURL = redirectURL;
  }
}

export function validateConfig({ container, apiToken, environment } = {}) {
  if (!/^iCloud\.[A-Za-z0-9.-]+$/.test(container ?? "")) throw new Error("Enter a CloudKit container starting with iCloud.");
  if (typeof apiToken !== "string" || !apiToken.trim() || apiToken.length > 4096) throw new Error("Enter the container's web API token.");
  if (!["development", "production"].includes(environment)) throw new Error("Choose a CloudKit environment.");
  return { container, apiToken: apiToken.trim(), environment };
}

export function appleSignInURL(value) {
  const url = new URL(value);
  const allowed = ["apple.com", "icloud.com", "apple-cloudkit.com"];
  if (url.protocol !== "https:" || url.username || url.password || url.port ||
      !allowed.some(host => url.hostname === host || url.hostname.endsWith(`.${host}`))) {
    throw new Error("CloudKit returned an unexpected sign-in address.");
  }
  return url.href;
}

export function callbackToken(value, expectedCallback) {
  const actual = new URL(value);
  const expected = new URL(expectedCallback);
  if (actual.origin !== expected.origin || actual.pathname !== expected.pathname) {
    throw new Error("Apple sign-in returned to an unexpected address.");
  }
  const tokens = actual.searchParams.getAll("ckWebAuthToken");
  if (tokens.length !== 1 || !tokens[0]) throw new Error("Apple sign-in did not return a CloudKit token.");
  return tokens[0];
}

export class CloudKitClient {
  constructor(config, { fetcher = fetch, getToken, setToken } = {}) {
    this.config = validateConfig(config);
    this.fetcher = fetcher;
    this.getToken = getToken;
    this.setToken = setToken;
  }

  async request(operation, body) {
    if (!["users/current", "records/lookup", "records/modify"].includes(operation)) throw new Error("Unsupported CloudKit operation.");
    const { container, environment, apiToken } = this.config;
    const url = new URL(`https://api.apple-cloudkit.com/database/1/${container}/${environment}/private/${operation}`);
    url.searchParams.set("ckAPIToken", apiToken);
    const token = await this.getToken();
    if (token) url.searchParams.set("ckWebAuthToken", token);
    let response;
    try {
      response = await this.fetcher(url.href, {
        method: body ? "POST" : "GET",
        headers: body ? { "Content-Type": "application/json" } : {},
        ...(body ? { body: JSON.stringify(body) } : {}),
        credentials: "omit", cache: "no-store", redirect: "error",
        signal: AbortSignal.timeout(20000),
      });
    } catch {
      throw new CloudKitError("NETWORK_ERROR");
    }
    let result;
    try { result = await response.json(); }
    catch { throw new CloudKitError("INVALID_RESPONSE"); }
    if (!result || typeof result !== "object" || Array.isArray(result)) throw new CloudKitError("INVALID_RESPONSE");
    // CloudKit can rotate this token. The worker serializes all operations.
    if (typeof result.ckWebAuthToken === "string" && result.ckWebAuthToken) await this.setToken(result.ckWebAuthToken);
    if (result.serverErrorCode) {
      if (["AUTHENTICATION_REQUIRED", "AUTHENTICATION_FAILED"].includes(result.serverErrorCode)) await this.setToken(null);
      throw new CloudKitError(result.serverErrorCode, result.redirectURL);
    }
    if (!response.ok) throw new CloudKitError("REQUEST_FAILED");
    return result;
  }

  async currentUser() {
    const user = await this.request("users/current");
    if (typeof user.userRecordName !== "string" || !user.userRecordName) throw new CloudKitError("INVALID_RESPONSE");
    return user.userRecordName;
  }

  async readProbe() {
    const result = await this.request("records/lookup", { records: [{ recordName: PROBE.recordName }] });
    const record = this.resultRecord(result);
    // Only a per-record NOT_FOUND means the probe is absent. Configuration errors
    // at the request level must not be turned into permission to create a record.
    if (record.serverErrorCode === "NOT_FOUND") return null;
    this.checkRecord(record);
    return record;
  }

  async writeProbe(message, previous) {
    if (typeof message !== "string" || !message.trim() || message.length > 500) throw new Error("Enter a message of 1–500 characters.");
    if (previous && (previous.recordName !== PROBE.recordName || !previous.recordChangeTag)) throw new CloudKitError("INVALID_RESPONSE");
    const record = {
      ...PROBE,
      ...(previous ? { recordChangeTag: previous.recordChangeTag } : {}),
      fields: {
        message: { value: message.trim(), type: "STRING" },
        writtenAt: { value: new Date().toISOString(), type: "STRING" },
      },
    };
    const result = await this.request("records/modify", {
      operations: [{ operationType: previous ? "update" : "create", record }],
    });
    const saved = this.resultRecord(result);
    this.checkRecord(saved);
    return saved;
  }

  resultRecord(result) {
    if (!Array.isArray(result.records) || result.records.length !== 1 || !result.records[0] ||
        result.records[0].recordName !== PROBE.recordName) throw new CloudKitError("INVALID_RESPONSE");
    return result.records[0];
  }

  checkRecord(record) {
    if (record.serverErrorCode) throw new CloudKitError(record.serverErrorCode);
    if (record.recordType !== PROBE.recordType || typeof record.recordChangeTag !== "string") throw new CloudKitError("INVALID_RESPONSE");
  }
}
