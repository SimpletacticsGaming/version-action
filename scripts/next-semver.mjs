// Asks semantic-release what the next version would be, and writes the answer as
// JSON to $SR_OUT. Nothing is ever released: dryRun is on and no publishing plugin
// is configured.
//
// Why a file rather than stdout: semantic-release installs a global hook on
// process.stdout for its own logger, so anything written there is interleaved with
// log output and cannot be parsed reliably.
//
// Why the JS API rather than `semantic-release --dry-run`: the CLI exits 0 both when
// there is genuinely nothing to release and when it bailed early (branch not
// configured, run triggered by a PR, no push permission). The API returns `false`
// for "no release" and throws for everything else, which is the distinction the
// caller needs.
import semanticRelease from "semantic-release";
import { writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";

const required = (name) => {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required`);
  return value;
};

// semantic-release decides which branch it is on by inspecting the working tree,
// not from `branches`. If the two disagree it logs "configured to only publish
// from ..." and returns false -- the same value it returns when there is simply
// nothing to release. That would make a misconfigured run look like a quiet
// no-op, so rule it out here instead.
const branch = required("SR_BRANCH");
const cwd = required("SR_CWD");
const head = execFileSync("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd })
  .toString()
  .trim();
if (head !== branch) {
  throw new Error(
    `SR_BRANCH is '${branch}' but ${cwd} has '${head}' checked out. ` +
      `semantic-release would silently report "no release" for this mismatch.`,
  );
}

const result = await semanticRelease(
  {
    // Exactly one branch, always the one being built. semantic-release otherwise
    // refuses to run on anything not listed, and more than three release branches
    // is an ERELEASEBRANCHES error.
    branches: [branch],
    tagFormat: process.env.SR_TAG_FORMAT || "v${version}",
    // A throwaway bare mirror, so the unconditional push-permission check passes
    // without any credentials. See compute-version.sh.
    repositoryUrl: required("SR_REPO_URL"),
    dryRun: true,
    // env-ci reports a pull_request build as a PR and bails with exit 0 otherwise.
    ci: false,
    plugins: [["@semantic-release/commit-analyzer", { preset: "conventionalcommits" }]],
  },
  { cwd, stdout: process.stderr, stderr: process.stderr },
);

writeFileSync(
  required("SR_OUT"),
  JSON.stringify(
    result === false
      // No releasable commit. lastRelease is not available on this path; the caller
      // falls back to the newest tag reachable from HEAD.
      ? { version: null, type: null, lastVersion: null }
      : {
          version: result.nextRelease.version,
          type: result.nextRelease.type,
          lastVersion: result.lastRelease.version ?? null,
        },
  ),
);
