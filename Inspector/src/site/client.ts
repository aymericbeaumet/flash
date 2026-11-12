// The published site in the browser: hydrate the prerendered page with the
// bundle it was rendered from, then let the App take over navigation.

import { hydrate } from "svelte";
import App from "../App.svelte";
import "../app.css";
import { docsStore } from "../lib/docs.svelte";
import { siteLinks, type DocsBundle } from "../lib/docsite";
import { router } from "../lib/router.svelte";
import { useSite } from "../lib/routes";

const boot = JSON.parse(document.getElementById("flash-docs")!.textContent!) as { bundle: DocsBundle; route: string };
useSite(siteLinks("public", boot.bundle.site));
docsStore.prime(boot.bundle, false);
router.prime(new URL(boot.route, location.href));
hydrate(App, { target: document.getElementById("app")! });
