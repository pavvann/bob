//
//  grammars.c
//  The thirty grammars bob does not ship — defined here, so the linker never
//  goes looking for them.
//
//  Each tree-sitter parser is its own object file in the CodeLanguagesContainer
//  archive (TreeSitterSwift.o, TreeSitterKotlin.o, …) and a static archive only
//  gives up a member when a symbol is still undefined. bob references ten entry
//  points, so ten members would be enough — except the grammar package's own
//  `CodeLanguage` names all forty in one switch, and SwiftPM hands the linker
//  that Swift object as a loose `.o` rather than an archive. Every global in a
//  loose object is a dead-strip root, so those references stay live no matter
//  what: the linker pulls all forty parsers, `-dead_strip` keeps them, `strip`
//  recovers 4MB of 101MB, and Bob.app is sixteen times bigger than the app.
//
//  A definition ends the search. With the thirty below already resolved, the
//  linker never loads their archive members and their parse tables never reach
//  the binary. `NULL` is also the honest answer: it is what the package's own
//  lookup returns for a language it has no parser for, and bob renders any
//  language it can't parse as plain text.
//
//  TO ADD A LANGUAGE: delete its `SKIP` line here, then add a row to
//  `SyntaxLanguage.all` in SyntaxHighlighter.swift. Forget the deletion and the
//  language quietly renders plain — the syntax harness asserts that every row in
//  that table resolves a real grammar, so it will say so.
//

#include "grammars.h"

#define SKIP(name) TSLanguage *tree_sitter_##name(void) { return 0; }

SKIP(agda)
SKIP(c)
SKIP(cpp)
SKIP(c_sharp)
SKIP(css)
SKIP(dart)
SKIP(dockerfile)
SKIP(elixir)
SKIP(gomod)
SKIP(haskell)
SKIP(html)
SKIP(java)
SKIP(jsdoc)
SKIP(julia)
SKIP(kotlin)
SKIP(lua)
SKIP(markdown)
SKIP(markdown_inline)
SKIP(objc)
SKIP(ocaml)
SKIP(ocaml_interface)
SKIP(perl)
SKIP(php)
SKIP(regex)
SKIP(ruby)
SKIP(scala)
SKIP(sql)
SKIP(toml)
SKIP(verilog)
SKIP(zig)

#undef SKIP
