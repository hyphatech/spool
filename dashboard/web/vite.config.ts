import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig, type Plugin } from "vite";
import solid from "vite-plugin-solid";
import solidtype from "vite-plugin-solidtype";

// The dashboard's page, rooted here, loads Melange's output from the
// repository's _build, which dune writes first. It is built into
// ../assets, which is committed and compiled into the package, with every
// URL relative to the page, so it is served under any prefix.
const repository = fileURLToPath(new URL("../..", import.meta.url));

const here = fileURLToPath(new URL(".", import.meta.url));

// Melange's output under _build imports packages by name, which live in
// this directory's node_modules, not above _build: such an import is
// resolved as if this directory's page made it, and left to Vite otherwise.
const fromHere: Plugin = {
  name: "resolve-from-web",
  enforce: "pre",
  async resolveId(source, importer, options) {
    if (!importer?.includes("/_build/") || source.startsWith(".") || source.startsWith("/")) return null;
    return (await this.resolve(source, `${here}index.html`, { ...options, skipSelf: true })) ?? null;
  },
};

export default defineConfig({
  root: here,
  base: "./",
  plugins: [fromHere, tailwindcss(), solidtype(), solid()],
  server: { fs: { allow: [repository] } },
  build: {
    outDir: fileURLToPath(new URL("../assets", import.meta.url)),
    emptyOutDir: true,
    assetsInlineLimit: 0,
    // One bundle is the design: the page is served from memory, and a
    // browser keeps it a year.
    chunkSizeWarningLimit: 1024,
  },
});
