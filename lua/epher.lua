-- Neovim glue for the shared epher language server (ADR-0066 ships
-- Neovim as a ready-made config, not a plugin). Works on Neovim 0.9
-- and newer: 0.9/0.10 attach through vim.lsp.start (the apt install
-- on current distributions is 0.9), 0.11+ uses the native
-- vim.lsp.config/vim.lsp.enable pair; the few API differences are
-- bridged in the compat helpers right below.
--
-- Usage:
--   vim.opt.rtp:append("/path/to/epher/clients/nvim")
--   vim.opt.rtp:append("/path/to/epher/clients/vim")  -- syntax + ft
--   require("epher").setup({ cmd = { "/path/to/epher-lsp" } })
--
-- The cmd default is `epher-lsp` on your PATH; the README has the
-- download lines per platform.
--
-- Running scripts (ADR-0069, decision 3: the text-first editors run
-- the same `epher/run` request the VS Code results pane uses, and
-- render the run's pane presentation in the results window with
-- Neovim's own means: tiers dim and red, verdict glyphs, matrix
-- grids, folded list tails, the answer bold under the cursor;
-- graphs are written as SVG files and opened with the system
-- viewer). `:EpherRun` does all of that for the current buffer;
-- setup({ pane = "float" }) puts the results in a floating window
-- instead of a vertical split.

local M = {}

M.ns = vim.api.nvim_create_namespace("epher-results")
M.augroup = vim.api.nvim_create_augroup("epher-results", { clear = false })

--- Neovim 0.11 split the attach API in two; 0.9 and 0.10 are the
--- vim.lsp.start generation. Everything below keys off this one
--- check, the way the emacs client keys off its jsonrpc version.
local has_lsp_config = vim.lsp.config ~= nil

--- The results buffer of the last run, so a rerun replaces it
--- instead of stacking windows.
local results_buf = nil
--- The epher clients attached to a buffer. 0.10 renamed
--- get_active_clients to get_clients; same filter arguments.
local function epher_clients(bufnr)
  if vim.lsp.get_clients ~= nil then
    return vim.lsp.get_clients({ bufnr = bufnr, name = "epher" })
  end
  return vim.lsp.get_active_clients({ bufnr = bufnr, name = "epher" })
end

--- Open a file with the system viewer. Every other epher client
--- hands the path straight to xdg-open (open on macOS). The stream
--- handlers matter: with no on_stdout/on_stderr, nvim connects the
--- child's output to closed fds, which makes xdg-open's gio dispatch
--- exit 0 without ever showing a window (observed on Cinnamon).
--- Buffered pipes keep the child healthy; the buffers are discarded.
local function open_path(path)
  local opener = vim.fn.has("mac") == 1 and "open" or "xdg-open"
  if vim.fn.executable(opener) == 0 then
    vim.notify("epher: no " .. opener .. " found; the graph is at " .. path, vim.log.levels.WARN)
    return
  end
  vim.fn.jobstart({ opener, path }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function() end,
    on_stderr = function() end,
    on_exit = function(_, code)
      if code ~= 0 then
        vim.notify(
          "epher: the system viewer could not open the graph (exit "
            .. code .. "); it is at " .. path,
          vim.log.levels.WARN
        )
      end
    end,
  })
end

--- One epher/run request, in whichever shape this Neovim speaks.
--- The handler receives (err, result) either way.
local function send_run(client, bufnr, params, handler)
  if has_lsp_config then
    -- 0.11+: the method form, (handled, request_id) return.
    local handled = client:request("epher/run", params, handler, bufnr)
    return handled and true or false
  end
  -- 0.9/0.10: the function form, boolean return.
  local sent = client.request("epher/run", params, handler, bufnr)
  return sent and true or false
end

