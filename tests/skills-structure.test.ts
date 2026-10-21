#!/usr/bin/env tsx
// Structure checks for every skill this repository publishes: the six sg-*
// skills the wizard installs (skills/) and the standalone skills (standalone/),
// plus the catalog, the skills.sh grouping and the Claude Code marketplace.
import assert from "node:assert";
import {
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "js-yaml";
import { SG_SKILL_NAMES, installSkills } from "../src/sg/skills.js";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SKILL_ROOTS = ["skills", "standalone"] as const;
const WIZARD_NOTE =
  "> **Before you start:** this skill needs the StackGuardian MCP server. If no StackGuardian tools are available (for example `search_workflows`), stop. Tell the user to run `npx @stackguardian/mcp-wizard` and restart the agent. Do not call StackGuardian APIs another way.";

let passed = 0;
let failed = 0;
const tempDirs: string[] = [];

function test(name: string, fn: () => void) {
  try {
    fn();
    console.log(`✓ ${name}`);
    passed++;
  } catch (err) {
    console.log(`✗ ${name}`);
    console.error(`  ${(err as Error).message}`);
    failed++;
  }
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(join(repoRoot, path), "utf-8")) as T;
}

type Skill = { root: string; dir: string; path: string };

/** Every `<root>/<name>/SKILL.md` folder under the published skill roots. */
function skillFolders(): Skill[] {
  return SKILL_ROOTS.flatMap((root) =>
    readdirSync(join(repoRoot, root))
      .filter((name) => statSync(join(repoRoot, root, name)).isDirectory())
      .map((name) => ({ root, dir: name, path: `${root}/${name}` })),
  );
}

function frontmatter(skillPath: string): Record<string, unknown> {
  const text = readFileSync(join(repoRoot, skillPath, "SKILL.md"), "utf-8");
  const match = /^---\n([\s\S]*?)\n---\n/.exec(text);
  assert.ok(match, `${skillPath}/SKILL.md has no frontmatter block`);
  const data = yaml.load(match[1]);
  assert.ok(
    data && typeof data === "object",
    `${skillPath}/SKILL.md frontmatter is not a mapping`,
  );
  return data as Record<string, unknown>;
}

function markdownFiles(dir: string): string[] {
  return readdirSync(dir, { recursive: true })
    .map(String)
    .filter((path) => path.endsWith(".md"))
    .map((path) => join(dir, path));
}

