import { mount } from "svelte";
import App from "./App.svelte";
import { adopt } from "./lib/access";
import "./app.css";

// The address Flash opened carries the access token once: keep it, then
// drop it from the address bar and the history entry.
const clean = adopt(location.href);
if (clean !== location.href) history.replaceState(history.state, "", clean);

const app = mount(App, { target: document.getElementById("app")! });

export default app;