--- <CR> in the results buffer: a row jumps to its statement, a
--- graph row reopens its SVG with the system viewer.
local function follow()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local ok_graphs, graphs = pcall(vim.api.nvim_buf_get_var, 0, "epher_graphs")
  if ok_graphs and type(graphs) == "table" and graphs[row] ~= nil and graphs[row] ~= "" then
    open_path(graphs[row])
    return
  end
  local ok_src, src_lines = pcall(vim.api.nvim_buf_get_var, 0, "epher_src_lines")
  if not (ok_src and type(src_lines) == "table" and (src_lines[row] or 0) > 0) then
    return
  end
  local ok_buf, src_bufnr = pcall(vim.api.nvim_buf_get_var, 0, "epher_src_bufnr")
  if not (ok_buf and vim.api.nvim_buf_is_valid(src_bufnr)) then
    return
  end
  local win = vim.fn.win_findbuf(src_bufnr)[1]
  if win == nil then
    return
  end
  vim.api.nvim_set_current_win(win)
  local last = vim.api.nvim_buf_line_count(src_bufnr)
  vim.api.nvim_win_set_cursor(win, { math.min(src_lines[row], last), 0 })
end

--- One matrix as padded grid rows (ADR-0078 R3): each cell padded
--- to its column's width, columns joined with two spaces; the wire
--- prefix rides the first row, the suffix the last, continuation
--- rows take the hang indent so they align under the text.
local function grid_body(grid, hang)
  local indent = string.rep(" ", hang)
  local out = {}
  local last = #grid.cells
  for i, row in ipairs(grid.cells) do
    local cells = {}
    for c, cell in ipairs(row) do
      local w = (grid.widths or {})[c] or #cell
      local pad = w - #cell
      if pad < 0 then pad = 0 end
      cells[c] = string.rep(" ", pad) .. cell
    end
    local line = (i == 1 and (grid.prefix or "") or indent) .. table.concat(cells, "  ")
    if i == last then line = line .. (grid.suffix or "") end
    out[i] = line
  end
  if #out == 0 then out[1] = (grid.prefix or "") .. (grid.suffix or "") end
  return out
end

