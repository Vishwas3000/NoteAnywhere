import { defineConfig } from "vite";

// One classic script + one stylesheet: loads from <script src> in the extension frame and the Mac app's WebView.
export default defineConfig({
  build: {
    outDir: "dist",
    lib: {
      entry: "src/index.js",
      name: "MNEditor",
      formats: ["iife"],
      fileName: () => "mn-editor.js",
      cssFileName: "mn-editor",
    },
  },
});
