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
-- show the text results in a scratch buffer; graphs are written as
-- SVG files and opened with the system viewer). `:EpherRun` does all
-- of that for the current buffer; setup({ pane = "float" }) puts the
-- results in a floating window instead of a vertical split.

local M = {}

M.ns = vim.api.nvim_create_namespace("epher-results")

--- Neovim 0.11 split the attach API in two; 0.9 and 0.10 are the
--- vim.lsp.start generation. Everything below keys off this one
--- check, the way the emacs client keys off its jsonrpc version.
local has_lsp_config = vim.lsp.config ~= nil

--- The results buffer of the last run, so a rerun replaces it
--- instead of stacking windows.
local results_buf = nil
--- The buffer of the last run. Focus lands in the results pane after
--- a run, and rerunning from there should just work: it re-runs this
--- one, not whatever the pane happens to be.
local last_run = nil

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

  -- The rows are the script's output, not a re-reading of the
  -- script: only statements that produced something, errors marked,
  -- every row carrying its source line for the <CR> jump.
  local rows = {}
  -- results line (1-based) -> source line, 0 where the row has no
  -- jump. The arrays stay dense: the nvim_buf_set_var boundary
  -- rejects sparse tables on Neovim 0.9.
  local src_lines = {}
  -- results line (1-based) -> svg path, "" where the row is not a
  -- graph row.
  local graphs = {}
  -- results lines (1-based) carrying an error, marked once the text exists.
  local error_rows = {}
  for _, statement in ipairs(report.statements or {}) do
    if statement.display ~= nil then
      -- The wire carries 0-based lines; humans and nvim cursor rows
      -- count from 1, so both the label and the jump target add one.
      table.insert(rows, string.format("L%-5d %s", statement.line + 1, statement.display))
      src_lines[#rows] = statement.line + 1
      graphs[#rows] = ""
      if statement.error then
        error_rows[#error_rows + 1] = #rows
      end
    end
  end
  if report.svgs ~= nil and #report.svgs > 0 then
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
  end
  vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, rows)
  local name = vim.fs.basename(vim.api.nvim_buf_get_name(src_bufnr))
  vim.api.nvim_buf_set_name(results_buf, "epher results: " .. (name ~= "" and name or "untitled"))
  vim.bo[results_buf].buftype = "nofile"
  vim.bo[results_buf].bufhidden = "wipe"
  vim.bo[results_buf].swapfile = false
  vim.bo[results_buf].modifiable = false
  vim.api.nvim_buf_set_var(results_buf, "epher_src_bufnr", src_bufnr)
  vim.api.nvim_buf_set_var(results_buf, "epher_src_lines", src_lines)
  vim.api.nvim_buf_set_var(results_buf, "epher_graphs", graphs)
  -- Error rows, after the text exists so the marks land exactly.
  for _, row in ipairs(error_rows) do
    vim.api.nvim_buf_set_extmark(results_buf, M.ns, row - 1, 0, {
      end_line = row - 1,
      end_col = 0,
      hl_group = "ErrorMsg",
      hl_eol = true,
    })
  end
  vim.keymap.set("n", "<CR>", follow, { buffer = results_buf, nowait = true, silent = true })

  -- The window: a vertical split by default (the pane beside the
  -- script, like every other editor's results pane), or a right
  -- anchored float.
  if pane == "float" then
    vim.api.nvim_open_win(results_buf, false, {
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
  end
end

--- Runs the current epher buffer: one `epher/run` request to the
--- attached language server, results in the pane.
function M.run()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "epher" then
    -- Running from the results pane (where a run leaves the cursor)
    -- re-runs the script the pane belongs to.
    if last_run ~= nil and vim.api.nvim_buf_is_valid(last_run)
      and vim.bo[last_run].filetype == "epher" then
      bufnr = last_run
    else
      vim.notify("epher: the current buffer is not an epher script", vim.log.levels.WARN)
      return
    end
  end
  last_run = bufnr
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