--- A long list folded at the threshold (ADR-0078 R3): the shown
--- elements carry a (+n more) note and the hidden tail lands on its
--- own rows (folded away by the caller), so nothing is lost and
--- nothing shouts. Returns the body rows and how many tail rows sit
--- past the fold.
local function list_body(list, width, hang)
  local elements = list.elements or {}
  local hidden = list.hidden or 0
  local shown_count = math.max(0, #elements - hidden)
  local shown = {}
  for i = 1, shown_count do shown[i] = elements[i] end
  local note = hidden > 0 and string.format(" (+%d more)", hidden) or ""
  local head = (list.prefix or "") .. "{ " .. table.concat(shown, ", ") .. " }" .. note .. (list.suffix or "")
  local rows = { head }
  local tail_rows = 0
  if hidden > 0 then
    -- The hidden tail, wrapped on element boundaries to the pane width.
    local line = nil
    for i = shown_count + 1, #elements do
      local piece = elements[i] .. (i < #elements and ", " or "")
      if line == nil then
        line = piece
      elseif #line + #piece <= width - hang then
        line = line .. piece
      else
        rows[#rows + 1] = string.rep(" ", hang) .. line
        tail_rows = tail_rows + 1
        line = piece
      end
    end
    if line ~= nil then
      rows[#rows + 1] = string.rep(" ", hang) .. line
      tail_rows = tail_rows + 1
    end
  end
  return rows, tail_rows
end

--- The terminal pane's wrap (ADR-0078 R2), over the wire's
--- soft-break segments: rows no wider than `width`, continuation
--- rows indented `hang` spaces, breaks never inside a number.
local function wrap_segments(segments, width, hang, plain_text)
  width = math.max(width or 80, 8)
  local indent = string.rep(" ", math.min(hang, width))
  local segs = {}
  for i, s in ipairs(segments or {}) do segs[i] = s end
  -- Prose shed the `= ` voice in the pane text; the segments (from
  -- the verbatim display) keep it, so the first segment sheds it too
  -- when the text does not carry it.
  if #segs > 0 and plain_text ~= nil and not plain_text:match("^= ") and segs[1]:sub(1, 2) == "= " then
    segs[1] = segs[1]:sub(3)
  end
  local rows, current, has_content, continuation = {}, "", false, false
  for _, seg in ipairs(segs) do
    for word in seg:gmatch("[^ ]+") do
      local rest = word
      while #rest > 0 do
        if not has_content and continuation and #current == 0 then
          current = indent
        end
        local fresh = (not has_content and continuation) and (width - #indent) or width
        local budget = has_content and (width - #current - 1) or fresh
        if budget < 1 then budget = 1 end
        local take
        if #rest <= budget then take = #rest
        elseif #rest <= fresh then take = 0
        else take = budget end
        if take == 0 then
          if has_content then
            rows[#rows + 1] = current
            current, has_content = "", false
          end
          continuation = true
        else
          local tail = #rest > take and rest:sub(take + 1) or ""
          if has_content then current = current .. " " end
          current = current .. rest:sub(1, take)
          has_content = true
          rest = tail
          if #rest > 0 then
            rows[#rows + 1] = current
            current, has_content = "", false
            continuation = true
          end
        end
      end
    end
  end
  if has_content then rows[#rows + 1] = current end
  if #rows == 0 then rows[1] = "" end
  return rows
end

--- The rows for one report (ADR-0069 amendment): each display line's
--- presentation applied with the toolkit's own means. Without a
--- presentation (an older server) the verbatim display stands alone,
--- as before. Returns the rows plus the per-row maps the buffer
--- records: source line, svg path, verbatim output, tier, the
--- answer rows, and the fold ranges over the hidden list tails.
local function render_rows(report, width)
  local rows = {}
  local src_lines, graphs, verbatim, tiers = {}, {}, {}, {}
  local answer_rows, folds = {}, {}
  -- The "L<line> " label's width, so wrapped, grid, and folded rows
  -- align under the text they belong to.
  local hang = 7
  for _, statement in ipairs(report.statements or {}) do
    if statement.display ~= nil then
      local label = string.format("L%-5d ", statement.line + 1)
      local first_row = #rows + 1
      local present = statement.presentation
      local answer = present ~= nil and present.answer == true
      if present ~= nil and type(present.lines) == "table" and #present.lines > 0 then
        for _, pane in ipairs(present.lines) do
          local glyph = pane.verdict == nil and "" or (pane.verdict and "✓ " or "✗ ")
          local body, tail_rows
          if pane.grid ~= nil then
            body = grid_body(pane.grid, hang)
            tail_rows = 0
          elseif pane.list ~= nil then
            body, tail_rows = list_body(pane.list, width, hang)
          else
            body = wrap_segments(pane.segments, width, hang, pane.text)
            tail_rows = 0
          end
          for bi, line in ipairs(body) do
            rows[#rows + 1] = bi == 1 and (label .. glyph .. line) or line
            local r = #rows
            src_lines[r] = statement.line + 1
            graphs[r] = ""
            verbatim[r] = statement.display
            tiers[r] = pane.kind
          end
          -- list_body's tail rows sit at the body's end: fold them.
          if tail_rows > 0 then
            folds[#folds + 1] = { #rows - tail_rows + 1, #rows }
          end
        end
      else
        rows[#rows + 1] = label .. statement.display
        local r = #rows
        src_lines[r] = statement.line + 1
        graphs[r] = ""
        verbatim[r] = statement.display
        if statement.error then tiers[r] = "error" end
      end
      if answer then
        for r = first_row, #rows do answer_rows[#answer_rows + 1] = r end
      end
    end
  end
  return rows, src_lines, graphs, verbatim, tiers, answer_rows, folds
end

--- y in the results buffer: yank the row's verbatim statement output
--- (ADR-0078's first rule: copy never sees the shaped text).
local function copy_row()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local ok, verbatim = pcall(vim.api.nvim_buf_get_var, 0, "epher_verbatim")
  local value = ok and type(verbatim) == "table" and verbatim[row] or nil
  if value == nil or value == "" then return end
  vim.fn.setreg('"', value)
  pcall(vim.fn.setreg, "+", value)
  vim.notify("epher: copied the verbatim output", vim.log.levels.INFO)
end

--- The verbatim float of a CursorHold hover; gone on the next move.
local hover_win = nil
local hover_buf = nil
local function close_hover()
  if hover_win ~= nil and vim.api.nvim_win_is_valid(hover_win) then
    vim.api.nvim_win_close(hover_win, true)
  end
  if hover_buf ~= nil and vim.api.nvim_buf_is_valid(hover_buf) then
    vim.api.nvim_buf_delete(hover_buf, { force = true })
  end
  hover_win, hover_buf = nil, nil
end
local function hover_row()
  close_hover()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local ok, verbatim = pcall(vim.api.nvim_buf_get_var, 0, "epher_verbatim")
  local value = ok and type(verbatim) == "table" and verbatim[row] or nil
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  if value == nil or value == "" or value == line then return end
  local lines = vim.split(value, "\n", { plain = true })
  local widest = 0
  for _, l in ipairs(lines) do widest = math.max(widest, #l) end
  hover_buf = vim.api.nvim_create_buf(false, true)
  hover_win = vim.api.nvim_open_win(hover_buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(80, math.max(20, widest)),
    height = #lines,
    border = "rounded",
    style = "minimal",
    focusable = false,
  })
  vim.api.nvim_buf_set_lines(hover_buf, 0, -1, false, lines)
end

--- Renders one report into a fresh scratch buffer and opens it
--- beside the script (or floating, with pane = "float").
local function show_report(src_bufnr, report, pane)
  -- One fresh buffer per run: the old one is deleted, so its window
  -- (if any) falls back to another buffer and two runs never stack
  -- two result panes side by side.
  if results_buf ~= nil and vim.api.nvim_buf_is_valid(results_buf) then
    vim.api.nvim_buf_delete(results_buf, { force = true })
  end
  results_buf = vim.api.nvim_create_buf(false, true)

  -- The window opens first: the rows wrap to the real pane width
  -- (ADR-0078 R2), which a float and a split do not share.
  local win
  if pane == "float" then
    win = vim.api.nvim_open_win(results_buf, false, {
      relative = "editor",
      anchor = "NE",
      row = 1,
      col = vim.o.columns - 1,
      width = math.max(40, math.floor(vim.o.columns * 0.45)),
      height = math.max(8, math.floor(vim.o.lines * 0.5)),
      border = "rounded",
      focusable = true,
    })
  else
    vim.cmd("vsplit")
    vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), results_buf)
    win = vim.api.nvim_get_current_win()
  end
  local width = vim.api.nvim_win_get_width(win)

  -- The rows are the script's output, not a re-reading of the
  -- script: only statements that produced something, shaped by the
  -- run's presentation when the server sent one, every row carrying
  -- its source line for the <CR> jump.
  local rows, src_lines, graphs, verbatim, tiers, answer_rows, folds =
    render_rows(report or {}, width)
  if report ~= nil and report.svgs ~= nil and #report.svgs > 0 then
    local dir = vim.fs.normalize(vim.fn.stdpath("cache") .. "/epher/runs")
    vim.fn.mkdir(dir, "p")
    table.insert(rows, "")
    table.insert(rows, string.format("Graphs (%d, each opened with the system viewer):", #report.svgs))
    for i, svg in ipairs(report.svgs) do
      local path = dir .. string.format("/run-%d-%d.svg", os.time(), i)
      local file = io.open(path, "w")
      if file ~= nil then
        file:write(svg)
        file:close()
        table.insert(rows, "  " .. path)
        src_lines[#rows] = 0
        graphs[#rows] = path
        verbatim[#rows] = ""
        -- The graph opens with the system viewer as soon as it is
        -- written, like the other clients; the row above reopens it.
        open_path(path)
      end
    end
  end

  if #rows == 0 then
    rows = { "No output." }
  end
  -- The rows above are inserted in pieces (statements, a blank
  -- line, the graph header); fill any hole the piecewise inserts
  -- left, because the nvim_buf_set_var boundary rejects sparse
  -- tables on Neovim 0.9.
  for i = 1, #rows do
    src_lines[i] = src_lines[i] or 0
    graphs[i] = graphs[i] or ""
    verbatim[i] = verbatim[i] or ""
  end
  vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, rows)
  local name = vim.fs.basename(vim.api.nvim_buf_get_name(src_bufnr))
  vim.api.nvim_buf_set_name(results_buf, "epher results: " .. (name ~= "" and name or "untitled"))
  vim.bo[results_buf].buftype = "nofile"
  vim.bo[results_buf].bufhidden = "wipe"
  vim.bo[results_buf].swapfile = false
  vim.bo[results_buf].foldmethod = "manual"
  vim.api.nvim_buf_set_var(results_buf, "epher_src_bufnr", src_bufnr)
  vim.api.nvim_buf_set_var(results_buf, "epher_src_lines", src_lines)
  vim.api.nvim_buf_set_var(results_buf, "epher_graphs", graphs)
  vim.api.nvim_buf_set_var(results_buf, "epher_verbatim", verbatim)

  -- The hidden list tails fold away (ADR-0078 R3), while the buffer
  -- is still modifiable: fold commands change no text, but a closed
  -- fold keeps the rules simple.
  for _, f in ipairs(folds) do
    vim.api.nvim_win_call(win, function()
      vim.cmd(string.format("silent %d,%dfold", f[1], f[2]))
    end)
  end
  if #folds > 0 then
    vim.api.nvim_win_call(win, function() vim.cmd("silent normal! zM") end)
  end
  vim.bo[results_buf].modifiable = false

  -- The tiers (ADR-0078) and the answer emphasis (R4), after the
  -- text exists so the marks land exactly. The pane's answer
  -- highlight is scheme-agnostic bold; the tiers ride the colors
  -- the user already has (Comment dims, ErrorMsg reads as failure).
  vim.api.nvim_set_hl(0, "EpherAnswer", { default = true, bold = true })
  for r = 1, #rows do
    local group = nil
    if tiers[r] == "setup" then group = "Comment" end
    if tiers[r] == "error" then group = "ErrorMsg" end
    if group ~= nil then
      vim.api.nvim_buf_set_extmark(results_buf, M.ns, r - 1, 0, {
        end_line = r - 1,
        end_col = 0,
        hl_group = group,
        hl_eol = true,
      })
    end
  end
  for _, r in ipairs(answer_rows) do
    vim.api.nvim_buf_set_extmark(results_buf, M.ns, r - 1, 0, {
      end_line = r - 1,
      end_col = 0,
      hl_group = "EpherAnswer",
      hl_eol = true,
    })
  end
  vim.keymap.set("n", "<CR>", follow, { buffer = results_buf, nowait = true, silent = true })
  vim.keymap.set("n", "y", copy_row, { buffer = results_buf, nowait = true, silent = true })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = M.augroup,
    buffer = results_buf,
    callback = hover_row,
    desc = "epher: the row's verbatim output under the cursor",
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "BufWipeout" }, {
    group = M.augroup,
    buffer = results_buf,
    callback = close_hover,
    desc = "epher: the verbatim float goes when the cursor moves",
  })

  -- The run's answer carries the weight (ADR-0078 R4/R5): the
  -- cursor lands on it, so the pane opens scrolled to what matters.
  if #answer_rows > 0 then
    vim.api.nvim_win_set_cursor(win, { answer_rows[1], 0 })
  end
end

--- Runs the current epher buffer: one `epher/run` request to the
--- attached language server, results in the pane.
function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "epher" then
    -- Running from the results pane (where a run leaves the cursor)
    -- re-runs the script the pane belongs to: the pane's own recorded
    -- source (epher_src_bufnr, the same link the <CR> jump follows),
    -- never a shared "last run" that a run elsewhere could re-point
    -- and make this pane execute the wrong script.
    local ok, src = pcall(vim.api.nvim_buf_get_var, bufnr, "epher_src_bufnr")
    if ok and type(src) == "number" and vim.api.nvim_buf_is_valid(src)
      and vim.bo[src].filetype == "epher" then
      bufnr = src
    else
      vim.notify("epher: the current buffer is not an epher script", vim.log.levels.WARN)
      return
    end
  end
  local clients = epher_clients(bufnr)
  local client = clients[1]
  if client == nil then
    vim.notify("epher: the language server is not attached; see :checkhealth vim.lsp", vim.log.levels.WARN)
    return
  end

  -- The server knows documents by didOpen. Attached buffers were
  -- opened at attach time; anything else (a buffer the client never
  -- saw) is opened here first, so the run sees what the editor sees.
  local uri = vim.uri_from_bufnr(bufnr)
  local attached = client.attached_buffers ~= nil and client.attached_buffers[bufnr]
  if not attached then
    local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    if has_lsp_config then
      client:notify("textDocument/didOpen", {
        textDocument = { uri = uri, languageId = "epher", version = 0, text = text },
      })
    else
      client.notify("textDocument/didOpen", {
        textDocument = { uri = uri, languageId = "epher", version = 0, text = text },
      })
    end
  end

  -- The handler runs on an LSP thread either way; every editor call
  -- waits for the scheduler.
  local pane = M.pane or "split"
  local function handler(err, result)
    vim.schedule(function()
      if err ~= nil then
        vim.notify("epher run failed: " .. tostring(err.message or err), vim.log.levels.ERROR)
        return
      end
      show_report(bufnr, result or {}, pane)
    end)
  end
  -- client:request answers (handled, request_id): false means no
  -- transport took the request, which for us means a stopped server.
  local handled = send_run(client, bufnr, { textDocument = { uri = uri } }, handler)
  if not handled then
    vim.notify("epher: the language server stopped before the run started", vim.log.levels.ERROR)
  end
end

--- The directory a buffer's script lives in; untitled buffers run
--- from the working directory.
local function buffer_root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return vim.fn.getcwd()
  end
  return vim.fs.dirname(name)
end

--- Set up the epher language server. Call once, from anywhere.
--- opts.cmd: the command that starts epher-lsp (default {"epher-lsp"}).
--- opts.pane: "split" (default) or "float" for the results window.
function M.setup(opts)
  opts = opts or {}
  M.pane = opts.pane or "split"
  local cmd = opts.cmd or { "epher-lsp" }

  if has_lsp_config then
    vim.lsp.config("epher", {
      cmd = cmd,
      filetypes = { "epher" },
      -- A calculator file stands alone: its own directory is the root.
      root_dir = function(bufnr, on_dir)
        on_dir(buffer_root(bufnr))
      end,
    })
    vim.lsp.enable("epher")
  else
    -- 0.9/0.10: vim.lsp.start on the FileType event, which reuses
    -- an existing client when the name and root match.
    local function attach(bufnr)
      vim.lsp.start({
        name = "epher",
        cmd = cmd,
        root_dir = buffer_root(bufnr),
      }, { bufnr = bufnr })
    end
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "epher",
      callback = function(args)
        attach(args.buf)
      end,
      desc = "epher: attach the language server",
    })
    -- Buffers that were already open when setup() ran.
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == "epher" and vim.api.nvim_buf_get_name(bufnr) ~= "" then
        attach(bufnr)
      end
    end
  end

  vim.api.nvim_create_user_command("EpherRun", function()
    M.run()
  end, { desc = "Run the current epher script and show the results pane", force = true })

  -- Inline answers (ADR-0066): nvim renders them natively from the
  -- server's inlay hints from 0.11 on; older versions skip this and
  -- only the results pane shows the answers.
  if vim.lsp.inlay_hint then
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "epher",
      callback = function(args)
        vim.lsp.inlay_hint.enable(true, { bufnr = args.buf })
      end,
      desc = "epher: show inline answers",
    })
    -- Buffers that were already open when setup() ran.
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[bufnr].filetype == "epher" then
        vim.lsp.inlay_hint.enable(true, { bufnr = bufnr })
      end
    end
  end
end

return M
