defmodule PtcRunner.Lisp.TemporaryDirectory do
  @moduledoc """
  Exclusive random temporary directories for compiler and oracle scratch work.

  Creation checks trusted, non-replaceable ancestry and verifies ownership
  and mode 0700. Existing names are retried without
  adopting or removing them; the caller owns cleanup. Hosts may supply their
  own directory creator to enforce additional parent and ownership policy.
  """

  alias PtcRunner.Lisp.DirectoryCreation

  @spec create(binary(), non_neg_integer(), (binary() -> :ok | {:error, term()})) ::
          {:ok, binary()} | {:error, term()}
  def create(prefix, attempts \\ 10, creator \\ &DirectoryCreation.create/1)
  def create(_prefix, 0, _creator), do: {:error, :private_directory_creation_failed}

  def create(prefix, attempts, creator) when is_binary(prefix) and attempts > 0 do
    if prefix != "" and Path.basename(prefix) == prefix do
      path =
        Path.join(
          System.tmp_dir!(),
          prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
        )

      case creator.(path) do
        :ok -> {:ok, path}
        {:error, :eexist} -> create(prefix, attempts - 1, creator)
        {:error, _reason} = error -> error
      end
    else
      {:error, :private_directory_creation_failed}
    end
  rescue
    _exception -> {:error, :private_directory_creation_failed}
  end
end
