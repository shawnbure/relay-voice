import { expect, test } from "vitest";
import { hashPassword, verifyPassword } from "../src/auth";

test("password credentials use salted PBKDF2 and verify correctly", async () => {
  const first = await hashPassword("correct horse battery staple");
  const second = await hashPassword("correct horse battery staple");
  expect(first.hash).toMatch(/^pbkdf2-sha256:100000:/);
  expect(first.salt).not.toBe(second.salt);
  expect(first.hash).not.toBe(second.hash);
  expect(await verifyPassword("correct horse battery staple", first.hash, first.salt)).toBe(true);
  expect(await verifyPassword("wrong password", first.hash, first.salt)).toBe(false);
  expect(await verifyPassword("anything", null, null)).toBe(false);
});
