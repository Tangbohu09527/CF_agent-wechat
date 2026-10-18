# Shanghai runtime timezone default

The production and lab Compose profiles now set the container process `TZ` to `Asia/Shanghai`. This fixed default adds no environment-file key and does not widen the production parser allowlist. Existing mounts, login data, restart policy, endpoints, credentials and binary/image selection are unchanged. The filename release candidate remains separately pinned; this change does not rebuild it or alter its original-media helpers.

The focused CI starts only `/bin/sh` over the exact upstream OCI digest, with no network, production mounts or login data. It checks that Shanghai zoneinfo exists, the local offset is +0800 and a fixed epoch remains identical under UTC and Shanghai. It does not start the server/WeChat or claim recipient acceptance. A later production Compose change requires controlled lifecycle and actual runtime timezone verification.

Existing UTC execution receipts, epoch deadlines and message timestamps are not rewritten. This change does not convert old SQLite values, reset login, trigger a QR scan or extend management authorization. Host timezone must be verified separately by the production executor.

Local targeted result: `python -m unittest discover -s tests -p test_timezone_defaults.py -v` passed. Actual fixed-image zoneinfo/offset/epoch proof is delegated to Linux CI; source parsing on Windows does not establish this result. The parent read-only production observation at 11:21:50 UTC found the fixed original image still deployed, with Shanghai zoneinfo present and no TZ configured; no live change occurred in this candidate task.
