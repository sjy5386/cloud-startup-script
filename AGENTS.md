# Keep `bootstrap.sh` within 1024 bytes

`bootstrap.sh` is pasted into a CSP user-data field. That field allows 1024 bytes, so the whole file must stay at or under 1024 bytes.

Put new setup in `setup.sh`. The only work that belongs in `bootstrap.sh` is pinning DNS, then downloading `setup.sh`. DNS has to be pinned before `apt` or `curl` in that file, and the file still has to fit.

`.githooks/pre-commit` rejects a commit when the staged `bootstrap.sh` is over 1024 bytes. It runs when this clone has `git config --local core.hooksPath .githooks`.
