const { app, BrowserWindow, ipcMain } = require("electron");
const fs = require("fs");
const path = require("path");

function argValue(name, fallback) {
  const index = process.argv.indexOf(name);
  if (index >= 0 && process.argv[index + 1]) return process.argv[index + 1];
  return fallback;
}

const expectedFile = argValue("--expected-file", path.join(app.getPath("temp"), "flash-electron-expected.json"));
const stateFile = argValue("--state-file", path.join(app.getPath("temp"), "flash-electron-state.json"));

const state = {
  primary: 0,
  toggle: 0
};

function writeState() {
  fs.mkdirSync(path.dirname(stateFile), { recursive: true });
  fs.writeFileSync(stateFile, JSON.stringify(state, null, 2));
}

function html() {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Flash Electron Fixture</title>
  <style>
    html, body {
      margin: 0;
      font: 15px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f8fafc;
      color: #172033;
    }
    main {
      padding: 28px;
      display: grid;
      gap: 18px;
      align-content: start;
    }
    button, input, select, a {
      font: inherit;
      width: max-content;
    }
    .row {
      display: flex;
      gap: 18px;
      align-items: center;
    }
    a {
      color: #075985;
    }
  </style>
</head>
<body>
  <main>
    <h1>Flash Electron Fixture</h1>
    <div class="row">
      <button data-flash-target="primary" data-role="AXButton" onclick="require('electron').ipcRenderer.send('fixture-state', 'primary')">Electron Primary</button>
      <button disabled>Electron Disabled</button>
      <a href="#electron-link" data-flash-target="link" data-role="AXLink">Electron Link</a>
    </div>
    <div class="row">
      <label>
        Electron Input
        <input aria-label="Electron Input" data-flash-target="input" data-role="AXTextField" value="">
      </label>
      <select aria-label="Electron Select" data-flash-target="select" data-role="AXPopUpButton">
        <option>First</option>
        <option>Second</option>
      </select>
    </div>
    <label>
      <input type="checkbox" aria-label="Electron Toggle" data-flash-target="toggle" data-role="AXCheckBox" onchange="require('electron').ipcRenderer.send('fixture-toggle', this.checked)">
      Electron Toggle
    </label>
  </main>
</body>
</html>`;
}

function collectExpectedTargets() {
  return Array.from(document.querySelectorAll("[data-flash-target]")).map((node) => {
    const rect = node.getBoundingClientRect();
    return {
      id: node.getAttribute("data-flash-target"),
      label: node.getAttribute("aria-label") || node.textContent.trim(),
      role: node.getAttribute("data-role"),
      domRect: {
        x: rect.x,
        y: rect.y,
        width: rect.width,
        height: rect.height
      }
    };
  });
}

app.commandLine.appendSwitch("force-renderer-accessibility");

ipcMain.on("fixture-state", (_event, key) => {
  state[key] = (state[key] || 0) + 1;
  writeState();
});

ipcMain.on("fixture-toggle", (_event, checked) => {
  state.toggle = checked ? 1 : 0;
  writeState();
});

app.whenReady().then(async () => {
  writeState();
  const win = new BrowserWindow({
    width: 900,
    height: 640,
    show: false,
    title: "Flash Electron Fixture",
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  });
  await win.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html())}`);
  win.show();
  win.focus();
  const targets = await win.webContents.executeJavaScript(`(${collectExpectedTargets.toString()})()`);
  fs.mkdirSync(path.dirname(expectedFile), { recursive: true });
  fs.writeFileSync(expectedFile, JSON.stringify({ targets }, null, 2));
});

app.on("window-all-closed", () => {
  app.quit();
});
