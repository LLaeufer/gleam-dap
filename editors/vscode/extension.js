// Registers the `gleam` debug type and starts the gleam-dap adapter.
const vscode = require("vscode");
const path = require("path");
const fs = require("fs");

function activate(context) {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("gleam", {
      createDebugAdapterDescriptor() {
        const settings = vscode.workspace.getConfiguration("gleamDap");
        const configured = settings.get("adapterPath");
        const env = {};
        const logFile = settings.get("logFile");
        if (logFile) env.GLEAM_DAP_LOG = logFile;
        if (configured) {
          return new vscode.DebugAdapterExecutable(configured, [], { env });
        }
        // The bundled adapter is started with `erl` directly: unpacking the
        // extension doesn't keep the launcher script executable.
        const ebin = context.asAbsolutePath(path.join("adapter", "ebin"));
        if (!fs.existsSync(ebin)) {
          vscode.window.showErrorMessage(
            "gleam-dap: no adapter found. Set gleamDap.adapterPath to the gleam-dap launcher."
          );
          return undefined;
        }
        return new vscode.DebugAdapterExecutable(
          "erl",
          ["-noinput", "-pa", ebin, "-eval", "gleam_dap:main()"],
          { env }
        );
      },
    })
  );

  context.subscriptions.push(
    vscode.debug.registerDebugConfigurationProvider("gleam", {
      // F5 without a launch.json: debug the workspace's Gleam project.
      resolveDebugConfiguration(folder, config) {
        if (!config.type && !config.request && !config.name) {
          const editor = vscode.window.activeTextEditor;
          if (editor && editor.document.languageId === "gleam") {
            config.type = "gleam";
            config.request = "launch";
            config.name = "Debug Gleam project";
          }
        }
        if (!config.projectDir && folder) {
          config.projectDir = folder.uri.fsPath;
        }
        return config;
      },
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
