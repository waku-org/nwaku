
## nph - An opinionated Nim formatter
This prettifier tool is used to format the nwaku code base.

### VSCode Extension
https://marketplace.visualstudio.com/items?itemName=arnetheduck.vscode-nph

### GitHub
https://github.com/arnetheduck/nph

### Installation and configuration
1. Ask the [nwaku team](https://discord.com/channels/1110799176264056863/1111541184490393691) about the required `nph` version.
2. Download the desired release from _GitHub_ and place the binary in the PATH env var.
3. Add the following content into `~/.config/Code/User/settings.json`:

```
{
    "editor.renderWhitespace": "all",
    "editor.largeFileOptimizations": false,
    "[python]": {
        "editor.formatOnType": true
    },
    "explorer.confirmDelete": false,
    "explorer.confirmDragAndDrop": false,
    "editor.rulers": [
        100
    ],
    "diffEditor.ignoreTrimWhitespace": false,
    "editor.parameterHints.enabled": false,
    "rust-analyzer.inlayHints.parameterHints.enable": false,
    "rust-analyzer.inlayHints.bindingModeHints.enable": true,
    "rust-analyzer.inlayHints.closureCaptureHints.enable": true,
    "editor.minimap.enabled": false,
    "window.zoomLevel": 1,
    "[nim]": {
        "editor.formatOnSave": true,
        "editor.defaultFormatter": "arnetheduck.vscode-nph"
    },
}
```

With that, every time a Nim file is saved, it will be formatted automatically.

