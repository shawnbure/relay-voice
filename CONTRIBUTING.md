# Contributing to Relay

1. Fork the repository and create a focused branch.
2. Follow the README's local setup.
3. Keep provider credentials and customer data out of fixtures, logs, screenshots, commits, issues, and pull requests.
4. Add or update tests for behavior changes.
5. Run `npm test`, `npm run typecheck`, and `npm run build` before opening a pull request.
6. Explain user-visible behavior, migrations, deployment changes, and security implications.

Preserve tenant scoping, normalize telephone inputs to E.164 at API boundaries, verify webhook signatures before processing payloads, and never send provider secrets to a client.

Use GitHub's private vulnerability reporting instead of a public issue for security problems.
