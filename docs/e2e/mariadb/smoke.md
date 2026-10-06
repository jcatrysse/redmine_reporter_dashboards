# smoke

Run 2026-10-06T21:34:44.980Z against http://127.0.0.1:3000.

| screenshot | user | URL | shows |
|---|---|---|---|
| ![](smoke-01.png) | admin | `/` | / (HTTP 200) |
| ![](smoke-02.png) | admin | `/projects/e2e-project` | /projects/e2e-project (HTTP 200) |
| ![](smoke-03.png) | admin | `/projects/e2e-project/issues` | /projects/e2e-project/issues (HTTP 200) |
| ![](smoke-04.png) | admin | `/issues/1` | /issues/1 (HTTP 200) |
| ![](smoke-05.png) | admin | `/projects/e2e-project/issues/new` | /projects/e2e-project/issues/new (HTTP 200) |
| ![](smoke-06.png) | admin | `/projects/e2e-project/settings` | /projects/e2e-project/settings (HTTP 200) |
| ![](smoke-07.png) | admin | `/my/page` | /my/page (HTTP 200) |
| ![](smoke-08.png) | admin | `/my/account` | /my/account (HTTP 200) |
| ![](smoke-09.png) | admin | `/admin` | /admin (HTTP 200) |
| ![](smoke-10.png) | admin | `/admin/plugins` | /admin/plugins (HTTP 200) |
| ![](smoke-11.png) | admin | `/settings/plugin/redmine_reporter_dashboards` | /settings/plugin/redmine_reporter_dashboards (HTTP 200) |
| ![](smoke-12.png) | admin | `/projects/e2e-project/reporter` | /projects/e2e-project/reporter (HTTP 200) |
| ![](smoke-13.png) | admin | `/projects/e2e-project/reporter/report_pdf` | /projects/e2e-project/reporter/report_pdf (HTTP 404) |
| ![](smoke-14.png) | admin | `/projects/e2e-project/reporter/templates` | /projects/e2e-project/reporter/templates (HTTP 200) |
| ![](smoke-15.png) | admin | `/projects/e2e-project/reporter/templates/new` | /projects/e2e-project/reporter/templates/new (HTTP 200) |
| ![](smoke-16.png) | admin | `/projects/e2e-project/reporter/templates/1` | /projects/e2e-project/reporter/templates/1 (HTTP 200) |
| ![](smoke-17.png) | admin | `/projects/e2e-project/reporter/templates/1/edit` | /projects/e2e-project/reporter/templates/1/edit (HTTP 200) |
| ![](smoke-18.png) | admin | `/projects/e2e-project/reporter/templates/1/edit` | /projects/e2e-project/reporter/templates/1/document (HTTP 200) |
| ![](smoke-19.png) | admin | `/projects/e2e-project/reporter/templates/1/edit` | /projects/e2e-project/reporter/templates/1/export (HTTP 200) |
| ![](smoke-20.png) | admin | `/admin/reporter_dashboards/preflight` | /admin/reporter_dashboards/preflight (HTTP 200) |
| ![](smoke-21.png) | admin | `/sql/stats/monthly_flow` | /sql/stats/monthly_flow (HTTP 404) |
| ![](smoke-22.png) | admin | `/projects/e2e-project/reporter/schedules` | /projects/e2e-project/reporter/schedules (HTTP 200) |
| ![](smoke-23.png) | admin | `/projects/e2e-project/reporter/schedules/new` | /projects/e2e-project/reporter/schedules/new (HTTP 200) |
| ![](smoke-24.png) | admin | `/projects/e2e-project/reporter/schedules/1` | /projects/e2e-project/reporter/schedules/1 (HTTP 200) |
| ![](smoke-25.png) | admin | `/projects/e2e-project/reporter/schedules/1/edit` | /projects/e2e-project/reporter/schedules/1/edit (HTTP 200) |
| ![](smoke-26.png) | admin | `/projects/e2e-project/reporter/mail` | /projects/e2e-project/reporter/mail (HTTP 200) |
| ![](smoke-27.png) | admin | `/projects/e2e-project/reporter/mail/new` | /projects/e2e-project/reporter/mail/new (HTTP 404) |
| ![](smoke-28.png) | admin | `/reporter/s/1` | /reporter/s/1 (HTTP 404) |
| ![](smoke-29.png) | admin | `/projects/e2e-project/reporter/templates/1/shares` | /projects/e2e-project/reporter/templates/1/shares (HTTP 200) |
| ![](smoke-30.png) | admin | `/projects/e2e-project/reporter/templates/1/shares/new` | /projects/e2e-project/reporter/templates/1/shares/new (HTTP 200) |
