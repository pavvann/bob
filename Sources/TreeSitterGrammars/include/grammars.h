//
//  grammars.h
//  The tree-sitter parsers in the CodeLanguagesContainer archive.
//
//  All forty are declared here because a prototype costs nothing — a declaration
//  nobody calls emits no code and pulls no archive member. What decides the size
//  of Bob.app is which of them something *references*: see the table in
//  SyntaxHighlighter.swift for the ten bob ships, and grammars.c for how the
//  other thirty are kept out of the binary.
//
//  bob declares these itself rather than importing the grammar package's
//  `CodeLanguage`, whose parser lookup is one switch over all forty cases. Link
//  that switch and all forty parsers come with it — 101MB of Bob.app.
//

#ifndef BOB_TREE_SITTER_GRAMMARS_H
#define BOB_TREE_SITTER_GRAMMARS_H

/// Opaque here exactly as it is in tree-sitter's own public header. bob never
/// looks inside a grammar, it only hands the pointer to SwiftTreeSitter — and
/// leaving the struct incomplete is what makes Swift import these functions as
/// returning `OpaquePointer`, which is the type `Language(language:)` wants.
typedef struct TSLanguage TSLanguage;

#ifdef __cplusplus
extern "C" {
#endif

TSLanguage *tree_sitter_agda(void);
TSLanguage *tree_sitter_bash(void);
TSLanguage *tree_sitter_c(void);
TSLanguage *tree_sitter_cpp(void);
TSLanguage *tree_sitter_c_sharp(void);
TSLanguage *tree_sitter_css(void);
TSLanguage *tree_sitter_dart(void);
TSLanguage *tree_sitter_dockerfile(void);
TSLanguage *tree_sitter_elixir(void);
TSLanguage *tree_sitter_go(void);
TSLanguage *tree_sitter_gomod(void);
TSLanguage *tree_sitter_haskell(void);
TSLanguage *tree_sitter_html(void);
TSLanguage *tree_sitter_java(void);
TSLanguage *tree_sitter_javascript(void);
TSLanguage *tree_sitter_jsdoc(void);
TSLanguage *tree_sitter_json(void);
TSLanguage *tree_sitter_julia(void);
TSLanguage *tree_sitter_kotlin(void);
TSLanguage *tree_sitter_lua(void);
TSLanguage *tree_sitter_markdown(void);
TSLanguage *tree_sitter_markdown_inline(void);
TSLanguage *tree_sitter_objc(void);
TSLanguage *tree_sitter_ocaml(void);
TSLanguage *tree_sitter_ocaml_interface(void);
TSLanguage *tree_sitter_perl(void);
TSLanguage *tree_sitter_php(void);
TSLanguage *tree_sitter_python(void);
TSLanguage *tree_sitter_regex(void);
TSLanguage *tree_sitter_ruby(void);
TSLanguage *tree_sitter_rust(void);
TSLanguage *tree_sitter_scala(void);
TSLanguage *tree_sitter_sql(void);
TSLanguage *tree_sitter_swift(void);
TSLanguage *tree_sitter_toml(void);
TSLanguage *tree_sitter_tsx(void);
TSLanguage *tree_sitter_typescript(void);
TSLanguage *tree_sitter_verilog(void);
TSLanguage *tree_sitter_yaml(void);
TSLanguage *tree_sitter_zig(void);

#ifdef __cplusplus
}
#endif

#endif /* BOB_TREE_SITTER_GRAMMARS_H */
