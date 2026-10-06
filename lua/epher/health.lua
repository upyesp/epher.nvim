-- :checkhealth epher -- the three things the client needs: a modern
-- enough Neovim, the epher-lsp binary, and the runtime files this
-- plugin ships. Every check says what to do when it fails.
return {
  check = function()
    vim.health.start("epher")

    -- Neovim version: everything works on 0.9, the inline answers
    -- need 0.11's inlay hints. has("nvim-0.11") is the honest check;
    -- vim.lsp.inlay_hint existing is the API-level one and stays true
    -- for the 0.11 line this client targets.
    if vim.lsp.inlay_hint ~= nil then
      vim.health.ok("Neovim carries the inlay-hint API: the inline answers render natively")
    else
      vim.health.warn(
        "Neovim is older than 0.11: no inline answers, the results window shows them instead",
        "Upgrade to Neovim 0.11 or newer for the inline answers"
      )
    end

    -- The language server binary. The cmd is configurable, so a miss
    -- here is a warning, not an error: a full path in setup() is fine.
    if vim.fn.executable("epher-lsp") == 1 then
      vim.health.ok("`epher-lsp` is on PATH")
    else
      vim.health.warn(
        "`epher-lsp` is not on PATH",
        {
          "Download the build for your operating system from",
          "https://github.com/upyesp/epher/releases/latest",
          "and put it on your PATH, or pass its full path to",
          'require("epher").setup({ cmd = { "/path/to/epher-lsp" } })',
        }
      )
    end

    -- The runtime files this plugin ships. All three must resolve, or
    -- .epher files never become epher buffers.
    for _, rel in ipairs({ "ftdetect/epher.vim", "ftplugin/epher.vim", "syntax/epher.vim" }) do
      if #vim.api.nvim_get_runtime_file(rel, false) > 0 then
        vim.health.ok("`" .. rel .. "` is on the runtimepath")
      else
        vim.health.error(
          "`" .. rel .. "` is not on the runtimepath",
          "Reinstall the plugin; the ftdetect, ftplugin, and syntax directories ship beside lua/"
        )
      end
    end
  end,
}
