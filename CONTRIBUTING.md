# Contributing to Input Source Pro

First off, thank you for considering contributing to Input Source Pro! We welcome any help, whether it's reporting a bug, proposing a feature, improving documentation, adding translations, or writing code.

This document provides guidelines to help you contribute effectively.

## Code of Conduct

This project and everyone participating in it is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code. Please report unacceptable behavior to [support@inputsource.pro](mailto:support@inputsource.pro).

## How Can I Contribute?

* **Reporting Bugs:** If you find a bug, please report it!
* **Suggesting Enhancements:** Have an idea for a new feature or an improvement? Let us know.
* **Pull Requests:** Contribute code, documentation updates, or translations.
* **Answering Questions:** Help others in the [GitHub Discussions](https://github.com/runjuu/InputSourcePro/discussions) section.

## Reporting Bugs

Before submitting a bug report, please check the existing [GitHub Issues](https://github.com/runjuu/InputSourcePro/issues) to see if someone else has already reported it.

If not, create a new issue and provide the following information:

1.  **Clear Title:** Describe the issue concisely.
2.  **Steps to Reproduce:** Detailed steps to reliably reproduce the behavior.
3.  **Expected Behavior:** What you expected to happen.
4.  **Actual Behavior:** What actually happened. Include error messages or screenshots if applicable.
5.  **Environment:**
    * Input Source Pro Version (e.g., 1.2.3 Build 456 - found in left bottom corner of the app)
    * macOS Version (e.g., macOS 15.4.1 - found in "About This Mac")
    * Affected Application(s) (if applicable)
    * Relevant Input Sources used

## Suggesting Enhancements

We track feature requests using [GitHub Discussions](https://github.com/runjuu/InputSourcePro/discussions). Before creating a new one, check if a similar suggestion already exists.

When submitting an enhancement suggestion, please include:

1.  **Clear Title:** Describe the enhancement concisely.
2.  **Problem Description:** What problem does this enhancement solve? Why is it needed?
3.  **Proposed Solution:** A clear description of the feature or improvement you envision.
4.  **Alternatives Considered:** (Optional) Any alternative solutions or features you've considered.
5.  **Additional Context:** Mockups, examples, or related information.

## Your First Code Contribution / Pull Requests

Ready to contribute code? Here's how to set up and submit a pull request:

### Setting Up Your Development Environment

1.  **Fork** the repository on GitHub.
2.  **Clone** your fork locally: `git clone git@github.com:runjuu/InputSourcePro.git`
3.  **Open** the project (`Input Source Pro.xcodeproj`) in the latest stable version of Xcode.
4.  Dependencies are managed via Swift Package Manager (SPM) and should resolve automatically when you open the project.
5.  **Build and Run** the project (Cmd+R) to ensure everything is set up correctly.

### Making Changes

1.  **Create a new branch** for your changes, based off the `main` branch. Use a descriptive name (e.g., `feature/add-xyz-support`, `fix/indicator-crash`).
    ```bash
    git checkout main
    git pull origin main
    git checkout -b feature/your-descriptive-branch-name
    ```
2.  **Write your code.** Please try to follow the existing code style. If you add new features, consider adding tests if applicable.
3.  **Ensure the project builds** successfully (Cmd+B).
4.  **Commit your changes** with clear and concise commit messages. Reference the issue number if your PR addresses a specific issue (e.g., `Fix #123: Resolve crash when switching sources rapidly`).
    ```bash
    git add .
    git commit -m "feat: Add support for XYZ browser rule"
    ```
5.  **Push** your branch to your fork on GitHub:
    ```bash
    git push origin feature/your-descriptive-branch-name
    ```

### Submitting a Pull Request

1.  Go to the original `InputSourcePro` repository on [GitHub](https://github.com/runjuu/InputSourcePro).
2.  Click on "Pull Requests" and then "New pull request".
3.  Choose your fork and the branch containing your changes.
4.  **Write a clear description** for your Pull Request:
    * Explain the **purpose** of your changes.
    * Link to any relevant **issues** (e.g., "Closes #123").
    * Summarize the **changes** made.
    * Describe any **testing** you performed.
5.  Submit the Pull Request. A maintainer will review it as soon as possible. Be prepared to discuss your changes and make adjustments based on feedback.

## Style Guides

* **Code Style:** Follow the existing Swift conventions used in the project. Keep code clear and readable.
* **Git Commit Messages:** Use conventional commit messages if possible (e.g., `feat: ...`, `fix: ...`, `docs: ...`), but clear, descriptive messages are the priority.
* **Swift Code:** Follow standard Swift API Design Guidelines and try to match the style of the surrounding code.

## License

By contributing, you agree that your contributions will be licensed under the [GPL-3.0 License](LICENSE) that covers the project.

---

Thank you again for your interest in contributing!