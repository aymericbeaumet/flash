"use strict";

const HOST = "com.flash.fixture_collector";

async function activeTab() {
  const tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs[0];
}

async function collect(tabId) {
  await browser.tabs.executeScript(tabId, { file: "content-script.js" });
  return browser.tabs.sendMessage(tabId, { type: "flash.collectFixture" });
}

browser.browserAction.onClicked.addListener(async () => {
  try {
    const tab = await activeTab();
    if (!tab || tab.id == null) {
      throw new Error("No active tab");
    }
    const page = await collect(tab.id);
    const result = await browser.runtime.sendNativeMessage(HOST, {
      type: "capture_page",
      page
    });
    if (!result || !result.ok) {
      throw new Error((result && result.error) || "Native host failed");
    }
    browser.browserAction.setBadgeBackgroundColor({ color: "#a3be8c", tabId: tab.id });
    browser.browserAction.setBadgeText({ text: "ok", tabId: tab.id });
    setTimeout(() => browser.browserAction.setBadgeText({ text: "", tabId: tab.id }), 1800);
  } catch (error) {
    const tab = await activeTab().catch(() => null);
    const details = error && error.message ? error.message : String(error);
    console.error("[flash-fixture-collector]", details);
    if (tab && tab.id != null) {
      browser.browserAction.setBadgeBackgroundColor({ color: "#bf616a", tabId: tab.id });
      browser.browserAction.setBadgeText({ text: "err", tabId: tab.id });
      setTimeout(() => browser.browserAction.setBadgeText({ text: "", tabId: tab.id }), 3000);
    }
  }
});
