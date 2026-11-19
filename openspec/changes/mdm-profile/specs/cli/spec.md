## MODIFIED Requirements

### Requirement: service enable opens Login Items

When the login item needs approval, `signd service enable` SHALL open System Settings at Login Items and exit non-zero.
With `--at-login`, it SHALL never open System Settings.
It SHALL exit 0 while the item waits for approval, so the hook logs no failure at each login.

#### Scenario: Approval pending

- **WHEN** the login item needs approval and `signd service enable` runs
- **THEN** System Settings opens at Login Items and the command exits non-zero

#### Scenario: Approval pending at login

- **WHEN** the login item needs approval and `signd service enable --at-login` runs
- **THEN** System Settings stays closed, the command exits 0, and `signd status` shows the approval as missing
