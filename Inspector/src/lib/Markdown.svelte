<script lang="ts">
  import type { MdNode } from "./markdown";
  import { site } from "./routes";
  import { copyText } from "./toasts.svelte";

  /**
   * Mounts a rendered Markdown tree: each element is created with its
   * attributes and each string is a text node, on the server and in the
   * browser alike, so a prerendered page hydrates the same nodes. Code
   * blocks gain a copy button once the page runs (`interactive`); a toast
   * says whether the copy worked.
   */
  let { nodes, interactive = false }: { nodes: MdNode[]; interactive?: boolean } = $props();
  /**
   * The resident's help never hydrates: it builds the same elements and
   * text nodes with plain DOM calls. A long page is thousands of nodes, and
   * a reactive block for each made opening one take tens of milliseconds.
   * The server render, and the published site that hydrates it, keep the
   * template.
   */
  const direct = typeof document !== "undefined" && !site.public;
  const voids = new Set(["br", "hr", "img", "input"]);

  function copy(event: MouseEvent) {
    const code = (event.currentTarget as HTMLButtonElement).closest("pre")?.querySelector("code");
    void copyText(code?.textContent ?? "", "the code block", "Select the code and copy it instead.");
  }

  function append(parent: Node, list: MdNode[]) {
    for (const node of list) {
      if (typeof node === "string") { parent.appendChild(document.createTextNode(node)); continue; }
      const element = document.createElement(node.tag);
      for (const [name, value] of Object.entries(node.attrs ?? {})) element.setAttribute(name, value);
      if (!voids.has(node.tag)) append(element, node.children ?? []);
      if (node.tag === "pre") {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "copy-code";
        button.setAttribute("aria-label", "Copy code");
        button.textContent = "Copy";
        button.addEventListener("click", copy);
        element.appendChild(button);
      }
      parent.appendChild(element);
    }
  }

  /** Replaces the host's content with `list`, built off the document. */
  function build(list: MdNode[]) {
    return (host: Element) => {
      const fragment = document.createDocumentFragment();
      append(fragment, list);
      host.replaceChildren(fragment);
    };
  }
</script>

{#snippet tree(list: MdNode[])}{#each list as node}{#if typeof node === "string"}{node}{:else if voids.has(node.tag)}<svelte:element this={node.tag} {...node.attrs} />{:else if node.tag === "pre"}<pre {...node.attrs}>{@render tree(node.children ?? [])}{#if interactive}<button type="button" class="copy-code" aria-label="Copy code" onclick={copy}>Copy</button>{/if}</pre>{:else}<svelte:element this={node.tag} {...node.attrs}>{@render tree(node.children ?? [])}</svelte:element>{/if}{/each}{/snippet}
{#if direct}<div class="markdown" {@attach build(nodes)}></div>{:else}{@render tree(nodes)}{/if}

<style>
  /* No box of its own: the article's rules and layout see the content directly. */
  .markdown { display: contents; }
</style>
