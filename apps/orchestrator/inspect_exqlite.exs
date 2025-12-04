{:ok, _} = Application.ensure_all_started(:exqlite)
IO.inspect(Exqlite.Sqlite3.module_info(:exports), label: "Exqlite.Sqlite3 exports")
IO.inspect(Application.spec(:exqlite, :vsn), label: "Exqlite version")
