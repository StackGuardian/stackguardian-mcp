#!/usr/bin/env node

// The npm bin. npm only warns about `engines`, so check the version here, before
// index.ts and its dependencies load: below Node 18 the sign-in fails on the missing
// global fetch, and only after the user has approved access in the browser.
import { nodeVersionError } from "./sg/node-version.js";

const versionError = nodeVersionError(process.versions.node);
if (versionError) {
  console.error(versionError);
  process.exit(1);
}

import("./index.js").catch((error: unknown) => {
  console.error(error);
  process.exit(1);
});
