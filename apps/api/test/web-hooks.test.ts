import { readFileSync } from "node:fs";
import ts from "typescript";
import { expect, test } from "vitest";

test("web app never calls React hooks at module scope", () => {
  const source = ts.createSourceFile("App.tsx", readFileSync(new URL("../../web/src/App.tsx", import.meta.url), "utf8"), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  const violations: string[] = [];
  const inspect = (node: ts.Node) => {
    if (ts.isFunctionLike(node)) return;
    if (ts.isCallExpression(node) && /^use[A-Z]/.test(node.expression.getText(source))) violations.push(node.expression.getText(source));
    ts.forEachChild(node, inspect);
  };
  inspect(source);
  expect(violations).toEqual([]);
});
