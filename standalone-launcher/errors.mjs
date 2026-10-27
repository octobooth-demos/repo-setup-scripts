// User-facing error with a stable code; the HTTP API returns it as a 400 with { error, code }.
export class LauncherError extends Error {
    constructor(code, message) {
        super(message);
        this.name = "LauncherError";
        this.code = code;
    }
}
