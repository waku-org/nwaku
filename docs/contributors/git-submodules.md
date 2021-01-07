# Submodules

We use Git submodules in the `vendor` directory to track internal Nim
dependencies. We want to update submodules all at once to avoid issues.

```
git submodule foreach --recursive git submodule update --init
git submodule update --remote
```

