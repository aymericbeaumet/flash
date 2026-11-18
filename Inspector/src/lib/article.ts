import type { Manual, ManualPage } from "./docsite";
import type { Rendered } from "./markdown-tree";
import { paths } from "./routes";
import type { Crumb } from "./shell";
import { copyText } from "./toasts.svelte";

/** A page beside the one shown: the one before, the one after, or the one above. */
export interface ArticleLink {
  href: string;
  title: string;
}

/** What frames a rendered page: where it sits, what it is called and where it leads. */
export interface ArticleInfo {
  crumbs: Crumb[];
  title: string;
  summary?: string;
  /** Where the page's source is edited. */
  edit?: string;
  previous?: ArticleLink;
  next?: ArticleLink;
  up?: ArticleLink;
}

/** A page of the manual, framed by its place in the navigation. */
export function pageArticle(manual: Manual, page: ManualPage, rendered: Rendered): ArticleInfo {
  const { previous, next } = manual.neighbours(page.path);
  return {
    crumbs: [
      { label: "Documentation", href: paths.docs() },
      ...page.trail.map((label) => ({ label })),
    ],
    title: rendered.title ?? page.title,
    edit: manual.editURL(page),
    previous: previous && { href: paths.docs(previous.path), title: previous.title },
    next: next && { href: paths.docs(next.path), title: next.title },
  };
}

export function readingMinutes(markdown: string): number {
  return Math.max(1, Math.ceil(markdown.split(/\s+/).length / 220));
}

/** A code block's copy button; a toast says whether the copy worked. */
export function copyButton(): HTMLButtonElement {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-code";
  button.setAttribute("aria-label", "Copy code");
  button.textContent = "Copy";
  button.addEventListener("click", () => {
    void copyText(
      button.closest("pre")?.querySelector("code")?.textContent ?? "",
      "the code block",
      "Select the code and copy it instead.",
    );
  });
  return button;
}

/**
 * Follows the section at the top of the reading area: `show` takes the id of
 * the topmost heading of `body` in view. Returns what stops it.
 */
export function followHeadings(body: Element, show: (id: string) => void): () => void {
  const headings = Array.from(body.querySelectorAll("h2, h3"));
  if (!headings.length || typeof IntersectionObserver === "undefined") return () => {};
  const observer = new IntersectionObserver(
    (entries) => {
      const visible = entries
        .filter((entry) => entry.isIntersecting)
        .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top);
      if (visible[0]) show(visible[0].target.id);
    },
    { root: body.closest("main"), rootMargin: "0px 0px -70% 0px", threshold: 0 },
  );
  for (const heading of headings) observer.observe(heading);
  return () => observer.disconnect();
}
