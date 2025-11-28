# lib/mix/tasks/amalgam.install.ex

defmodule Mix.Tasks.Amalgam.Install do
  use Mix.Task

  @shortdoc "Installs Amalgam as a git merge driver"

  def run(_) do
    escript_path = Path.expand("~/.mix/escripts/amalgam")

    System.cmd("git", ["config", "--global", "merge.elixir.name", "Amalgam semantic merge"])
    System.cmd("git", ["config", "--global", "merge.elixir.driver", "#{escript_path} %O %A %B %P"])

    Mix.shell().info("""
    Amalgam installed!
    
    Add this to your project's .gitattributes:

        *.ex merge=elixir
        *.exs merge=elixir
    """)
  end
end
