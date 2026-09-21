# Mix commands worth knowing

| Command | What it does |
|---|---|
| `mix compile --warnings-as-errors` | compiles, failing on any warning |
| `mix format --check-formatted` | says which files the formatter would change |
| `mix test path/to/file_test.exs:LINE` | one test |
| `mix test --failed` | the tests that failed last time |
| `mix ecto.gen.migration name` | a new migration file |
| `mix ecto.migrate` / `mix ecto.rollback` | apply or undo migrations |
| `mix deps.get` / `mix deps.update name` | fetch or update dependencies |
| `mix xref graph --sink lib/app/thing.ex` | who depends on a file |
