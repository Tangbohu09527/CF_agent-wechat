# Active-account read candidate

Dependency: WeChat PR14, `73e6e83ed3428ebe8fc5f11e0ff39c9123af00ee`; official upstream remains fixed at `96c2e90c497d999bf5189a134a9b3b293731f42e`.

The current client can be logged into a different account while `sessions.logged_in_user` still names a previous account. The existing native read handlers use that saved value and may lazily extract keys from the new process into the previous account's partition. Merely changing the browser label or adding a Gateway source cannot correct this boundary.

This candidate resolves the unique current account from a verified process and its open database FDs, reports that account from fresh auth, and uses it in contact/chat/message metadata reads. It does not change stored identity, run LoginPlan, log out, operate the UI, reset checkpoints, delete old keys, start a new client or modify the file-send path. The candidate has no deployment action.

Local Windows source-contract RED reproduced two expected failures against PR14; candidate GREEN passed all four contracts. These are source checks, not native or live acceptance.

The fixed code revision `26374798d1555361aad7501515bcbb189a88b576` passed [Linux push CI 39941092194](https://github.com/Tangbohu09527/CF_agent-wechat/actions/runs/39941092194), completed at `2026-10-23T10:48:13Z`. Its five native process-FD/account/SQL preservation tests and eleven retained PR14 live-observation/WAL tests passed. All fixtures are synthetic; CI did not start a live WeChat client. The release used the unchanged official Cargo.lock and Rust 1.93.0 on Ubuntu 22.04.

The downloaded artifact `active-account-26374798d1555361aad7501515bcbb189a88b576` (ID `12496630853`, expires `2026-11-06T10:48:09Z`) contains the evidence and binary. Independent local hashing matches `release-proof.json`:

- `active-release/context/agent-server`: SHA256 `697a4b7ac7b3f35354c0caf550a8ed7613f704ba3771c7c8efaef9ce8518ffbf`.
- `active-release/active-account-overlay.tar.gz`: SHA256 `e78f256d0ff2f96e8e061f0310a592ae0cb407b3626b3c642e8cfe32c1238200`.
- Fixed official runtime: `ghcr.io/thisnick/agent-wechat@sha256:97d5a99f933592c15897a7579b4e2b2cbbb5f4dda856228f8271f91dd7cafb43`; config `sha256:3b14e58c908ec11e9163ef0bbb51522bea15c1568c8e1012a29890b9adadc48e`.

The runtime loader verified and listed the candidate inside that fixed image. Dependencies resolve to its existing libgcc_s, libm, libc and ELF loader; runtime glibc is 2.35, while the binary requires at most 2.34. The package changes only `/opt/agent-server/agent-server`, preserves runtime configuration and has one replacement layer. No extra loader, library, client or service is required by this artifact. This establishes package compatibility, not an authorized deployment or live metadata acceptance.

Runtime account/keys/contacts and real-message acceptance require a separate authorized operator check. The existing `get_media`, download and voice paths are outside this repair and must not be treated as active-account verified. Until separately addressed, acceptance should use metadata and a few plain-text messages without opening original media. A deployment operator must preserve the WeChat PID/login and apply its separately authorized API-only replacement procedure.

The new account requires its own Gateway source and new first-window baseline; old permissions, archives and candidate source records are not migrated. Existing source collection must remain disabled until the actual account and intended source agree.
