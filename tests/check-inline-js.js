const fs = require("fs");

const files = process.argv.slice(2);
if (!files.length) {
  throw new Error("Provide at least one HTML file.");
}

for (const file of files) {
  const html = fs.readFileSync(file, "utf8");
  const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/gi)]
    .map((match) => match[1])
    .filter((source) => source.trim());

  scripts.forEach((source, index) => {
    try {
      new Function(source);
    } catch (error) {
      throw new Error(`${file}, script ${index + 1}: ${error.message}`);
    }
  });

  console.log(`${file}: ${scripts.length} inline script(s) OK`);
}