/** Relative link targets outside fenced code blocks. */
function relativeLinks(markdown: string): string[] {
  const prose = markdown.replace(/```[\s\S]*?```/g, "");
  return [...prose.matchAll(/\]\(([^)\s]+)\)/g)]
    .map((m) => m[1])
    .filter((target) => !/^(https?:|mailto:|#)/.test(target))
    .map((target) => decodeURIComponent(target.split("#")[0]));
}

type CatalogEntry = {
  slug: string;
  title: string;
  tier: "standalone" | "platform";
  requiresStackGuardian: boolean;
  category: string;
  summary: string;
  description: string;
  examplePrompts: string[];
  supportedAgents: string[];
  prerequisites: string[];
  install: { skillsCli: string | null; claudePlugin: string | null };
  githubPath: string;
  demoUrl: string | null;
  relatedSlugs: string[];
};
const catalog = readJson<{ version: number; skills: CatalogEntry[] }>(
  "catalog/skills.json",
);

test("every SKILL.md has a valid name and a what-and-when description", () => {
  const skills = skillFolders();
  assert.ok(skills.length > SG_SKILL_NAMES.length, "found the skill folders");
  for (const skill of skills) {
    const meta = frontmatter(skill.path);
    assert.strictEqual(meta.name, skill.dir, `${skill.path}: name`);
    assert.match(
      skill.dir,
      /^[a-z0-9-]{1,64}$/,
      `${skill.path}: name must be lowercase letters, digits and hyphens, at most 64 characters`,
    );
    const description = meta.description;
    assert.ok(
      typeof description === "string" && description.trim().length > 0,
      `${skill.path}: description missing`,
    );
    assert.ok(
      description.length <= 1024,
      `${skill.path}: description is ${description.length} characters`,
    );
    assert.match(
      description,
      /\bwhen\b/i,
      `${skill.path}: description should say when to use the skill`,
    );
  }
});

test("every relative link inside a skill resolves", () => {
  for (const skill of skillFolders()) {
    for (const file of markdownFiles(join(repoRoot, skill.path))) {
      for (const target of relativeLinks(readFileSync(file, "utf-8"))) {
        assert.ok(
          existsSync(resolve(dirname(file), target)),
          `${relative(repoRoot, file)} links to missing ${target}`,
        );
      }
    }
  }
});

test("the sg-* skills tell the agent how to connect when the server is missing", () => {
  for (const name of SG_SKILL_NAMES) {
    const text = readFileSync(
      join(repoRoot, "skills", name, "SKILL.md"),
      "utf-8",
    );
    assert.ok(text.includes("npx @stackguardian/mcp-wizard"), name);
    assert.ok(text.includes(WIZARD_NOTE), `${name}: note differs`);
  }
});

test("the wizard still installs exactly the six sg-* skills", () => {
  const folders = readdirSync(join(repoRoot, "skills")).filter((name) =>
    statSync(join(repoRoot, "skills", name)).isDirectory(),
  );
  assert.deepStrictEqual(folders.sort(), [...SG_SKILL_NAMES].sort());

  const pkg = readJson<{ files: string[]; scripts: Record<string, string> }>(
    "package.json",
  );
  assert.deepStrictEqual(pkg.files, ["dist", "skills", "README.md"]);
  const buildBinary = pkg.scripts["build:binary"] ?? "";
  assert.ok(buildBinary.includes(" skills/*/SKILL.md "));
  assert.ok(!buildBinary.includes("standalone"));

  const home = mkdtempSync(join(tmpdir(), "add-sg-mcp-structure-home-"));
  const cwd = mkdtempSync(join(tmpdir(), "add-sg-mcp-structure-cwd-"));
  tempDirs.push(home, cwd);
  process.env.XDG_CONFIG_HOME = join(home, ".config");
  const results = installSkills(["claude-code", "codex"], "global", cwd, {
    home,
  });
  assert.ok(
    results.every((r) => !r.error),
    JSON.stringify(results.filter((r) => r.error)),
  );
  for (const dir of [
    join(home, ".agents", "skills"),
    join(home, ".claude", "skills"),
  ]) {
    assert.deepStrictEqual(
      readdirSync(dir).sort(),
      [...SG_SKILL_NAMES].sort(),
      dir,
    );
  }
});

test("catalog entries point at real skills with matching names", () => {
  assert.strictEqual(catalog.version, 1);
  const slugs = catalog.skills.map((entry) => entry.slug);
  assert.strictEqual(new Set(slugs).size, slugs.length, "slugs are unique");
  const categories = ["Review", "Deploy", "Policy", "Migrate", "Platform"];
  for (const entry of catalog.skills) {
    assert.ok(
      existsSync(join(repoRoot, entry.githubPath, "SKILL.md")),
      `${entry.slug}: ${entry.githubPath}/SKILL.md`,
    );
    assert.strictEqual(frontmatter(entry.githubPath).name, entry.slug);
    const platform = entry.githubPath.startsWith("skills/");
    assert.strictEqual(entry.requiresStackGuardian, platform, entry.slug);
    assert.strictEqual(
      entry.tier,
      platform ? "platform" : "standalone",
      entry.slug,
    );
    assert.ok(categories.includes(entry.category), entry.slug);
    assert.ok(entry.summary.length <= 160, `${entry.slug}: summary length`);
    for (const related of entry.relatedSlugs) {
      assert.ok(slugs.includes(related), `${entry.slug}: ${related}`);
    }
  }
});

test("every skill folder has a catalog entry", () => {
  const paths = catalog.skills.map((entry) => entry.githubPath);
  for (const skill of skillFolders()) {
    assert.ok(paths.includes(skill.path), `${skill.path} is not catalogued`);
  }
});

test("skills.sh groupings list only catalogued skills in the right tier", () => {
  const grouping = readJson<{
    groupings: { title: string; skills: string[] }[];
  }>("skills.sh.json");
  const tierOf = new Map(catalog.skills.map((e) => [e.slug, e.tier]));
  const expected: Record<string, string> = {
    "Works with any repo": "standalone",
    "With StackGuardian": "platform",
  };
  for (const group of grouping.groupings) {
    for (const slug of group.skills) {
      assert.strictEqual(
        tierOf.get(slug),
        expected[group.title],
        `${group.title}: ${slug}`,
      );
    }
  }
});

test("the marketplace plugins carry skills only", () => {
  const marketplace = readJson<{
    name: string;
    plugins: Record<string, unknown>[];
  }>(".claude-plugin/marketplace.json");
  assert.strictEqual(marketplace.name, "stackguardian");
  const plugins = Object.fromEntries(
    marketplace.plugins.map((p) => [p.name as string, p]),
  );
  assert.deepStrictEqual(plugins.terraform?.skills, ["./standalone"]);
  assert.deepStrictEqual(plugins.stackguardian?.skills, ["./skills"]);
  for (const plugin of marketplace.plugins) {
    for (const key of [
      "mcpServers",
      "hooks",
      "agents",
      "commands",
      "lspServers",
    ]) {
      assert.ok(!(key in plugin), `${plugin.name as string} declares ${key}`);
    }
  }
  // A plugin whose source is the repository root would load these too.
  for (const path of [".mcp.json", "hooks", "agents", "commands", "bin"]) {
    assert.ok(!existsSync(join(repoRoot, path)), `repository root has ${path}`);
  }
});

for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
