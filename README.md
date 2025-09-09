# small-useful-scripts

A collection of my small but useful command-line scripts.

### Available Scripts:
-   **gemini.sh** - A simple CLI tool for interacting with the Google Gemini API.
-   **maccheck** - A security analysis tool for macOS `.app` bundles and `.dmg` files.

---

## gemini.sh

*Easy tool for work with Gemini API in CLI.*

### SET UP
Need to set the env:
```shell
export GEMINI_API_KEY="YOUR_API_KEY"
```
For further use you have to add it to your `~/.bashrc` or `~/.zshrc`.

### USE
- Start:
```shell
./gemini.sh "Question about anything"
```
- Alias (e.g. in `~/.zshrc`):
```shell
alias gemini='~/small-useful-scripts/gemini.sh'
```

---

## maccheck

*A script to perform a security and signature check on macOS `.app` bundles or `.dmg` disk images.*

### SET UP
1.  **Make the script executable:**
    ```shell
    chmod +x maccheck
    ```
2.  **Ensure Xcode Command Line Tools are installed:**
    This script requires tools like `codesign` and `spctl`. If you don't have them, install them with:
    ```shell
    xcode-select --install
    ```

### USE
- Run the check on a `.dmg` or `.app` file:
```shell
./maccheck "/path/to/some/application.dmg"
```
```shell
./maccheck "/path/to/some/application.app"
```

- Alias (e.g. in `~/.zshrc`):
```shell
alias maccheck='~/small-useful-scripts/maccheck'
```
