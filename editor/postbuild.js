// After `vite build`: write shortcuts.json for the Mac Info panel and copy the bundle into the extension.
import { cpSync, writeFileSync } from "node:fs";
import { shortcuts } from "./src/shortcuts.js";

writeFileSync("dist/shortcuts.json", JSON.stringify(shortcuts, null, 2) + "\n");
cpSync("dist", "../extension/editor", { recursive: true });
