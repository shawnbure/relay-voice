import { describe, expect, it } from "vitest";
import { verifyTelnyxWebhook } from "../src/telnyx";

describe("verifyTelnyxWebhook", () => {
  it("rejects missing headers", async () => {
    await expect(verifyTelnyxWebhook({ body: "{}", signature: undefined, timestamp: undefined, publicKey: "bad" })).resolves.toBe(false);
  });

  it("rejects stale timestamps before cryptographic work", async () => {
    await expect(verifyTelnyxWebhook({ body: "{}", signature: "bad", timestamp: "1", publicKey: "bad", now: 600_000 })).resolves.toBe(false);
  });
});
