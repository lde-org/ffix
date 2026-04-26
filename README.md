# ffix

This is a namespaced version of the `ffi` library for LuaJIT.

It works by parsing your C code and individually renaming types and symbols to be namespaced to an `ffix.context()`.

This solves the issue of ffi redefinition fears that are all too common with a large amount of ffi definitions in LuaJIT.

## Usage

Set up [lde](https://lde.sh)

```
lde add ffix --git https://github.com/lde-org/ffix
```

## Development

This library is used by `lde` itself to sandbox `ffi` so that its own declarations do not conflict with package declarations.

However, this means that is there's any issues with ffix, they will remain in the binary and cause problems with development of ffix itself, since it would now be using the old version for `require("ffi")`

This can be avoided via an escape hatch as so: `local ffi = getmetatable(package.loaded.ffi).__index` to get the original luajit ffi library without ffix detours.
