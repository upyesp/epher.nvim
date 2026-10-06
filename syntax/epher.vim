" Vim syntax for epher: the configuration-level view of the language
" (ADR-0066 ships Neovim and Vim as ready-made configs, not plugins).
" The twenty keywords mirror crates/core KEYWORDS; numbers cover
" decimal, scientific, the 0b/0o/0x bases, and the imaginary `i`
" suffix; strings honor the five escapes; unit suffixes are matched
" conservatively (identifier immediately after a number with no
" separator, never a call), which is the parser's own adjacency
" rule. The language server's semantic tokens are the exact rule.

if exists("b:current_syntax")
  finish
endif

" Comments: the three forms the lexer takes.
syntax match epherComment "#.*$" contains=epherTodo
syntax match epherComment "//.*$" contains=epherTodo
syntax region epherComment start="/\*" end="\*/" contains=epherTodo
syntax keyword epherTodo contained TODO FIXME XXX NOTE

" Strings: double-quoted, five escapes: \n \t \r \\ \".
syntax match epherStringEscape "\\[ntr\\\"]" contained
syntax region epherString start=+"+ skip=+\\.+ end=+"+ contains=epherStringEscape

" Numbers: decimal, scientific, 0b/0o/0x, and the imaginary `i`.
syntax match epherNumber "\v<0[bB][01]+>"
syntax match epherNumber "\v<0[oO][0-7]+>"
syntax match epherNumber "\v<0[xX][0-9a-fA-F]+>"
syntax match epherNumber "\v<\d+(\.\d+)?([eE][-+]?\d+)?>"
syntax match epherNumber "\v<\d+(\.\d+)?([eE][-+]?\d+)?i>"

" Keywords (crates/core KEYWORDS, verbatim).
syntax keyword epherKeyword and break const continue def do else end for if in not or return solve step then to while xor

" Statement commands (graph, graph3d, solar3d, save, table): not
" grammar keywords, but a line opening with one is a shell-level
" statement, so it colors like one. The language server's
" statement-start rule is the exact one; line start is this
" grammar's approximation.
syntax match epherCommand "\v^\s*<(graph3d|solar3d|graph|save|table)>"

" Units: an identifier immediately after a number (the whitespace
" run between them is what the parser's adjacency rule allows),
" never a call (no `(` follows), and never containing digits (the
" parser rejects `2 m3`). Conservative on purpose; the language
" server's semantic tokens are the exact rule.
syntax match epherUnit "\v\d[ \t]+\zs[A-Za-z_]+(\i|\()@!"

" Operators.
syntax match epherOperator "\v[+\-*/%^=!<>]"

" Names and calls.
syntax match epherName "\v<[A-Za-z_]\w*>"
syntax match epherCall "\v<[A-Za-z_]\w*>\ze[ \t]*\("

hi def link epherComment Comment
hi def link epherTodo Todo
hi def link epherString String
hi def link epherStringEscape SpecialChar
hi def link epherNumber Number
hi def link epherKeyword Keyword
hi def link epherCommand Keyword
hi def link epherUnit Type
hi def link epherOperator Operator
hi def link epherCall Function
hi def link epherName Identifier

let b:current_syntax = "epher"
