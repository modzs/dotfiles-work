return {
  {
    'MeanderingProgrammer/render-markdown.nvim',
    ft = 'markdown',
    -- nvim ships the markdown and markdown_inline parsers this reads a buffer
    -- with, so no nvim-treesitter here; see AGENTS.md
    opts = {},
  },
  {
    'iamcco/markdown-preview.nvim',
    -- mkdp defines its three commands buffer-locally, from a filetype-gated autocmd, so
    -- ft alone is what makes them exist. a cmd stub cannot help: lazy's cmd handler
    -- re-fires no event, so in a non-markdown buffer the stub deletes itself, loads the
    -- plugin for nothing, then defers `Command ... not found after loading
    -- markdown-preview.nvim` - an error blaming the plugin in place of the immediate
    -- honest E492, which is what a retype gives anyway once the stub is gone
    ft = 'markdown',
    -- builds the preview server from the vendored app/ with the node home.nix
    -- already installs, rather than downloading a prebuilt binary
    build = 'cd app && npx --yes yarn@1.22.22 install',
  },
}
