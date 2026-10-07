# core_pages

Run 2026-10-07T18:08:05.063Z against http://127.0.0.1:3000.

| screenshot | user | URL | shows |
|---|---|---|---|
| ![](core_pages-admin-settings.png) | admin | `/projects/e2e-project/settings` | admin: Project > Settings answers 200, with this plugin's "Reports and dashboards" tab |
| ![](core_pages-admin-issues.png) | admin | `/projects/e2e-project/issues` | admin: the issue list answers 200 |
| ![](core_pages-admin-issue.png) | admin | `/issues/1` | admin: an issue page answers 200 |
| ![](core_pages-admin-settings-tab.png) | admin | `/projects/e2e-project/settings/reporter_dashboards` | admin: the "Reports and dashboards" settings tab itself renders |
| ![](core_pages-manager-settings.png) | manager | `/projects/e2e-project/settings` | manager: Project > Settings answers 200, with this plugin's "Reports and dashboards" tab |
| ![](core_pages-manager-issues.png) | manager | `/projects/e2e-project/issues` | manager: the issue list answers 200 |
| ![](core_pages-manager-issue.png) | manager | `/issues/1` | manager: an issue page answers 200 |
| ![](core_pages-reporter-settings.png) | reporter | `/projects/e2e-project/settings` | reporter: Project > Settings answers 403 |
| ![](core_pages-reporter-issues.png) | reporter | `/projects/e2e-project/issues` | reporter: the issue list answers 200 |
| ![](core_pages-reporter-issue.png) | reporter | `/issues/1` | reporter: an issue page answers 200 |
| ![](core_pages-outsider-settings.png) | outsider | `/projects/e2e-project/settings` | outsider: Project > Settings of the public project is refused (403) |
| ![](core_pages-outsider-issues.png) | outsider | `/projects/e2e-project/issues` | outsider: the public project's issue list answers 200 |
| ![](core_pages-outsider-private-issues.png) | outsider | `/projects/e2e-private/issues` | outsider: the private project's issue list is refused (403) |
