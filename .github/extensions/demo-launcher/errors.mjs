// Host-neutral error with a machine-readable code. Each host adapter maps it to its own
// error type (CanvasError in the Copilot app, a thrown Error in VS Code tools).
export class LauncherError extends Error {
    constructor(code, message) {
        super(message);
        this.name = "LauncherError";
        this.code = code;
    }
}
