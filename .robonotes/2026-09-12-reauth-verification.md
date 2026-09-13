# Re-authentication verification

- User recreated Upduck2 manually; its successful usage response must not be counted as a Re-authenticate success.
- Read-only usage requests accepted six current saved access tokens and rejected restored Clank1/Clank2 copies with 401. No refresh-token requests were made.
- Re-authenticate previously accepted local token shape plus a successful copy as success. It also deleted the temporary login even when replacement failed.
- Added usage-service validation before replacement, saved-file read-back verification, live-file comparison in the shell replacement, retention of fresh login files on failure, and explicit manual VS Code reload messaging.
- Validation failures retain the isolated login and leave the profile unchanged. Network/service errors are reported as inability to verify, not proof of revocation.
- Build and shell transaction tests passed. Browser login end-to-end remains user-interactive; the cause of server invalidation remains unproven.
