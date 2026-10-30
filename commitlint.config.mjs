export default {
  extends: ["@commitlint/config-conventional"],
  // The squash-merge commit of a PR, and `git revert`, are not authored by hand.
  ignores: [(message) => /^(Merge|Revert) /.test(message)],
};
