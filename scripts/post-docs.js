// Prepends Jekyll front-matter to docgen-produced markdown so they integrate
// with the just-the-docs theme used for GitHub Pages.
const fs = require("fs");
const path = require("path");

const targets = [
  {
    file: path.join(__dirname, "..", "docs", "api", "index.md"),
    frontMatter: `---
title: API reference
nav_order: 4
---

`,
  },
];

for (const { file, frontMatter } of targets) {
  if (!fs.existsSync(file)) {
    console.error(`post-docs: missing ${file}`);
    process.exit(1);
  }
  const body = fs.readFileSync(file, "utf8");
  if (body.startsWith("---\n")) continue; // already has front-matter
  fs.writeFileSync(file, frontMatter + body);
  console.log(`post-docs: prepended front-matter to ${path.relative(process.cwd(), file)}`);
}
