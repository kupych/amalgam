# Amalgam

A semantic merge driver for Elixir code.

## The Problem

Git's default merge strategy is line-based, which doesn't understand Elixir. When you and a coworker both add a function in the same spot, you get:

```elixir
def my_function do
def their_function do
  :my_thing
  :their_thing
end
```

"There's gotta be a better way!" 

And now, there is.
  
## Installation

```bash
mix escript.install hex amalgam
mix amalgam.install
```

Add to your project's `.gitattributes`:

```
*.ex merge=amalgam
*.exs merge=amalgam
```

##License

MIT License. See the LICENSE file for details.
