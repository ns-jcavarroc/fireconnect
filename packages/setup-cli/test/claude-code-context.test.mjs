import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  applyClaudeCodeContextPolicy,
  claudeCodeModelId,
  CLAUDE_CODE_1M_CONTEXT_MODELS,
} from "../lib/claude-code-context.mjs";

const NON_1M_MODEL = "accounts/fireworks/models/glm-5p1";

function enabledMapping(overrides) {
  return applyClaudeCodeContextPolicy(
    { CLAUDE_CODE_DISABLE_1M_CONTEXT: "1" },
    overrides,
  );
}

describe("claude-code-context", () => {
  it("recognizes glm-5p2 as a 1M context model", () => {
    assert.ok(CLAUDE_CODE_1M_CONTEXT_MODELS.has("glm-5p2"));
    assert.equal(claudeCodeModelId("glm-5p2"), "glm-5p2[1m]");
    assert.equal(
      claudeCodeModelId("accounts/fireworks/models/glm-5p2"),
      "accounts/fireworks/models/glm-5p2[1m]",
    );
  });

  it("enables 1M context when the main model is glm-5p2", () => {
    const policy = enabledMapping({
      main: "glm-5p2",
      opus: NON_1M_MODEL,
      sonnet: NON_1M_MODEL,
      haiku: NON_1M_MODEL,
      subagent: NON_1M_MODEL,
    });
    assert.ok(!("CLAUDE_CODE_DISABLE_1M_CONTEXT" in policy));
  });

  it("enables 1M context when opus is glm-5p2 even if main is not", () => {
    const policy = enabledMapping({
      main: NON_1M_MODEL,
      opus: "glm-5p2",
      sonnet: NON_1M_MODEL,
      haiku: NON_1M_MODEL,
      subagent: NON_1M_MODEL,
    });
    assert.ok(!("CLAUDE_CODE_DISABLE_1M_CONTEXT" in policy));
  });

  it("disables 1M context when no mapped model supports it", () => {
    const policy = enabledMapping({
      main: NON_1M_MODEL,
      opus: NON_1M_MODEL,
      sonnet: NON_1M_MODEL,
      haiku: NON_1M_MODEL,
      subagent: NON_1M_MODEL,
    });
    assert.equal(policy.CLAUDE_CODE_DISABLE_1M_CONTEXT, "1");
  });
});
