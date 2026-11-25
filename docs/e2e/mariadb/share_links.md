# share_links

Run 2026-10-06T21:37:36.971Z against http://127.0.0.1:3000.

| screenshot | user | URL | shows |
|---|---|---|---|
| ![](share_links-index-empty.png) | manager | `/projects/e2e-project/reporter/templates/1/shares` | Share links of "E2E issue report" before any link exists: the empty state and the create action |
| ![](share_links-new.png) | manager | `/projects/e2e-project/reporter/templates/1/shares/new` | The new share link form: purpose, expiry, use limit, public flag |
| ![](share_links-created.png) | manager | `/projects/e2e-project/reporter/templates/1/shares` | Link created: the URL is shown once, the list shows expiry, uses and the revoke action |
| ![](share_links-private-anonymous.png) | anonymous | `/login?back_url=http%3A%2F%2F127.0.0.1%3A3000%2Freporter%2Fs%2Fdo9FjCdiJ7JBq3-W7yCtJTAG0QxadAyLT5CfvU5w3Es` | A non-public share link opened anonymously: Redmine asks for a login first |
| ![](share_links-unknown-token.png) | anonymous | `/reporter/s/thisIsNotAToken123` | An unknown token: refused with 404 and nothing about the report |
| ![](share_links-single-use-exhausted.png) | anonymous | `/reporter/s/_EKwP-Lyen3qYwCmafshozAAgiy32ul15wxrymwO2P4` | A single-use link opened a second time is refused (HTTP 410) |
| ![](share_links-revoked.png) | manager | `/projects/e2e-project/reporter/templates/1/shares` | After revoking, the list marks the link revoked |
| ![](share_links-revoked-open.png) | anonymous | `/reporter/s/7o1HUGaKonJVQlwZ3-njDHlMAf4vswnvol6nWIWiScw` | The revoked link is refused (HTTP 410) with the refusal page |
| ![](share_links-reporter-refused.png) | reporter | `/projects/e2e-project/reporter/templates/1/shares` | Reporter without share permission: the share link list is refused (403) |
