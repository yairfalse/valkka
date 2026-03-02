defmodule Kanni.Git.Types do
  @moduledoc """
  Core domain types for git data.
  """

  defmodule Commit do
    @moduledoc "A git commit."
    @type t :: %__MODULE__{
            oid: String.t(),
            message: String.t(),
            author: String.t(),
            timestamp: DateTime.t(),
            parents: [String.t()]
          }
    defstruct [:oid, :message, :author, :timestamp, parents: []]
  end

  defmodule Branch do
    @moduledoc "A git branch reference."
    @type t :: %__MODULE__{
            name: String.t(),
            head: String.t(),
            upstream: String.t() | nil,
            is_current: boolean()
          }
    defstruct [:name, :head, :upstream, is_current: false]
  end

  defmodule FileDelta do
    @moduledoc "A file change in the working directory or between commits."
    @type status :: :added | :modified | :deleted | :renamed | :copied | :untracked
    @type t :: %__MODULE__{
            path: String.t(),
            old_path: String.t() | nil,
            status: status()
          }
    defstruct [:path, :old_path, :status]
  end

  defmodule RepoStatus do
    @moduledoc "Aggregate status of a repository."
    @type t :: %__MODULE__{
            branch: String.t() | nil,
            deltas: [FileDelta.t()],
            ahead: non_neg_integer(),
            behind: non_neg_integer()
          }
    defstruct [:branch, deltas: [], ahead: 0, behind: 0]
  end

  defmodule GraphNode do
    @moduledoc "A positioned commit node in the graph layout."
    @type t :: %__MODULE__{
            oid: String.t(),
            short_oid: String.t(),
            column: non_neg_integer(),
            row: non_neg_integer(),
            message: String.t(),
            author: String.t(),
            timestamp: DateTime.t(),
            branches: [String.t()],
            is_merge: boolean(),
            parents: [String.t()]
          }
    defstruct [
      :oid,
      :short_oid,
      :column,
      :row,
      :message,
      :author,
      :timestamp,
      branches: [],
      is_merge: false,
      parents: []
    ]
  end

  defmodule GraphLayout do
    @moduledoc "Complete graph layout with positioned nodes and edge metadata."
    @type t :: %__MODULE__{
            nodes: [GraphNode.t()],
            edges: [map()],
            max_columns: non_neg_integer(),
            branches: [String.t()],
            total_commits: non_neg_integer()
          }
    defstruct nodes: [], edges: [], max_columns: 0, branches: [], total_commits: 0
  end
end
