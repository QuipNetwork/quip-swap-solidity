# Local demos

These demos exercise the v1.1 prototype on ephemeral Anvil chains. They are not
production deployment procedures.

## Prerequisites

From the repository root, verify the tools and install dependencies once:

```sh
forge --version
anvil --version
bun --version
cd sdk && bun install --frozen-lockfile && cd ..
```

If `dependencies/` is absent, run
`make dependencies` once. Dependency installation
is explicit; ordinary Forge commands do not invoke Soldeer.

## Available demos

- [Automated cross-chain success](full-demo.md): `cd sdk && bun run demo:full`
- [Separate Alice/Bob console flow](console-demo.md): one command at a time
- [Same-chain success and recovery](same-chain-demo.md): `cd sdk && bun run demo:same-chain`
- [Cross-chain recovery](recovery-demo.md): `cd sdk && bun run demo:cross-chain:recovery`

All artifacts are local test evidence. Never reuse their keys, signatures,
secrets, nonces, or terms.

## Verification checkpoint

```sh
forge fmt --check
forge test
cd sdk
bun run check
bun run test:integration
bun run test:cross-chain
bun run demo:same-chain
bun run demo:cross-chain:recovery
bun run demo:full
bun run demo:console
```
