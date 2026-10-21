#!/usr/bin/env node
// Copies the Tirith skills from StackGuardian/tirith, pinned to the tag in
// standalone/TIRITH_VERSION, into standalone/. The copies are never edited by
// hand: change them upstream in Tirith, then bump the tag and run this again.
//
// Usage:
//   node scripts/sync-tirith-skills.mjs          overwrite standalone/<skill>
//   node scripts/sync-tirith-skills.mjs --check  fail if the committed copy differs
import { spawnSync } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const TIRITH_REPO = "https://github.com/StackGuardian/tirith.git";
// tirith-standards and tirith-migrate join this list once a Tirith release
// contains them; 1.2.1 ships only tirith-policies.
const TIRITH_SKILLS = ["tirith-policies"];

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const standaloneDir = join(repoRoot, "standalone");
const tag = readFileSync(join(standaloneDir, "TIRITH_VERSION"), "utf-8").trim();
const check = process.argv.includes("--check");

function listFiles(dir) {
  return readdirSync(dir, { recursive: true })
    .map(String)
    .filter((path) => statSync(join(dir, path)).isFile())
    .sort();
}

/** Returns a description of every difference between two directory trees. */
function diffTrees(expected, actual) {
  if (!existsSync(actual)) return [`${relative(repoRoot, actual)} is missing`];
  const want = listFiles(expected);
  const have = listFiles(actual);
  const problems = [];
  for (const path of want) {
    if (!have.includes(path)) problems.push(`missing ${path}`);
    else if (
      !readFileSync(join(expected, path)).equals(
        readFileSync(join(actual, path)),
      )
    )
      problems.push(`changed ${path}`);
  }
  for (const path of have) {
    if (!want.includes(path)) problems.push(`unexpected ${path}`);
  }
  return problems;
}

const work = mkdtempSync(join(tmpdir(), "tirith-skills-"));
try {
  const clone = spawnSync(
    "git",
    [
      "-c",
      "advice.detachedHead=false",
      "clone",
      "--quiet",
      "--depth",
      "1",
      "--branch",
      tag,
      TIRITH_REPO,
      work,
    ],
    { stdio: "inherit" },
  );
  if (clone.status !== 0) {
    throw new Error(`git clone of ${TIRITH_REPO} at ${tag} failed`);
  }

  const problems = [];
  for (const skill of TIRITH_SKILLS) {
    const source = join(work, ".claude", "skills", skill);
    if (!existsSync(join(source, "SKILL.md"))) {
      throw new Error(`Tirith ${tag} has no .claude/skills/${skill}/SKILL.md`);
    }
    const target = join(standaloneDir, skill);
    if (check) {
      problems.push(...diffTrees(source, target).map((p) => `${skill}: ${p}`));
    } else {
      rmSync(target, { recursive: true, force: true });
      cpSync(source, target, { recursive: true });
      console.log(`synced ${skill} from Tirith ${tag}`);
    }
  }

  if (problems.length > 0) {
    console.error(
      `standalone/ does not match Tirith ${tag}. Do not edit these files by hand; run node scripts/sync-tirith-skills.mjs.`,
    );
    for (const problem of problems) console.error(`  ${problem}`);
    process.exitCode = 1;
  } else if (check) {
    console.log(`standalone/ matches Tirith ${tag}`);
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
