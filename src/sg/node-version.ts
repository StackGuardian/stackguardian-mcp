/** Oldest Node.js major the npm package runs on; `engines` in package.json says the same. */
export const MIN_NODE_MAJOR = 18;

/** What to tell the user when `version` (`process.versions.node`) is too old, otherwise null. */
export function nodeVersionError(version: string): string | null {
  if (Number.parseInt(version, 10) >= MIN_NODE_MAJOR) return null;
  return [
    `add-sg-mcp needs Node.js ${MIN_NODE_MAJOR} or later, and this is Node.js ${version}.`,
    "Upgrade Node.js, or install the standalone executable, which does not need Node.js:",
    "",
    "  # macOS and Linux",
    "  curl -fsSL https://dl.stackguardian.io/add-sg-mcp/install.sh | sh",
    "",
    "  # Windows (PowerShell)",
    "  irm https://dl.stackguardian.io/add-sg-mcp/install.ps1 | iex",
    "",
    "More: https://github.com/StackGuardian/stackguardian-mcp#install",
  ].join("\n");
}
