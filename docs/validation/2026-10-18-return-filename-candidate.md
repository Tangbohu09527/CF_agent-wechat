# Preserve the original returned filename — candidate

This change is an isolated source overlay, not a production deployment. It uses
upstream revision `96c2e90c497d999bf5189a134a9b3b293731f42e`, already recorded in
`upstream/media-retrieval.lock.json`. The source is not vendored by this repository;
the overlay refuses a different revision, dirty checkout, or mismatched input
file digest. The original `a949` worktree and saved evidence remain unchanged.

## Evidence and its limits

The pinned source has two independent rename points: the HTTP file route replaces
non-ASCII characters and punctuation, then places the timestamp prefix in the
basename; `paste-file` makes another renamed copy when the path is non-ASCII.
The observed returned PDF name has this source-level signature.

The saved media-candidate lock connects the pinned source to a particular public
OCI candidate through provenance and extracted binary hashes. It explicitly
describes an isolated candidate. No fresh proof that the current production
binary is that exact binary was obtained for this task. Matching naming behavior
does not substitute for that proof. No production connection, image replacement,
WeChat login, or protocol change has been performed by this candidate.

## Minimal behavior change

- A valid supplied filename is kept byte-for-byte as the basename inside a fresh
  UUID directory. Neither message text nor a model-generated title supplies it.
- Chinese, spaces, parentheses, accents, `%`, and `#` are preserved. Path
  separators, controls, directional control characters, Windows-illegal
  punctuation/device names, trailing dots/spaces, empty names and names longer
  than 255 UTF-8 bytes are rejected rather than silently renamed or truncated.
- Bytes are fully decoded and size-checked before publication. Exclusive
  creation prevents collisions or overwrites. A private construction directory
  becomes `0711`, and its complete file becomes `0644`, preserving the existing
  root-server / ordinary-WeChat cross-user read contract. This is not a claim of
  secrecy against an account that already knows the unpredictable full path.
- `paste-file` supplies an ASCII percent-encoded UTF-8 `text/uri-list`, without a
  second copied/renamed file. Image routing and `paste-image` are unchanged.
- A failed paste helper returns failure before pressing Return. The existing
  GUI execution loop remains the consumer boundary. Temporary files survive
  until that loop returns, including when the HTTP waiter disconnects. An
  already accepted send can therefore finish after HTTP cancellation. There are
  no new retries or services. File sends have a 30-second queue wait limit; once
  the GUI lock is held they retain the existing 300-second loop limit and
  individual tool timeouts. These are separate bounds, not a strict total
  five-minute deadline. Process termination can still leave temporary material.

The GUI plan's return is the existing completion boundary; it does not prove a
human received or opened the file. Clipboard setup alone is not treated as
completion. Cleanup removes only the exclusively-created file and its directory,
never a recursive or shared temporary tree.

## Verification

Local Windows checks exercise the pinned overlay and reject modified source;
they do not compile or execute the Linux Rust/Qt consumer. The dedicated Actions
job compiles the actual modified upstream sender, runs synthetic success/failure,
concurrency, queue timeout/cancellation and HTTP-waiter cancellation tests, then
passes the actual `paste-file` URI through native Qt `QUrl`/`QFile` under `LC_ALL=C`.
The Qt check also runs as a distinct unprivileged UID and compares exact bytes
and basename. Clipboard/keystroke commands are test stand-ins: no production
WeChat or real chat is used. Passing these checks remains isolated evidence;
production filename and recipient acceptance require separate authorization and
verification after a reviewed deployment.
