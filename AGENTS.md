# AGENTS.md

pocket-kit is a small kit of pieces for self-hosted phone web apps: a Rails engine (this gem) plus a copy-in Python module and templates.

## Commands

- Install: `bundle install`
- Unit and integration tests: `bundle exec rake test`
- Browser (system) tests, needs Chrome or Chromium: `bundle exec rake test:system`
- Python helper tests: `(cd python && python -m unittest -v)`
- Build the gem: `gem build pocket_kit.gemspec -o /tmp/pocket_kit.gem`

There is no lint or typecheck setup.

## Layout

- `lib/`, `app/`, `config/`: the Rails engine; `test/dummy` is the host app used by tests.
- `python/pocket_kit.py`: the copy-in Python helper, with `python/test_pocket_kit.py`.
- `templates/` and `docs/local-app-pattern.md`: the app pattern and its start script, service and env files.

## Working rules

- Put temporary probes, scratch tests and generated output under /tmp or a gitignored directory, and make sure `git status` is clean of them before reporting work done.
- Report checks as passed only after every check has finished and exited 0; name any check you did not run.
