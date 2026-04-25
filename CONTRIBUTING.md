# Contributing to OpenScribe

Thank you for your interest in contributing!

## Getting Started

1. **Fork** the repository and clone your fork
2. Create a **feature branch**: `git checkout -b feature/my-feature`
3. Make your changes
4. Run the tests: `swift test`
5. Open a **Pull Request** against `main`

## What to Work On

Check the [Issues](../../issues) tab for open bugs and feature requests. If you want to add something new, open an issue first to discuss it — this avoids duplicate effort.

## Code Style

- Follow standard Swift conventions (Swift API Design Guidelines)
- [SwiftLint](https://github.com/realm/SwiftLint) is recommended but not enforced in CI
- Keep functions small and focused
- Prefer `let` over `var` wherever possible

## Tests

- Any new **business logic** (model, audio engine behaviour) should come with unit tests
- Place tests in `Tests/OpenScribeTests/`
- Run `swift test` before submitting your PR

## Reporting Bugs

Please include:
- macOS version
- Steps to reproduce
- Expected vs. actual behaviour
- A sample audio file if the bug is format-specific

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
