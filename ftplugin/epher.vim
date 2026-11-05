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

  " The pane's colors over the user's scheme (ADR-0078): the setup
  " echo dims to Comment, the answer reads bold (EpherAnswer); the
  " failure tier keeps ErrorMsg, as it always has.
  if !hlexists("EpherSetup")
    highlight default link EpherSetup Comment
  endif
  if !hlexists("EpherAnswer")
    highlight default EpherAnswer term=bold cterm=bold gui=bold
  endif

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

  " One matrix as padded grid rows (ADR-0078 R3): each cell padded
  " to its column's width, columns joined with two spaces; the wire
  " prefix rides the first row, the suffix the last, continuation
  " rows the hang indent so they align under the text.
  function! s:epher_grid_body(grid, hang) abort
    let l:out = []
    let l:last = len(a:grid.cells)
    for l:i in range(l:last)
      let l:row = a:grid.cells[l:i]
      let l:cells = []
      for l:c in range(len(l:row))
        let l:cell = l:row[l:c]
        let l:w = get(get(a:grid, "widths", []), l:c, strchars(l:cell))
        call add(l:cells, repeat(" ", max([0, l:w - strchars(l:cell)])) . l:cell)
      endfor
      let l:line = (l:i == 0 ? get(a:grid, "prefix", "") : repeat(" ", a:hang)) . join(l:cells, "  ")
      if l:i == l:last - 1
        let l:line .= get(a:grid, "suffix", "")
      endif
      call add(l:out, l:line)
    endfor
    if empty(l:out)
      call add(l:out, get(a:grid, "prefix", "") . get(a:grid, "suffix", ""))
    endif
    return l:out
  endfunction

  " A long list folded at the threshold (ADR-0078 R3): shown elements
  " with a (+n more) note, the hidden tail on its own rows (folded by
  " the caller), so nothing is lost and nothing shouts. Returns
  " [rows, tail_rows].
  function! s:epher_list_body(list, width, hang) abort
    let l:elements = get(a:list, "elements", [])
    let l:hidden = get(a:list, "hidden", 0)
    let l:shown_count = max([0, len(l:elements) - l:hidden])
    let l:shown = l:shown_count > 0 ? l:elements[: l:shown_count - 1] : []
    let l:note = l:hidden > 0 ? printf(" (+%d more)", l:hidden) : ""
    let l:rows = [get(a:list, "prefix", "") . "{ " . join(l:shown, ", ") . " }" . l:note . get(a:list, "suffix", "")]
    let l:tail_rows = 0
    if l:hidden > 0
      " The hidden tail, wrapped on element boundaries to the width.
      let l:line = ""
      let l:open = 0
      for l:i in range(l:shown_count, len(l:elements) - 1)
        let l:piece = l:elements[l:i] . (l:i < len(l:elements) - 1 ? ", " : "")
        if !l:open
          let l:line = l:piece
          let l:open = 1
        elseif strchars(l:line) + strchars(l:piece) <= a:width - a:hang
          let l:line .= l:piece
        else
          call add(l:rows, repeat(" ", a:hang) . l:line)
          let l:tail_rows += 1
          let l:line = l:piece
        endif
      endfor
      if l:open
        call add(l:rows, repeat(" ", a:hang) . l:line)
        let l:tail_rows += 1
      endif
    endif
    return [l:rows, l:tail_rows]
  endfunction

  " The terminal pane's wrap (ADR-0078 R2), over the wire's
  " soft-break segments: rows no wider than width, continuation rows
  " indented hang spaces, breaks never inside a number.
  function! s:epher_wrap_segments(segments, width, hang, plain_text) abort
    let l:width = a:width < 8 ? 8 : a:width
    let l:indent = repeat(" ", a:hang > l:width ? l:width : a:hang)
    let l:segs = deepcopy(a:segments)
    if !empty(l:segs) && a:plain_text !~# '^= ' && strpart(get(l:segs, 0, ""), 0, 2) ==# '= '
      " Prose shed the `= ` voice in the pane text; the segments (from
      " the verbatim display) keep it, so the first segment sheds it
      " too when the text does not carry it.
      let l:segs[0] = strpart(l:segs[0], 2)
    endif
    let l:rows = []
    let l:current = ""
    let l:has_content = 0
    let l:continuation = 0
    for l:seg in l:segs
      for l:word in split(l:seg, ' ')
        let l:rest = l:word
        while !empty(l:rest)
          if !l:has_content && l:continuation && empty(l:current)
            let l:current = l:indent
          endif
          let l:fresh = (!l:has_content && l:continuation) ? l:width - strchars(l:indent) : l:width
          let l:budget = l:has_content ? l:width - strchars(l:current) - 1 : l:fresh
          if l:budget < 1
            let l:budget = 1
          endif
          let l:len = strchars(l:rest)
          if l:len <= l:budget
            let l:take = l:len
          elseif l:len <= l:fresh
            let l:take = 0
          else
            let l:take = l:budget
          endif
          if l:take <= 0
            if l:has_content
              call add(l:rows, l:current)
              let l:current = ""
              let l:has_content = 0
            endif
            let l:continuation = 1
          else
            if l:has_content
              let l:current .= " "
            endif
            let l:current .= strcharpart(l:rest, 0, l:take)
            let l:has_content = 1
            let l:rest = strcharpart(l:rest, l:take)
            if !empty(l:rest)
              call add(l:rows, l:current)
              let l:current = ""
              let l:has_content = 0
              let l:continuation = 1
            endif
          endif
        endwhile
      endfor
    endfor
    if l:has_content
      call add(l:rows, l:current)
    endif
    if empty(l:rows)
      call add(l:rows, "")
    endif
    return l:rows
  endfunction

  " The rows for one report (ADR-0069 amendment): each display line's
  " presentation applied with the toolkit's own means. Without a
  " presentation (an older server) the verbatim display stands
  " alone, as before. Returns [rows, src_lines, graphs, verbatim,
  " tiers, answer_rows, folds].
  function! s:epher_render_rows(report, width) abort
    let l:rows = []
    let l:src_lines = {}
    let l:graphs = {}
    let l:verbatim = {}
    let l:tiers = {}
    let l:answer_rows = []
    let l:folds = []
    " The "L<line> " label's width, so wrapped, grid, and folded rows
    " align under the text they belong to.
    let l:hang = 7
    for l:statement in get(a:report, "statements", [])
      if !has_key(l:statement, "display")
        continue
      endif
      let l:label = printf("L%-5d ", l:statement.line + 1)
      let l:first_row = len(l:rows) + 1
      let l:present = get(l:statement, "presentation", {})
      let l:answer = !empty(get(l:present, "answer", 0))
      if has_key(l:present, "lines") && !empty(l:present.lines)
        for l:pane in l:present.lines
          let l:glyph = ""
          if has_key(l:pane, "verdict")
            let l:glyph = l:pane.verdict ? "✓ " : "✗ "
          endif
          let l:tail_rows = 0
          if has_key(l:pane, "grid")
            let l:body = s:epher_grid_body(l:pane.grid, l:hang)
          elseif has_key(l:pane, "list")
            let [l:body, l:tail_rows] = s:epher_list_body(l:pane.list, a:width, l:hang)
          else
            let l:body = s:epher_wrap_segments(get(l:pane, "segments", []), a:width, l:hang, get(l:pane, "text", ""))
          endif
          for l:bi in range(len(l:body))
            call add(l:rows, l:bi == 0 ? (l:label . l:glyph . l:body[l:bi]) : l:body[l:bi])
            let l:r = len(l:rows)
            let l:src_lines[l:r] = l:statement.line + 1
            let l:graphs[l:r] = ""
            let l:verbatim[l:r] = l:statement.display
            let l:tiers[l:r] = get(l:pane, "kind", "labeled")
          endfor
          " list_body's tail rows sit at the body's end: fold them.
          if l:tail_rows > 0
            call add(l:folds, [len(l:rows) - l:tail_rows + 1, len(l:rows)])
          endif
        endfor
      else
        call add(l:rows, l:label . l:statement.display)
        let l:r = len(l:rows)
        let l:src_lines[l:r] = l:statement.line + 1
        let l:graphs[l:r] = ""
        let l:verbatim[l:r] = l:statement.display
        if get(l:statement, "error", v:false)
          let l:tiers[l:r] = "error"
        endif
      endif
      if l:answer
        for l:r in range(l:first_row, len(l:rows))
          call add(l:answer_rows, l:r)
        endfor
      endif
    endfor
    return [l:rows, l:src_lines, l:graphs, l:verbatim, l:tiers, l:answer_rows, l:folds]
  endfunction

  " y in the results pane: yank the row's verbatim statement output
  " (ADR-0078's first rule: copy never sees the shaped text).
  function! s:epher_copy_verbatim() abort
    let l:row = line(".")
    let l:v = get(getbufvar(bufnr("%"), "epher_verbatim", {}), l:row, "")
    if empty(l:v)
      return
    endif
    call setreg('"', l:v)
    if has("clipboard")
      call setreg("+", l:v)
    endif
    echom "epher: copied the verbatim output"
  endfunction

  " CursorHold in the results pane: the row's verbatim output in a
  " popup when it differs from the rendered text (wrapped or folded
  " rows hide it). Needs the 8.2 popups; without them, no hover.
  function! s:epher_hover() abort
    if !exists("*popup_atcursor")
      return
    endif
    let l:row = line(".")
    let l:v = get(getbufvar(bufnr("%"), "epher_verbatim", {}), l:row, "")
    if empty(l:v) || l:v ==# getline(l:row)
      return
    endif
    call popup_atcursor(split(l:v, "\n"), #{moved: "any", border: [], padding: [0, 1, 0, 1]})
  endfunction

  " Renders one report into a fresh scratch buffer beside the script.
  " a:src_bufnr is the script; a:report is the epher/run result:
  " {'statements': [{'line': 0, 'display': '= 5', 'error': v:false,
  "  'presentation': {'lines': [{'text': ..., 'kind': 'labeled',
  "  'verdict': v:true, 'grid': {...}, 'list': {...}, 'segments': [...]}],
  "  'answer': v:false}}], 'svgs': ['<svg...'], 'answerLine': 3}
  function! s:epher_show_report(src_bufnr, report) abort
    " The window opens first: the rows wrap to the real pane width
    " (ADR-0078 R2).
    execute "rightbelow vnew"
    let l:width = winwidth(0)
    let [l:rows, l:src_lines, l:graphs, l:verbatim, l:tiers, l:answer_rows, l:folds] =
          \ s:epher_render_rows(a:report, l:width)
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
    setlocal buftype=nofile
    setlocal bufhidden=wipe
    setlocal noswapfile
    setlocal nobuflisted
    setlocal modifiable
    setlocal foldmethod=manual
    setlocal foldcolumn=0
    call setline(1, l:rows)
    " The hidden list tails fold away (ADR-0078 R3), while the
    " buffer is still modifiable: a fold changes no text, but a
    " closed fold keeps the rules simple.
    for l:f in l:folds
      execute l:f[0] . "," . l:f[1] . "fold"
    endfor
    if !empty(l:folds)
      silent! normal! zM
    endif
    setlocal nomodifiable
    execute "file epher results: " . (empty(l:name) ? "untitled" : l:name)
    " The tiers (ADR-0078) and the answer emphasis (R4), after the
    " text exists. matchaddpos takes eight lines a call, so the
    " loops walk row by row; the results window is the current one.
    let l:error_rows = []
    let l:setup_rows = []
    for l:r in range(1, len(l:rows))
      if get(l:tiers, l:r, "") ==# "error"
        call add(l:error_rows, l:r)
      elseif get(l:tiers, l:r, "") ==# "setup"
        call add(l:setup_rows, l:r)
      endif
    endfor
    for l:r in l:error_rows
      call matchaddpos("ErrorMsg", [l:r])
    endfor
    for l:r in l:setup_rows
      call matchaddpos("EpherSetup", [l:r])
    endfor
    for l:r in l:answer_rows
      call matchaddpos("EpherAnswer", [l:r])
    endfor
    call setbufvar("%", "epher_src_bufnr", a:src_bufnr)
    call setbufvar("%", "epher_src_lines", l:src_lines)
    call setbufvar("%", "epher_graphs", l:graphs)
    call setbufvar("%", "epher_verbatim", l:verbatim)
    nnoremap <buffer><nowait><silent> <CR> :<C-u>call <SID>epher_follow()<CR>
    nnoremap <buffer><nowait><silent> r     :<C-u>call <SID>epher_rerun()<CR>
    nnoremap <buffer><nowait><silent> y     :<C-u>call <SID>epher_copy_verbatim()<CR>
    autocmd CursorHold <buffer> call <SID>epher_hover()
    " The run's answer carries the weight (ADR-0078 R4/R5): the
    " cursor lands on it, so the pane opens scrolled to what matters.
    if !empty(l:answer_rows)
      call cursor(l:answer_rows[0], 1)
    endif
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
