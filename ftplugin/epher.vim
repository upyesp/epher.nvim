" Buffer settings for epher buffers: the comment form the lexer
" takes, word characters that keep `x1` and `sin_x` whole, and no
" automatic formatting surprises.

setlocal commentstring=#\ %s
setlocal iskeyword+=_
setlocal formatoptions-=t
setlocal suffixesadd=.epher

if !exists("b:undo_ftplugin")
  let b:undo_ftplugin = ""
endif
let b:undo_ftplugin .=
      \ "| setlocal commentstring< iskeyword< formatoptions< suffixesadd<"

" Neovim gets its lsp wiring and :EpherRun from the nvim client
" (epher-nvim/lua/epher.lua); this ftplugin would only shadow them
" with the vim-lsp variant, so under nvim it contributes just the
" buffer settings above and stops here.
if has("nvim")
  finish
endif

" ----------------------------------------------------------------------
" Running scripts (ADR-0069, decision 3: the text-first editors run the
" same `epher/run` request the VS Code results pane uses). The transport
" is the vim-lsp plugin when it is installed; the syntax layer above
" works without it, and :EpherRun says so plainly when it is missing.

if !exists("g:loaded_epher_ftplugin_run")
  let g:loaded_epher_ftplugin_run = 1

  function! s:epher_results_dir() abort
    if has("win32")
      let l:base = !empty($LOCALAPPDATA) ? $LOCALAPPDATA : expand("~/AppData/Local")
    else
      let l:base = !empty($XDG_CACHE_HOME) ? $XDG_CACHE_HOME : expand("~/.cache")
    endif
    return l:base . "/epher/runs"
  endfunction

  function! s:epher_open(path) abort
    let l:opener = has("mac") ? "open" : "xdg-open"
    if !executable(l:opener)
      echom "epher: no " . l:opener . " found; the graph is at " . a:path
      return
    endif
    if has("job")
      call job_start([l:opener, a:path])
    else
      call system(l:opener . " " . shellescape(a:path) . " &")
    endif
  endfunction

  " <CR> in the results pane: a graph row reopens its SVG, a result
  " row jumps to its statement in the script, r re-runs.
  function! s:epher_follow() abort
    let l:row = line(".")
    let l:graphs = getbufvar(bufnr("%"), "epher_graphs", {})
    if has_key(l:graphs, l:row) && !empty(l:graphs[l:row])
      call s:epher_open(l:graphs[l:row])
      return
    endif
    let l:src_lines = getbufvar(bufnr("%"), "epher_src_lines", {})
    if !has_key(l:src_lines, l:row) || l:src_lines[l:row] <= 0
      return
    endif
    let l:src = getbufvar(bufnr("%"), "epher_src_bufnr", -1)
    if l:src < 0 || !bufexists(l:src)
      return
    endif
    let l:win = bufwinnr(l:src)
    if l:win < 0
      return
    endif
    execute l:win . "wincmd w"
    call cursor(min([l:src_lines[l:row], line("$")]), 1)
  endfunction

  function! s:epher_rerun() abort
    let l:src = getbufvar(bufnr("%"), "epher_src_bufnr", -1)
    if l:src >= 0 && bufexists(l:src)
      call s:EpherRun(l:src)
    endif
  endfunction

  " Renders one report into a fresh scratch buffer beside the script.
  " a:src_bufnr is the script; a:report is the epher/run result:
  " {'statements': [{'line': 0, 'display': '= 5', 'error': v:false}],
  "  'svgs': ['<svg...']}
  function! s:epher_show_report(src_bufnr, report) abort
    let l:rows = []
    let l:src_lines = {}
    let l:graphs = {}
    let l:error_rows = []
    for l:statement in get(a:report, "statements", [])
      if has_key(l:statement, "display")
        " The wire carries 0-based lines; humans count from 1.
        call add(l:rows, printf("L%-5d %s", l:statement.line + 1, l:statement.display))
        let l:src_lines[len(l:rows)] = l:statement.line + 1
        if get(l:statement, "error", v:false)
          call add(l:error_rows, len(l:rows))
        endif
      endif
    endfor
    let l:svgs = get(a:report, "svgs", [])
    if !empty(l:svgs)
      let l:dir = s:epher_results_dir()
      call mkdir(l:dir, "p")
      call add(l:rows, "")
      call add(l:rows, printf("Graphs (%d, each opened with the system viewer):", len(l:svgs)))
      for l:i in range(len(l:svgs))
        let l:path = printf("%s/run-%d-%d.svg", l:dir, localtime(), l:i + 1)
        " writefile takes a String only on newer vims; split with the
        " keep-empty flag is the portable spelling of the same bytes.
        if writefile(split(l:svgs[l:i], "\n", 1), l:path) == 0
          call add(l:rows, "  " . l:path)
          let l:graphs[len(l:rows)] = l:path
          " The graph opens with the system viewer as soon as it is
          " written, like the other clients; the row above reopens it.
          call s:epher_open(l:path)
        endif
      endfor
    endif
    if empty(l:rows)
      let l:rows = ["No output."]
    endif

    let l:name = fnamemodify(bufname(a:src_bufnr), ":t")
    execute "rightbelow vnew"
    setlocal buftype=nofile
    setlocal bufhidden=wipe
    setlocal noswapfile
    setlocal nobuflisted
    setlocal modifiable
    call setline(1, l:rows)
    setlocal nomodifiable
    execute "file epher results: " . (empty(l:name) ? "untitled" : l:name)
    " Error rows, marked after the text exists.
    for l:row in l:error_rows
      call matchaddpos("ErrorMsg", [l:row])
    endfor
    call setbufvar("%", "epher_src_bufnr", a:src_bufnr)
    call setbufvar("%", "epher_src_lines", l:src_lines)
    call setbufvar("%", "epher_graphs", l:graphs)
    nnoremap <buffer><nowait><silent> <CR> :<C-u>call <SID>epher_follow()<CR>
    nnoremap <buffer><nowait><silent> r     :<C-u>call <SID>epher_rerun()<CR>
  endfunction

  function! s:epher_on_response(src_bufnr, response) abort
    if lsp#client#is_error(a:response['response'])
      let l:err = get(a:response['response'], 'error', {})
      echom "epher run failed: " . get(l:err, 'message', 'unknown error')
      return
    endif
    call s:epher_show_report(a:src_bufnr, get(a:response['response'], 'result', {}))
  endfunction

  " Runs the script in a:bufnr (default: the current buffer, or the
  " script behind the results pane) through the attached server.
  function! EpherRun(...) abort
    let l:bufnr = a:0 > 0 && a:1 > 0 ? a:1 : bufnr("%")
    if getbufvar(l:bufnr, "&filetype") !=# "epher"
      let l:src = getbufvar(l:bufnr, "epher_src_bufnr", -1)
      if l:src >= 0 && bufexists(l:src) && getbufvar(l:src, "&filetype") ==# "epher"
        let l:bufnr = l:src
      else
        echom "epher: the current buffer is not an epher script"
        return
      endif
    endif
    if !exists("g:lsp_loaded")
      echom "epher: :EpherRun needs the vim-lsp plugin (github.com/prabirshrestha/vim-lsp); highlighting works without it"
      return
    endif
    let l:servers = lsp#get_allowed_servers(l:bufnr)
    if empty(l:servers)
      echom "epher: the language server is not attached; see :h lsp-setup"
      return
    endif
    let l:uri = lsp#utils#get_buffer_uri(l:bufnr)
    call lsp#send_request(l:servers[0], {
          \ 'method': 'epher/run',
          \ 'params': {'textDocument': {'uri': l:uri}},
          \ 'on_notification': function('s:epher_on_response', [l:bufnr]),
          \ })
  endfunction
endif

command! -buffer EpherRun call EpherRun()
