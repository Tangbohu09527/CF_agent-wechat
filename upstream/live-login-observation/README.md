# Minimal live observation candidate

This overlay targets only clean official `thisnick/agent-wechat@96c2e90c497d999bf5189a134a9b3b293731f42e`.
It changes four source files:

- `ia/states/login.rs`: recognize the saved-account **Enter Weixin** button alongside **Log In / Open WeChat**; still require **Switch Account** to identify this page.
- `ia/actions.rs`: the existing-account login action selects those three exact labels, never **Switch Account**.
- `router/status.rs`: require a freshly recognized main-window state. Unrecognized observations return `status=unknown`, `error=observation_unrecognized`, `reason=auth_observation_unrecognized`, `identityVerified=false` and `observedAt`; no stale context is saved on that path.
- `tools/wechat_db.rs`: short `mode=ro` SQLCipher connections include WAL, enforce `query_only` and bound busy wait to 1 second. They do not checkpoint, change journal mode or keep a read transaction open.

The branch is based on the preserve-account candidate, but its **default output and release package exclude all expected-account, filename, media-send and installer overlays**. Nothing here clears runtime/session/keys/checkpoints or starts a service.

## Reproduce

On an isolated Linux checkout with Python 3, Rust **1.93.0** and the official unchanged Cargo.lock:

```sh
python3 scripts/apply-live-login-observation.py --source /path/to/clean-official-source
cargo test --locked --manifest-path /path/to/clean-official-source/packages/agent-server-rust/Cargo.toml live_login_ -- --nocapture
cargo build --release --locked --manifest-path /path/to/clean-official-source/packages/agent-server-rust/Cargo.toml
```

Use a second clean checkout with `--regression-only` for the same native tests against old behavior. CI requires named assertion failures; compiler errors do not count as RED.

The native suite uses synthetic a11y fixtures and real encrypted SQLCipher databases. The WAL fixture first puts baseline data in the main file, leaves the writer open and disables automatic checkpointing, commits newer rows/timestamps only to WAL, then calls the actual production reader. Separate regressions cover current chat recognition, safe selector aliases, unknown observations, journal-mode preservation, write rejection and release of DELETE-journal locks after a short read.

The explicit `--with-expected-account` option composes the separate PR13 guard and is tested separately. The default binary does **not** add that guard and must not be represented as enabling the Gateway safe-login contract.

## Runtime package boundary

The dedicated CI builds on Ubuntu 22.04. `scripts/package-live-observation.py` checks the four-file source receipt and unchanged Cargo.lock, then uses:

```dockerfile
FROM ghcr.io/thisnick/agent-wechat@sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43
COPY --chown=0:0 --chmod=0755 agent-server /opt/agent-server/agent-server
```

Expected base config is `sha256:3b14e58c908ec11e9163ef0bbb51522bea15c1568c8e1012a29890b9adadc48e`.
Only one filesystem layer may be added; runtime command, entrypoint, user, environment, volumes and healthcheck must remain exact. The candidate loader is verified in a network-disabled read-only container with an overridden shell entrypoint. WeChat is never started.

The artifact contains the binary, Dockerfile, SHA256SUMS, source/build proof and synthetic test output. It contains no login data or credentials. It is a **reviewable build candidate**, not a deployed image or live-login acceptance. A production core replacement and any expected-account guard composition require their separately approved change and rollback boundary.
