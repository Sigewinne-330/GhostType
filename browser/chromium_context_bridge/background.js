const HOST_NAME = "com.codeandchill.ghosttype.context";
const MIN_PUSH_INTERVAL_MS = 1200;

const BROWSER_IDENTITIES = {
  chrome: {
    browser: "chrome",
    bundleId: "com.google.Chrome",
  },
  edge: {
    browser: "edge",
    bundleId: "com.microsoft.edgemac",
  },
  arc: {
    browser: "arc",
    bundleId: "company.thebrowser.Browser",
  },
};

function detectBrowserIdentity() {
  const ua = (navigator.userAgent || "").toLowerCase();
  if (ua.includes("edg/")) {
    return BROWSER_IDENTITIES.edge;
  }
  if (ua.includes("arc/")) {
    return BROWSER_IDENTITIES.arc;
  }
  return BROWSER_IDENTITIES.chrome;
}

const RUNTIME_BROWSER_IDENTITY = detectBrowserIdentity();

let nativePort = null;
let reconnectTimer = null;
let lastSent = {
  domain: "",
  at: 0,
};

function log(...args) {
  console.debug("[GhostTypeContextBridge]", ...args);
}

function extractDomain(url) {
  if (!url || typeof url !== "string") {
    return "";
  }
  try {
    const parsed = new URL(url);
    return (parsed.hostname || "").trim().toLowerCase();
  } catch (_err) {
    return "";
  }
}

async function getActiveTab() {
  const tabs = await chrome.tabs.query({
    active: true,
    lastFocusedWindow: true,
  });
  return tabs.length > 0 ? tabs[0] : null;
}

function buildPayload(tab) {
  if (!tab) {
    return null;
  }

  const url = typeof tab.url === "string" ? tab.url : "";
  const domain = extractDomain(url);
  if (!domain) {
    return null;
  }

  return {
    type: "active_tab",
    browser: RUNTIME_BROWSER_IDENTITY.browser,
    bundleId: RUNTIME_BROWSER_IDENTITY.bundleId,
    url,
    domain,
    title: typeof tab.title === "string" ? tab.title : "",
    tabId: tab.id,
    timestamp: new Date().toISOString(),
  };
}

function shouldSend(payload) {
  const now = Date.now();
  if (payload.domain === lastSent.domain && now - lastSent.at < MIN_PUSH_INTERVAL_MS) {
    return false;
  }
  return true;
}

function markSent(payload) {
  lastSent = {
    domain: payload.domain,
    at: Date.now(),
  };
}

function disconnectNativePort() {
  if (nativePort) {
    try {
      nativePort.disconnect();
    } catch (_err) {
      // ignored
    }
  }
  nativePort = null;
}

function scheduleReconnect(delayMs = 1200) {
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
  }
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    ensureNativePort();
  }, delayMs);
}

function ensureNativePort() {
  if (nativePort) {
    return nativePort;
  }

  try {
    nativePort = chrome.runtime.connectNative(HOST_NAME);
  } catch (err) {
    log("connectNative failed:", err);
    nativePort = null;
    scheduleReconnect(2000);
    return null;
  }

  nativePort.onMessage.addListener((message) => {
    if (message && message.ok === false) {
      log("host error:", message.error || "unknown");
      return;
    }
    log("host ack:", message);
  });

  nativePort.onDisconnect.addListener(() => {
    const runtimeError = chrome.runtime.lastError;
    if (runtimeError) {
      log("native host disconnected:", runtimeError.message);
    } else {
      log("native host disconnected");
    }
    nativePort = null;
    scheduleReconnect(1800);
  });

  return nativePort;
}

async function pushActiveTabContext(reason) {
  let tab;
  try {
    tab = await getActiveTab();
  } catch (err) {
    log("getActiveTab failed:", err);
    return;
  }

  const payload = buildPayload(tab);
  if (!payload) {
    return;
  }

  if (!shouldSend(payload)) {
    return;
  }

  const port = ensureNativePort();
  if (!port) {
    return;
  }

  try {
    port.postMessage(payload);
    markSent(payload);
    log(`context pushed (${reason}):`, payload.domain);
  } catch (err) {
    log("postMessage failed:", err);
    disconnectNativePort();
    scheduleReconnect(1800);
  }
}

function schedulePush(reason, delayMs = 160) {
  setTimeout(() => {
    pushActiveTabContext(reason);
  }, delayMs);
}

chrome.runtime.onInstalled.addListener(() => {
  ensureNativePort();
  chrome.alarms.create("ghosttype-context-sync", { periodInMinutes: 1 });
  schedulePush("installed", 600);
});

chrome.runtime.onStartup.addListener(() => {
  ensureNativePort();
  schedulePush("startup", 600);
});

chrome.action.onClicked.addListener(() => {
  pushActiveTabContext("action");
});

chrome.tabs.onActivated.addListener(() => {
  schedulePush("tab_activated", 120);
});

chrome.tabs.onUpdated.addListener((_tabId, changeInfo, tab) => {
  if (!tab.active) {
    return;
  }
  if (changeInfo.status === "complete" || typeof changeInfo.url === "string") {
    schedulePush("tab_updated", 220);
  }
});

chrome.windows.onFocusChanged.addListener((windowId) => {
  if (windowId !== chrome.windows.WINDOW_ID_NONE) {
    schedulePush("window_focus", 220);
  }
});

chrome.commands.onCommand.addListener((command) => {
  if (command === "push-context") {
    pushActiveTabContext("command");
  }
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "ghosttype-context-sync") {
    pushActiveTabContext("alarm");
  }
});

ensureNativePort();
schedulePush("boot", 900);
