# delivery

Run 2026-10-06T21:52:41.446Z against http://127.0.0.1:3000.

| screenshot | user | URL | shows |
|---|---|---|---|
| ![](delivery-mail-new.png) | manager | `/projects/e2e-project/reporter/mail/new?template_id=1` | The "send report by e-mail" form: recipients from the project, issues, subject |
| ![](delivery-mail-no-recipient.png) | manager | `/projects/e2e-project/reporter/mail` | Sending without a recipient: an error, and no mail is written |
| ![](delivery-mail-sent.png) | manager | `/projects/e2e-project/reporter/templates/1` | After sending: the mail log lists the send with its recipients and status |
| ![](delivery-mail-log.png) | manager | `/projects/e2e-project/reporter/mail` | The mail log of the project |
| ![](delivery-schedules-index.png) | manager | `/projects/e2e-project/reporter/schedules` | Report schedules of the project: the seeded daily schedule with its next run |
| ![](delivery-schedule-new.png) | manager | `/projects/e2e-project/reporter/schedules/new` | New schedule form: template, query, repeat, dates, subject, render-as, recipients |
| ![](delivery-schedule-created.png) | manager | `/projects/e2e-project/reporter/schedules/2` | The new weekly schedule is saved |
| ![](delivery-schedule-invalid.png) | manager | `/projects/e2e-project/reporter/schedules` | End date before start date: rejected with an error message |
| ![](delivery-schedule-show.png) | manager | `/projects/e2e-project/reporter/schedules/1` | The seeded schedule: template, repeat, recipients, run history |
| ![](delivery-schedule-test-sent.png) | manager | `/projects/e2e-project/reporter/schedules/1` | After "Send a test": the flash confirms and a mail is written |
| ![](delivery-schedule-deleted.png) | manager | `/projects/e2e-project/reporter/schedules` | After deleting the weekly schedule: the deletion notice and the list without it |
| ![](delivery-reporter-refused.png) | reporter | `/projects/e2e-project/reporter/mail/new?template_id=1` | Reporter: schedules and ad hoc mail are refused (403) |
| ![](delivery-outsider-private.png) | outsider | `/projects/e2e-private/reporter/schedules` | Outsider: schedules of the private project are refused (403) |
