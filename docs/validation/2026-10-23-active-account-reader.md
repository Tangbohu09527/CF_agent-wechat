# Active-account read candidate

Dependency: WeChat PR14, `73e6e83ed3428ebe8fc5f11e0ff39c9123af00ee`; official upstream remains fixed at `96c2e90c497d999bf5189a134a9b3b293731f42e`.

The current client can be logged into a different account while `sessions.logged_in_user` still names a previous account. The existing native read handlers use that saved value and may lazily extract keys from the new process into the previous account's partition. Merely changing the browser label or adding a Gateway source cannot correct this boundary.

This candidate resolves the unique current account from a verified process and its open database FDs, reports that account from fresh auth, and uses it in contact/chat/message metadata reads. It does not change stored identity, run LoginPlan, log out, operate the UI, reset checkpoints, delete old keys, start a new client or modify the file-send path. The candidate has no deployment action.

Local Windows source-contract RED reproduced two expected failures against PR14; candidate GREEN passed all four contracts. These are source checks, not native or live acceptance. Native process-observation, SQL preservation, retained WAL regressions and binary packaging run separately in the dedicated Linux workflow; pending results must not be counted as passed. Runtime account/keys/contacts and real-message acceptance require a later authorized operator check.

The new account requires its own Gateway source and new first-window baseline; old permissions, archives and candidate source records are not migrated. Existing source collection must remain disabled until the actual account and intended source agree.
