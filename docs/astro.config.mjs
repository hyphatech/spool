import { fileURLToPath } from "node:url";
import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";
import links from "starlight-links-validator";
import hypha from "starlight-theme-hypha";

// spool's documentation site, published to GitHub Pages by
// .github/workflows/docs.yml. `make docs` builds it into _build/docs,
// odoc's reference from the .mli files into public/reference/ first.
//
// Every program a page shows is a file under examples/, built with the
// repository, and imported by its page with Vite's `?raw` into Starlight's
// <Code> -- so a page cannot show code that does not compile. A missing one,
// or a link to a page or a heading that is not there, fails the build.
const repository = fileURLToPath(new URL("..", import.meta.url));

export default defineConfig({
  site: "https://hyphatech.github.io",
  base: "/spool",
  outDir: `${repository}_build/docs`,
  // A page imports a file as `@examples/<file>?raw`, and spool's own
  // migrations as `@migrations/<file>?raw`, never by a path of its own.
  vite: { resolve: { alias: { "@examples": `${repository}examples`, "@migrations": `${repository}migrations` } } },
  integrations: [
    starlight({
      title: "spool",
      description: "A durable job queue in your own Postgres, for OCaml 5 and Eio.",
      logo: { src: "starlight-theme-hypha/assets/hypha.webp" },
      favicon: "/favicon-32.png",
      head: [
        { tag: "link", attrs: { rel: "icon", type: "image/png", sizes: "16x16", href: "/spool/favicon-16.png" } },
        { tag: "link", attrs: { rel: "apple-touch-icon", sizes: "180x180", href: "/spool/apple-touch-icon.png" } },
      ],
      plugins: [
        hypha({
          brand: "hypha",
          github: "hyphatech/spool",
          tabs: { "Start here": "rocket", Guides: "book-open", Reference: "library" },
          links: [{ label: "Hypha Stack", href: "https://hyphatech.io/stack", icon: "layers" }],
        }),
        // The reference is odoc's, in public/, which the validator cannot see.
        links({
          components: [["Feature", "href"]],
          errorOnLocalLinks: false,
          exclude: ["**/reference/spool/**"],
        }),
      ],
      sidebar: [
        { label: "Start here", items: ["install", "quick-start"] },
        {
          label: "Guides",
          items: [
            "guide/table",
            "guide/kinds",
            "guide/enqueueing",
            "guide/handlers",
            "guide/runner",
            "guide/operating",
            "guide/testing",
            "guide/limits",
          ],
        },
        { label: "Reference", items: ["reference"] },
      ],
    }),
  ],
});
