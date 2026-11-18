// The article of a published page: HTML the build rendered, which the page
// adopts as it is rather than render again. What it gains once the page runs
// is attached here: copy buttons on code blocks, and an outline that follows
// the reading position.

import type { Attachment } from "svelte/attachments";
import { copyButton, followHeadings } from "../lib/article";

/** The article's nodes, kept so the reading area can take them back after a search. */
let article: Node[] | undefined;

/** The outline marks the section at the top of the reading area. */
function followOutline(host: HTMLElement): () => void {
  const body = host.querySelector(".article-body");
  const links = Array.from(host.querySelectorAll<HTMLAnchorElement>("aside.toc a"));
  if (!body || !links.length) return () => {};
  return followHeadings(body, (id) => {
    for (const link of links) {
      const current = link.getAttribute("href") === `#${id}`;
      link.classList.toggle("current", current);
      if (current) link.setAttribute("aria-current", "location");
      else link.removeAttribute("aria-current");
    }
  });
}

export const island: Attachment<HTMLElement> = (host) => {
  if (article) host.replaceChildren(...article);
  else {
    for (const block of host.querySelectorAll(".article-body pre")) block.append(copyButton());
    article = Array.from(host.childNodes);
  }
  return followOutline(host);
};
