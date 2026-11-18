<script lang="ts">
  import { copyButton } from "./article";
  import type { MdNode } from "./markdown-tree";

  /**
   * Mounts a rendered Markdown tree: each element is created with its
   * attributes and each string is a text node. Code blocks gain a copy
   * button where the page runs.
   */
  let { nodes }: { nodes: MdNode[] } = $props();
  /**
   * The browser builds the elements and text nodes with plain DOM calls: a
   * long page is thousands of nodes, and a reactive block for each made
   * opening one take tens of milliseconds. The build's server render, which
   * no browser hydrates, keeps the template.
   */
  const direct = typeof document !== "undefined";
  const voids = new Set(["br", "hr", "img", "input"]);

  function append(parent: Node, list: MdNode[]) {
    for (const node of list) {
      if (typeof node === "string") {
        parent.appendChild(document.createTextNode(node));
        continue;
      }
      const element = document.createElement(node.tag);
      for (const [name, value] of Object.entries(node.attrs ?? {}))
        element.setAttribute(name, value);
      if (!voids.has(node.tag)) append(element, node.children ?? []);
      if (node.tag === "pre") element.appendChild(copyButton());
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

{#snippet tree(
  list: MdNode[],
)}{#each list as node}{#if typeof node === "string"}{node}{:else if voids.has(node.tag)}<svelte:element
        this={node.tag}
        {...node.attrs}
      />{:else}<svelte:element this={node.tag} {...node.attrs}
        >{@render tree(node.children ?? [])}</svelte:element
      >{/if}{/each}{/snippet}
{#if direct}<div class="markdown" {@attach build(nodes)}></div>{:else}{@render tree(nodes)}{/if}

<style>
  /*
   * No box of its own: the article's rules and layout see the content
   * directly. Global, so the template's elements take no class from it.
   */
  :global(.markdown) {
    display: contents;
  }
</style>
