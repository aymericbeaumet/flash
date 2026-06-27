"use strict";

(() => {
  if (window.__flashFixtureCollectorInstalled) {
    return;
  }
  window.__flashFixtureCollectorInstalled = true;

  const URL_ATTRIBUTES = new Set([
    "action",
    "cite",
    "data",
    "formaction",
    "href",
    "poster",
    "src"
  ]);

  const SECRET_ATTRIBUTE = /(?:token|secret|password|passwd|pwd|session|cookie|csrf|xsrf|auth|jwt|bearer|credential|api[-_]?key|access[-_]?key|private[-_]?key)/i;

  function sanitizeURL(raw) {
    if (!raw || raw.startsWith("#") || raw.startsWith("mailto:") || raw.startsWith("tel:")) {
      return raw || "";
    }
    try {
      const parsed = new URL(raw, document.baseURI);
      parsed.username = "";
      parsed.password = "";
      parsed.search = "";
      parsed.hash = "";
      if (parsed.origin === window.location.origin) {
        return parsed.pathname;
      }
      return parsed.toString();
    } catch (_) {
      return "";
    }
  }

  function sanitizeText(value) {
    return value
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[redacted-email]")
      .replace(/\b(?:bearer|basic)\s+[a-z0-9._~+/-]+=*/gi, "[redacted-token]")
      .replace(/\b[a-z0-9._~+/-]{32,}={0,2}\b/gi, "[redacted-token]");
  }

  function sanitizeElement(element) {
    for (const attr of Array.from(element.attributes || [])) {
      const name = attr.name;
      if (/^on/i.test(name) || name === "nonce" || name === "integrity") {
        element.removeAttribute(name);
        continue;
      }
      if (SECRET_ATTRIBUTE.test(name)) {
        element.setAttribute(name, "[redacted]");
        continue;
      }
      if (URL_ATTRIBUTES.has(name)) {
        element.setAttribute(name, sanitizeURL(attr.value));
        continue;
      }
      if (name === "srcset") {
        element.removeAttribute(name);
      }
    }

    const tag = element.localName;
    if (tag === "input") {
      const type = (element.getAttribute("type") || "text").toLowerCase();
      if (type === "hidden" || SECRET_ATTRIBUTE.test(element.getAttribute("name") || "")) {
        element.setAttribute("value", "[redacted]");
      } else if (!["checkbox", "radio", "button", "submit", "reset"].includes(type)) {
        element.removeAttribute("value");
      }
    } else if (tag === "textarea") {
      element.textContent = "";
    } else if (tag === "option") {
      element.removeAttribute("value");
    } else if (tag === "meta") {
      const key = `${element.getAttribute("name") || ""} ${element.getAttribute("property") || ""}`;
      if (SECRET_ATTRIBUTE.test(key)) {
        element.setAttribute("content", "[redacted]");
      }
    }
  }

  function sanitizeTree(root) {
    for (const node of Array.from(root.querySelectorAll("script, object, embed"))) {
      node.remove();
    }
    for (const element of Array.from(root.querySelectorAll("*"))) {
      sanitizeElement(element);
    }
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const textNodes = [];
    while (walker.nextNode()) {
      textNodes.push(walker.currentNode);
    }
    for (const node of textNodes) {
      node.nodeValue = sanitizeText(node.nodeValue || "");
    }
  }

  browser.runtime.onMessage.addListener((message) => {
    if (!message || message.type !== "flash.collectFixture") {
      return undefined;
    }
    const clone = document.documentElement.cloneNode(true);
    sanitizeTree(clone);
    const doctype = document.doctype
      ? `<!doctype ${document.doctype.name}>`
      : "<!doctype html>";
    return Promise.resolve({
      title: sanitizeText(document.title || window.location.hostname || "captured-page"),
      url: sanitizeURL(window.location.href),
      html: `${doctype}\n${clone.outerHTML}\n`
    });
  });
})();
