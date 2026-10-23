# Active account read candidate

Read-only account resolution from the currently running WeChat process. No login, logout, account adoption or checkpoint reset.

The overlay composes the PR14 observation/WAL patch on exact official `96c2e90c497d999bf5189a134a9b3b293731f42e`. It changes fresh auth and the six contact/chat/message metadata read handlers. It leaves login, sending, media, stored session identity and old checkpoints unchanged.

`GET /api/status/auth` reports the unique account opened by the verified current process in `loggedInUser`, `identitySource=active_process_fd`, `identityVerified=true`, and `readIdentityContract=active-account-reader-v1`. `storedIdentityMatches` is diagnostic only. Missing, ambiguous or unverifiable process/account state cannot reuse the saved identity; metadata reads return HTTP 409 with a non-sensitive reason code.

The process executable, DISPLAY, HOME and Linux process start time are checked. All open `xwechat_files/.../db_storage/*.db` targets must identify one account. Reads recheck the process and account before returning. Missing keys are extracted through the official tool, verified against this account's DB, and stored only in the existing session/account/database partition. Unknown identity must be resolved before any extraction or key persistence.

The candidate does not migrate Gateway sources, employee permissions or archives. A previously registered source remains associated with its original account and must remain stopped after a real account switch. Register the new account separately before resuming candidate collection. The old account's keys and checkpoint rows remain intact.

Local source-contract RED/GREEN is distinct from native Linux regressions and live acceptance. `active-account-reader.yml` runs the fixed-source contracts, actual filesystem/SQL regressions, retained PR14 observation/WAL tests and the one-binary package/loader check using the official Cargo lock and Rust 1.93.0. It never starts WeChat or deploys to a server.
