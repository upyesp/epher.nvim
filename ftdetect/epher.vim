" Filetype detection for epher (ADR-0066: ready-made configs, not
" plugins). Point your runtimepath at clients/vim/ and .epher files
" become epher buffers; the ftplugin and syntax files take it from
" there.

au BufRead,BufNewFile *.epher set filetype=epher
