defmodule Oracle.Domain do
  use Ash.Domain

  resources do
    resource(Oracle.User)
    resource(Oracle.Token)
  end
end
